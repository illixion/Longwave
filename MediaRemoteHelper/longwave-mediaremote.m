// Longwave MediaRemote helper.
//
// Reads the *system-wide* Now Playing state — the same data the macOS menu bar
// widget shows — for any player: Music.app (local files and Apple Music
// streaming alike), Spotify, Safari/Chrome/Firefox video, podcasts, anything
// that publishes to MediaRemote. This is what AppleScript against Music.app
// cannot do: it sees only Music, and returns no artwork bytes at all for
// streamed Apple Music tracks.
//
// This file is deliberately NOT part of any Xcode target. It is compiled into
// `longwave-mediaremote.dylib` by scripts/build-mediaremote-helper.sh and
// copied into the app bundle's Resources as a plain data file. The app never
// links or loads it — only /usr/bin/perl does. See MediaRemoteBridge.swift for
// the parent side, and README.md in this folder for why the perl host is
// required at all.
//
// Approach informed by ungive/mediaremote-adapter (BSD 3-Clause), which
// established that an Apple-signed host is what MediaRemote checks. The code
// here is our own and speaks its own protocol.

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <signal.h>
#include <stdio.h>
#include <unistd.h>

#pragma mark - MediaRemote private API

// Verified against macOS 26.6 (`dyld_info -exports`). Dictionary keys are
// plain strings equal to their constant names, so we spell them literally
// rather than dlsym'ing each CFStringRef.
typedef void (*MRGetNowPlayingInfo)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*MRRegisterForNotifications)(dispatch_queue_t);
typedef void (*MRGetIsPlaying)(dispatch_queue_t, void (^)(bool));
typedef void (*MRGetClient)(dispatch_queue_t, void (^)(id));
typedef bool (*MRSendCommand)(int command, id userInfo);

static NSString *const kInfoTitle = @"kMRMediaRemoteNowPlayingInfoTitle";
static NSString *const kInfoArtist = @"kMRMediaRemoteNowPlayingInfoArtist";
static NSString *const kInfoAlbum = @"kMRMediaRemoteNowPlayingInfoAlbum";
static NSString *const kInfoDuration = @"kMRMediaRemoteNowPlayingInfoDuration";
static NSString *const kInfoElapsed = @"kMRMediaRemoteNowPlayingInfoElapsedTime";
static NSString *const kInfoTimestamp = @"kMRMediaRemoteNowPlayingInfoTimestamp";
static NSString *const kInfoPlaybackRate = @"kMRMediaRemoteNowPlayingInfoPlaybackRate";
static NSString *const kInfoArtworkData = @"kMRMediaRemoteNowPlayingInfoArtworkData";
static NSString *const kInfoArtworkMIME = @"kMRMediaRemoteNowPlayingInfoArtworkMIMEType";
static NSString *const kInfoArtworkID = @"kMRMediaRemoteNowPlayingInfoArtworkIdentifier";
static NSString *const kInfoContentID = @"kMRMediaRemoteNowPlayingInfoContentItemIdentifier";
static NSString *const kInfoUniqueID = @"kMRMediaRemoteNowPlayingInfoUniqueIdentifier";

// MRCommand values used by MRMediaRemoteSendCommand.
enum { kCmdPlay = 0, kCmdPause = 1, kCmdTogglePlayPause = 2, kCmdNextTrack = 4,
       kCmdPreviousTrack = 5 };

#pragma mark - State

static MRGetNowPlayingInfo mrGetInfo;
static MRRegisterForNotifications mrRegister;
static MRGetIsPlaying mrIsPlaying;
static MRGetClient mrGetClient;
static MRSendCommand mrSendCommand;

/// Identity of the artwork whose bytes we last emitted, so we send several
/// hundred KB of base64 only when the image actually changes.
static NSString *lastArtworkKey;
/// Last artwork we saw, reused when MediaRemote briefly drops the bytes for a
/// track it previously had them for (it does this while seeking).
static NSData *lastArtworkData;
static NSString *lastArtworkMIME;
/// Last emitted line, to suppress duplicate updates.
static NSString *lastPayload;
/// Elapsed time we last reported, and when — used to tell a seek apart from
/// playback simply having advanced.
static double lastElapsed;
static double lastElapsedAt;
static bool announcedReady;

#pragma mark - Output

/// Writes one NDJSON line to stdout. Exits if the parent has gone away — an
/// orphaned helper holding a MediaRemote client registration is worse than no
/// helper at all.
static void emitLine(NSDictionary *object) {
    NSError *error = nil;
    NSData *json = [NSJSONSerialization dataWithJSONObject:object options:0 error:&error];
    if (json == nil) {
        fprintf(stderr, "longwave-mediaremote: encode failed: %s\n",
                error.localizedDescription.UTF8String);
        return;
    }
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];

    const uint8_t *bytes = line.bytes;
    size_t remaining = line.length;
    while (remaining > 0) {
        ssize_t written = write(STDOUT_FILENO, bytes, remaining);
        if (written > 0) {
            bytes += written;
            remaining -= (size_t)written;
        } else if (written < 0 && errno == EINTR) {
            continue;
        } else {
            _exit(0); // Parent closed the pipe.
        }
    }
}

static void emitError(NSString *message) {
    fprintf(stderr, "longwave-mediaremote: %s\n", message.UTF8String);
}

#pragma mark - Snapshot building

static NSString *stringValue(NSDictionary *info, NSString *key) {
    id value = info[key];
    return [value isKindOfClass:NSString.class] && ((NSString *)value).length > 0 ? value : nil;
}

static NSNumber *numberValue(NSDictionary *info, NSString *key) {
    id value = info[key];
    return [value isKindOfClass:NSNumber.class] ? value : nil;
}

/// A stable identity for the current artwork. The artwork identifier is a URL
/// for streamed content and absent for some local files, so fall back through
/// the content/track identifiers and finally the byte count.
static NSString *artworkKeyFor(NSDictionary *info, NSData *artwork) {
    NSString *identifier = stringValue(info, kInfoArtworkID);
    if (identifier) return identifier;
    id contentID = info[kInfoContentID] ?: info[kInfoUniqueID];
    if (contentID) return [NSString stringWithFormat:@"%@", contentID];
    if (artwork) return [NSString stringWithFormat:@"len:%lu", (unsigned long)artwork.length];
    return nil;
}

/// Elapsed playback time brought forward to *now*. MediaRemote reports elapsed
/// time as of `timestamp`, which can be many seconds stale.
static NSNumber *elapsedNow(NSDictionary *info, bool playing) {
    NSNumber *elapsed = numberValue(info, kInfoElapsed);
    if (elapsed == nil) return nil;
    double seconds = elapsed.doubleValue;
    id timestamp = info[kInfoTimestamp];
    if (playing && [timestamp isKindOfClass:NSDate.class]) {
        double drift = -[(NSDate *)timestamp timeIntervalSinceNow];
        if (drift > 0 && drift < 24 * 60 * 60) seconds += drift;
    }
    NSNumber *duration = numberValue(info, kInfoDuration);
    if (duration != nil && duration.doubleValue > 0) {
        seconds = MIN(seconds, duration.doubleValue);
    }
    return @(MAX(0, seconds));
}

static void publish(NSDictionary *info, NSString *bundleID) {
    NSString *title = stringValue(info, kInfoTitle);
    if (title == nil) {
        // Nothing playing anywhere. Reset artwork memory so the next track is
        // always sent with its image.
        lastArtworkKey = nil;
        lastArtworkData = nil;
        lastArtworkMIME = nil;
        NSString *payload = @"none";
        if (![payload isEqualToString:lastPayload]) {
            lastPayload = payload;
            emitLine(@{@"v": @1, @"none": @YES});
        }
        return;
    }

    NSNumber *rate = numberValue(info, kInfoPlaybackRate);
    bool playing = rate != nil ? rate.doubleValue > 0 : false;

    NSData *artwork = [info[kInfoArtworkData] isKindOfClass:NSData.class]
        ? info[kInfoArtworkData] : nil;
    NSString *artworkMIME = stringValue(info, kInfoArtworkMIME);
    NSString *artworkKey = artworkKeyFor(info, artwork);

    // MediaRemote drops artwork bytes momentarily (e.g. while scrubbing). If
    // this is still the same artwork we already have, reuse it rather than
    // telling the headset the image vanished.
    if (artwork == nil && artworkKey != nil && lastArtworkData != nil &&
        [artworkKey isEqualToString:lastArtworkKey]) {
        artwork = lastArtworkData;
        artworkMIME = lastArtworkMIME;
    }

    bool artworkIsNew = artwork != nil &&
        (artworkKey == nil || ![artworkKey isEqualToString:lastArtworkKey]);
    if (artworkIsNew) {
        lastArtworkKey = artworkKey;
        lastArtworkData = artwork;
        lastArtworkMIME = artworkMIME;
    }

    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    payload[@"v"] = @1;
    payload[@"playing"] = playing ? @YES : @NO;
    payload[@"title"] = title;
    if (stringValue(info, kInfoArtist)) payload[@"artist"] = stringValue(info, kInfoArtist);
    if (stringValue(info, kInfoAlbum)) payload[@"album"] = stringValue(info, kInfoAlbum);
    if (numberValue(info, kInfoDuration)) payload[@"duration"] = numberValue(info, kInfoDuration);
    if (bundleID) payload[@"bundleID"] = bundleID;
    if (artworkKey) payload[@"artworkKey"] = artworkKey;

    // Fingerprint everything except elapsed time and the artwork bytes, so the
    // artwork retry passes don't each re-emit an otherwise identical update.
    NSData *identity = [NSJSONSerialization dataWithJSONObject:payload options:
        NSJSONWritingSortedKeys error:NULL];
    NSString *fingerprint = [[NSString alloc] initWithData:identity
                                                  encoding:NSUTF8StringEncoding];
    bool changed = fingerprint == nil || ![fingerprint isEqualToString:lastPayload];

    // Elapsed time is excluded above because it advances on its own. Report it
    // anyway when it jumps away from where playback should have reached, which
    // is what a seek looks like.
    NSNumber *elapsed = elapsedNow(info, playing);
    if (elapsed) payload[@"elapsed"] = elapsed;
    if (!changed && elapsed != nil) {
        double expected = lastElapsed;
        if (playing) expected += [NSDate timeIntervalSinceReferenceDate] - lastElapsedAt;
        if (fabs(elapsed.doubleValue - expected) > 2.0) changed = true;
    }
    if (elapsed != nil) {
        lastElapsed = elapsed.doubleValue;
        lastElapsedAt = [NSDate timeIntervalSinceReferenceDate];
    }

    if (!changed && !artworkIsNew) return;
    lastPayload = fingerprint;

    if (artworkIsNew) {
        payload[@"artwork"] = [artwork base64EncodedStringWithOptions:0];
        payload[@"artworkMIME"] = artworkMIME ?: @"application/octet-stream";
    }
    emitLine(payload);
}

#pragma mark - Refresh

static dispatch_queue_t workQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("pro.longwave.mediaremote", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

/// Bundle identifier of the app currently owning Now Playing, or nil. Read
/// through the client object because the PID-based lookup misses browsers,
/// which publish through a helper process.
static void withBundleID(void (^completion)(NSString *)) {
    if (mrGetClient == NULL) { completion(nil); return; }
    mrGetClient(workQueue(), ^(id client) {
        NSString *bundleID = nil;
        if (client != nil && [client respondsToSelector:@selector(bundleIdentifier)]) {
            id value = [client performSelector:@selector(bundleIdentifier)];
            if ([value isKindOfClass:NSString.class]) bundleID = value;
        }
        if (bundleID == nil && client != nil &&
            [client respondsToSelector:@selector(parentApplicationBundleIdentifier)]) {
            id value = [client performSelector:@selector(parentApplicationBundleIdentifier)];
            if ([value isKindOfClass:NSString.class]) bundleID = value;
        }
        completion(bundleID);
    });
}

static void refresh(void) {
    if (mrGetInfo == NULL) return;
    mrGetInfo(workQueue(), ^(NSDictionary *info) {
        if (!announcedReady) {
            announcedReady = true;
            emitLine(@{@"v": @1, @"ready": @YES});
        }
        withBundleID(^(NSString *bundleID) {
            publish(info, bundleID);
        });
    });
}

/// Coalesces the burst of notifications MediaRemote emits for a single track
/// change into one refresh, then re-checks shortly after because artwork bytes
/// frequently arrive a beat later than the rest of the metadata.
static void scheduleRefresh(void) {
    static int generation;
    int current = ++generation;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(150 * NSEC_PER_MSEC)),
                   dispatch_get_main_queue(), ^{
        if (current != generation) return;
        refresh();
    });
    static const double retryDelays[] = {0.8, 2.0};
    for (size_t i = 0; i < sizeof(retryDelays) / sizeof(retryDelays[0]); i++) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(retryDelays[i] * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (current != generation) return;
            refresh();
        });
    }
}

#pragma mark - Setup

static bool loadMediaRemote(void) {
    void *handle = dlopen(
        "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (handle == NULL) {
        emitError([NSString stringWithFormat:@"dlopen failed: %s", dlerror()]);
        return false;
    }
    mrGetInfo = (MRGetNowPlayingInfo)dlsym(handle, "MRMediaRemoteGetNowPlayingInfo");
    mrRegister = (MRRegisterForNotifications)dlsym(
        handle, "MRMediaRemoteRegisterForNowPlayingNotifications");
    mrIsPlaying = (MRGetIsPlaying)dlsym(
        handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    mrGetClient = (MRGetClient)dlsym(handle, "MRMediaRemoteGetNowPlayingClient");
    mrSendCommand = (MRSendCommand)dlsym(handle, "MRMediaRemoteSendCommand");
    if (mrGetInfo == NULL) {
        emitError(@"MRMediaRemoteGetNowPlayingInfo missing");
        return false;
    }
    return true;
}

/// Both sources must be stored, not left as locals: ARC releases a
/// dispatch_source_t as soon as it goes out of scope, which silently cancels
/// the watch and leaves an orphaned helper holding a MediaRemote client
/// registration after the companion quits.
static dispatch_source_t stdinWatch;
static dispatch_source_t parentWatch;

/// Exits when the companion goes away, whether it quit cleanly or crashed.
///
/// Two independent triggers, because an orphan here is not harmless — it keeps a
/// registered MediaRemote client alive and goes on streaming into a pipe nobody
/// reads. stdin reaching EOF covers the parent closing the pipe; watching the
/// parent pid covers the parent dying while something else holds the pipe open.
static void watchParent(void) {
    stdinWatch = dispatch_source_create(
        DISPATCH_SOURCE_TYPE_READ, STDIN_FILENO, 0, dispatch_get_main_queue());
    dispatch_source_set_event_handler(stdinWatch, ^{
        char buffer[256];
        ssize_t count = read(STDIN_FILENO, buffer, sizeof(buffer));
        if (count == 0) _exit(0);
    });
    dispatch_resume(stdinWatch);

    pid_t parent = getppid();
    if (parent > 1) {
        parentWatch = dispatch_source_create(DISPATCH_SOURCE_TYPE_PROC, (uintptr_t)parent,
                                            DISPATCH_PROC_EXIT, dispatch_get_main_queue());
        if (parentWatch != NULL) {
            dispatch_source_set_event_handler(parentWatch, ^{ _exit(0); });
            dispatch_resume(parentWatch);
        }
    }
}

#pragma mark - Entry points

// Called by /usr/bin/perl through DynaLoader::dl_install_xsub, i.e. as an XS
// sub. Threaded perl passes (PerlInterpreter *, CV *); we never touch the perl
// stack so both are ignored.
//
// This MUST be invoked after dl_load_file() has returned rather than from a
// library constructor: a constructor runs while dyld still holds the loader
// lock, and MediaRemote's reply path lazily loads further images, so the
// callbacks would deadlock and never fire. That failure looks exactly like
// "no permission" — the request reaches mediaremoted and succeeds, but the
// completion block is never called.
__attribute__((visibility("default")))
void longwave_mediaremote_stream(void *interpreter, void *cv) {
    (void)interpreter; (void)cv;
    @autoreleasepool {
        signal(SIGPIPE, SIG_IGN);
        setvbuf(stdout, NULL, _IONBF, 0);
        if (!loadMediaRemote()) _exit(2);
        watchParent();

        for (NSString *name in @[
            @"kMRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationDidChangeNotification",
            @"kMRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"kMRMediaRemoteNowPlayingPlaybackQueueDidChangeNotification",
        ]) {
            [NSNotificationCenter.defaultCenter addObserverForName:name
                                                           object:nil
                                                            queue:nil
                                                       usingBlock:^(NSNotification *note) {
                scheduleRefresh();
            }];
        }

        if (mrRegister != NULL) mrRegister(dispatch_get_main_queue());
        refresh();
    }
    CFRunLoopRun();
}

/// One-shot transport control. The command arrives in LW_MR_COMMAND because an
/// XS sub cannot take C arguments.
__attribute__((visibility("default")))
void longwave_mediaremote_send(void *interpreter, void *cv) {
    (void)interpreter; (void)cv;
    @autoreleasepool {
        if (!loadMediaRemote()) _exit(2);
        if (mrSendCommand == NULL) {
            emitError(@"MRMediaRemoteSendCommand missing");
            _exit(2);
        }
        const char *raw = getenv("LW_MR_COMMAND");
        NSString *name = raw != NULL ? @(raw) : @"";
        int command;
        if ([name isEqualToString:@"play"]) command = kCmdPlay;
        else if ([name isEqualToString:@"pause"]) command = kCmdPause;
        else if ([name isEqualToString:@"toggle"]) command = kCmdTogglePlayPause;
        else if ([name isEqualToString:@"next"]) command = kCmdNextTrack;
        else if ([name isEqualToString:@"previous"]) command = kCmdPreviousTrack;
        else {
            emitError([NSString stringWithFormat:@"unknown command '%@'", name]);
            _exit(2);
        }
        bool ok = mrSendCommand(command, nil);
        _exit(ok ? 0 : 1);
    }
}
