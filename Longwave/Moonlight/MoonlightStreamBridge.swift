#if MOONLIGHT_ENABLED
import Foundation
import os
@preconcurrency import MoonlightCommonC

// MARK: - Stream Delegate Protocol

/// Protocol for receiving connection lifecycle events from the streaming session.
protocol MoonlightStreamDelegate: AnyObject, Sendable {
    func moonlightStreamStageStarting(_ stage: Int32)
    func moonlightStreamStageComplete(_ stage: Int32)
    func moonlightStreamStageFailed(_ stage: Int32, errorCode: Int32)
    func moonlightStreamConnectionStarted()
    func moonlightStreamConnectionTerminated(_ errorCode: Int32)
    func moonlightStreamConnectionStatusUpdate(_ status: Int32)
    func moonlightStreamSetHdrMode(_ enabled: Bool)
}

// MARK: - Audio Configuration Helpers

/// Recreate MAKE_AUDIO_CONFIGURATION macro: ((channelMask) << 16) | (channelCount << 8) | 0xCA
nonisolated func makeAudioConfiguration(channelCount: Int, channelMask: Int) -> Int32 {
    Int32((channelMask << 16) | (channelCount << 8) | 0xCA)
}

/// Extract SURROUNDAUDIOINFO from audio config: (channelMask << 16) | channelCount
nonisolated func surroundAudioInfo(from audioConfig: Int32) -> Int {
    let channelCount = (Int(audioConfig) >> 8) & 0xFF
    let channelMask = (Int(audioConfig) >> 16) & 0xFFFF
    return (channelMask << 16) | channelCount
}

// Pre-computed audio configurations: ((channelMask) << 16) | (channelCount << 8) | 0xCA
// Stereo: (0x3 << 16) | (2 << 8) | 0xCA = 0x302CA
// 5.1:    (0x3F << 16) | (6 << 8) | 0xCA = 0x3F06CA
// 7.1:    (0x63F << 16) | (8 << 8) | 0xCA = 0x63F08CA
let audioConfigStereo: Int32 = 0x302CA
let audioConfig51: Int32 = 0x3F06CA
let audioConfig71: Int32 = 0x63F08CA

// MARK: - Callbacks

/// The C callbacks moonlight-common-c invokes, routed to the renderers of the
/// library copy that fired them.
///
/// A C function pointer cannot carry a context, and the library passes its
/// `renderContext` to `setup` only — never to `submitDecodeUnit`, the hot path —
/// so each linked copy gets its own set of callbacks with the slot baked in as a
/// literal (`makeCallbacks(slot:)`). Those are non-capturing closures, which is
/// what makes them convertible to `@convention(c)`; they all funnel into the
/// slot-parameterised functions below.
enum MoonlightBridge {
    nonisolated private static func library(_ slot: Int) -> MoonlightLibrary {
        MoonlightLibrary.all[slot]
    }

    // MARK: Video

    nonisolated static func videoSetup(_ slot: Int, _ videoFormat: Int32, _ width: Int32, _ height: Int32,
                                       _ redrawRate: Int32) -> Int32 {
        AppLog.moonlightBridge.line("[\(slot)] Video setup: \(width)x\(height)@\(redrawRate) format=0x\(String(videoFormat, radix: 16))")
        guard let renderer = library(slot).videoRenderer else {
            AppLog.moonlightBridge.line("[\(slot)] ERROR: No video renderer!")
            return -1
        }
        return renderer.setup(videoFormat: videoFormat, width: width, height: height, fps: redrawRate)
    }

    nonisolated static func videoStart(_ slot: Int) {
        AppLog.moonlightBridge.line("[\(slot)] Video start")
        library(slot).videoRenderer?.start()
    }

    nonisolated static func videoStop(_ slot: Int) {
        AppLog.moonlightBridge.line("[\(slot)] Video stop")
        library(slot).videoRenderer?.stop()
    }

    nonisolated static func videoCleanup(_ slot: Int) {
        AppLog.moonlightBridge.line("[\(slot)] Video cleanup")
        library(slot).videoRenderer?.cleanup()
    }

    nonisolated static func videoSubmitDecodeUnit(_ slot: Int, _ du: UnsafeMutablePointer<DECODE_UNIT>?) -> Int32 {
        guard let du, let renderer = library(slot).videoRenderer else { return DR_NEED_IDR }
        return renderer.submitDecodeUnit(du)
    }

    // MARK: Audio

    nonisolated static func audioInit(_ slot: Int, _ audioConfiguration: Int32,
                                      _ opusConfig: UnsafeMutablePointer<OPUS_MULTISTREAM_CONFIGURATION>?) -> Int32 {
        guard let opusConfig, let renderer = library(slot).audioRenderer else { return -1 }
        return renderer.setup(audioConfig: audioConfiguration, opusConfig: opusConfig)
    }

    nonisolated static func audioStart(_ slot: Int) { library(slot).audioRenderer?.start() }
    nonisolated static func audioStop(_ slot: Int) { library(slot).audioRenderer?.stop() }
    nonisolated static func audioCleanup(_ slot: Int) { library(slot).audioRenderer?.cleanup() }

    nonisolated static func audioDecodeAndPlay(_ slot: Int, _ sampleData: UnsafeMutablePointer<CChar>?, _ sampleLength: Int32) {
        guard let sampleData, let renderer = library(slot).audioRenderer else { return }
        renderer.decodeAndPlaySample(sampleData, length: sampleLength)
    }

    // MARK: Connection listener

    nonisolated static func stageStarting(_ slot: Int, _ stage: Int32) {
        AppLog.moonlightBridge.line("[\(slot)] Stage starting: \(stageName(stage)) (\(stage))")
        let delegate = library(slot).delegate
        Task { @MainActor in delegate?.moonlightStreamStageStarting(stage) }
    }

    nonisolated static func stageComplete(_ slot: Int, _ stage: Int32) {
        AppLog.moonlightBridge.line("[\(slot)] Stage complete: \(stageName(stage)) (\(stage))")
        let delegate = library(slot).delegate
        Task { @MainActor in delegate?.moonlightStreamStageComplete(stage) }
    }

    nonisolated static func stageFailed(_ slot: Int, _ stage: Int32, _ errorCode: Int32) {
        AppLog.moonlightBridge.line("[\(slot)] Stage FAILED: \(stageName(stage)) (\(stage)), error=\(errorCode)")
        let delegate = library(slot).delegate
        Task { @MainActor in delegate?.moonlightStreamStageFailed(stage, errorCode: errorCode) }
    }

    nonisolated static func connectionStarted(_ slot: Int) {
        AppLog.moonlightBridge.line("[\(slot)] Connection started successfully!")
        let delegate = library(slot).delegate
        Task { @MainActor in delegate?.moonlightStreamConnectionStarted() }
    }

    nonisolated static func connectionTerminated(_ slot: Int, _ errorCode: Int32) {
        AppLog.moonlightBridge.line("[\(slot)] Connection terminated, error=\(errorCode)")
        let delegate = library(slot).delegate
        Task { @MainActor in delegate?.moonlightStreamConnectionTerminated(errorCode) }
    }

    nonisolated static func connectionStatusUpdate(_ slot: Int, _ status: Int32) {
        AppLog.moonlightBridge.line("[\(slot)] Connection status update: \(status)")
        let delegate = library(slot).delegate
        Task { @MainActor in delegate?.moonlightStreamConnectionStatusUpdate(status) }
    }

    nonisolated static func rumble(_ slot: Int, _ controllerNumber: UInt16, _ lowFreqMotor: UInt16, _ highFreqMotor: UInt16) {
        library(slot).gamepadManager?.handleRumble(controllerNumber: controllerNumber, lowFreqMotor: lowFreqMotor, highFreqMotor: highFreqMotor)
    }

    nonisolated static func setHdrMode(_ slot: Int, _ hdrEnabled: Bool) {
        AppLog.moonlightBridge.line("[\(slot)] HDR mode: \(hdrEnabled)")
        // Forward HDR mode to renderer so it can update metadata and request IDR
        library(slot).videoRenderer?.setHdrMode(hdrEnabled)
        let delegate = library(slot).delegate
        Task { @MainActor in delegate?.moonlightStreamSetHdrMode(hdrEnabled) }
    }

    /// Map moonlight-common-c stage constants to human-readable names
    nonisolated static func stageName(_ stage: Int32) -> String {
        switch stage {
        case STAGE_PLATFORM_INIT: return "Platform Init"
        case STAGE_NAME_RESOLUTION: return "Name Resolution"
        case STAGE_RTSP_HANDSHAKE: return "RTSP Handshake"
        case STAGE_CONTROL_STREAM_INIT: return "Control Stream Init"
        case STAGE_VIDEO_STREAM_INIT: return "Video Stream Init"
        case STAGE_AUDIO_STREAM_INIT: return "Audio Stream Init"
        case STAGE_INPUT_STREAM_INIT: return "Input Stream Init"
        case STAGE_CONTROL_STREAM_START: return "Control Stream Start"
        case STAGE_VIDEO_STREAM_START: return "Video Stream Start"
        case STAGE_AUDIO_STREAM_START: return "Audio Stream Start"
        case STAGE_INPUT_STREAM_START: return "Input Stream Start"
        default: return "Unknown"
        }
    }

    // MARK: Per-slot callback tables

    /// The three callback structs for one linked copy, built with the unprefixed
    /// module's struct types (every copy shares the layout). One `case` per slot,
    /// because the slot has to be a literal inside a non-capturing closure for it
    /// to become a C function pointer — see the type comment.
    nonisolated static func makeCallbacks(slot: Int) -> (
        video: DECODER_RENDERER_CALLBACKS,
        audio: AUDIO_RENDERER_CALLBACKS,
        connection: CONNECTION_LISTENER_CALLBACKS
    ) {
        var dr = DECODER_RENDERER_CALLBACKS()
        LiInitializeVideoCallbacks(&dr)
        dr.capabilities = Int32(CAPABILITY_REFERENCE_FRAME_INVALIDATION_AV1)

        var ar = AUDIO_RENDERER_CALLBACKS()
        LiInitializeAudioCallbacks(&ar)
        ar.capabilities = 0

        var cl = CONNECTION_LISTENER_CALLBACKS()
        LiInitializeConnectionCallbacks(&cl)
        cl.logMessage = nil  // variadic — can't bridge to Swift
        cl.rumbleTriggers = { _, _, _ in }
        cl.setMotionEventState = { _, _, _ in }
        cl.setControllerLED = { _, _, _, _ in }
        cl.setAdaptiveTriggers = { _, _, _, _, _, _ in }

        switch slot {
        case 0:
            dr.setup = { format, w, h, rate, _, _ in MoonlightBridge.videoSetup(0, format, w, h, rate) }
            dr.start = { MoonlightBridge.videoStart(0) }
            dr.stop = { MoonlightBridge.videoStop(0) }
            dr.cleanup = { MoonlightBridge.videoCleanup(0) }
            dr.submitDecodeUnit = { MoonlightBridge.videoSubmitDecodeUnit(0, $0) }
            ar.`init` = { config, opus, _, _ in MoonlightBridge.audioInit(0, config, opus) }
            ar.start = { MoonlightBridge.audioStart(0) }
            ar.stop = { MoonlightBridge.audioStop(0) }
            ar.cleanup = { MoonlightBridge.audioCleanup(0) }
            ar.decodeAndPlaySample = { MoonlightBridge.audioDecodeAndPlay(0, $0, $1) }
            cl.stageStarting = { MoonlightBridge.stageStarting(0, $0) }
            cl.stageComplete = { MoonlightBridge.stageComplete(0, $0) }
            cl.stageFailed = { MoonlightBridge.stageFailed(0, $0, $1) }
            cl.connectionStarted = { MoonlightBridge.connectionStarted(0) }
            cl.connectionTerminated = { MoonlightBridge.connectionTerminated(0, $0) }
            cl.connectionStatusUpdate = { MoonlightBridge.connectionStatusUpdate(0, $0) }
            cl.rumble = { MoonlightBridge.rumble(0, $0, $1, $2) }
            cl.setHdrMode = { MoonlightBridge.setHdrMode(0, $0) }
        case 1:
            dr.setup = { format, w, h, rate, _, _ in MoonlightBridge.videoSetup(1, format, w, h, rate) }
            dr.start = { MoonlightBridge.videoStart(1) }
            dr.stop = { MoonlightBridge.videoStop(1) }
            dr.cleanup = { MoonlightBridge.videoCleanup(1) }
            dr.submitDecodeUnit = { MoonlightBridge.videoSubmitDecodeUnit(1, $0) }
            ar.`init` = { config, opus, _, _ in MoonlightBridge.audioInit(1, config, opus) }
            ar.start = { MoonlightBridge.audioStart(1) }
            ar.stop = { MoonlightBridge.audioStop(1) }
            ar.cleanup = { MoonlightBridge.audioCleanup(1) }
            ar.decodeAndPlaySample = { MoonlightBridge.audioDecodeAndPlay(1, $0, $1) }
            cl.stageStarting = { MoonlightBridge.stageStarting(1, $0) }
            cl.stageComplete = { MoonlightBridge.stageComplete(1, $0) }
            cl.stageFailed = { MoonlightBridge.stageFailed(1, $0, $1) }
            cl.connectionStarted = { MoonlightBridge.connectionStarted(1) }
            cl.connectionTerminated = { MoonlightBridge.connectionTerminated(1, $0) }
            cl.connectionStatusUpdate = { MoonlightBridge.connectionStatusUpdate(1, $0) }
            cl.rumble = { MoonlightBridge.rumble(1, $0, $1, $2) }
            cl.setHdrMode = { MoonlightBridge.setHdrMode(1, $0) }
        case 2:
            dr.setup = { format, w, h, rate, _, _ in MoonlightBridge.videoSetup(2, format, w, h, rate) }
            dr.start = { MoonlightBridge.videoStart(2) }
            dr.stop = { MoonlightBridge.videoStop(2) }
            dr.cleanup = { MoonlightBridge.videoCleanup(2) }
            dr.submitDecodeUnit = { MoonlightBridge.videoSubmitDecodeUnit(2, $0) }
            ar.`init` = { config, opus, _, _ in MoonlightBridge.audioInit(2, config, opus) }
            ar.start = { MoonlightBridge.audioStart(2) }
            ar.stop = { MoonlightBridge.audioStop(2) }
            ar.cleanup = { MoonlightBridge.audioCleanup(2) }
            ar.decodeAndPlaySample = { MoonlightBridge.audioDecodeAndPlay(2, $0, $1) }
            cl.stageStarting = { MoonlightBridge.stageStarting(2, $0) }
            cl.stageComplete = { MoonlightBridge.stageComplete(2, $0) }
            cl.stageFailed = { MoonlightBridge.stageFailed(2, $0, $1) }
            cl.connectionStarted = { MoonlightBridge.connectionStarted(2) }
            cl.connectionTerminated = { MoonlightBridge.connectionTerminated(2, $0) }
            cl.connectionStatusUpdate = { MoonlightBridge.connectionStatusUpdate(2, $0) }
            cl.rumble = { MoonlightBridge.rumble(2, $0, $1, $2) }
            cl.setHdrMode = { MoonlightBridge.setHdrMode(2, $0) }
        default:
            preconditionFailure("MoonlightLibrary.count is \(MoonlightLibrary.count); no callbacks for slot \(slot)")
        }
        return (dr, ar, cl)
    }
}

// MARK: - Stream Launcher

/// Configuration for starting a Moonlight streaming session.
struct MoonlightStreamConfig {
    var width: Int32 = 1920
    var height: Int32 = 1080
    var fps: Int32 = 60
    var bitrate: Int32 = 20000  // kbps
    var packetSize: Int32 = 1024
    var audioConfiguration: Int32
    var supportedVideoFormats: Int32
    var colorSpace: Int32 = COLORSPACE_REC_709
    var colorRange: Int32 = COLOR_RANGE_LIMITED
    var serverAddress: String
    var serverAppVersion: String
    var serverGfeVersion: String
    var rtspSessionUrl: String?
    var serverCodecModeSupport: Int32
    var riKey: Data         // 16 bytes
    var riKeyId: Int32
    var encryptionFlags: Int32 = Int32(bitPattern: 0xFFFFFFFF) // ENCFLG_ALL
}

/// Starts a Moonlight streaming session on `library`. This function blocks
/// until the connection is established or fails. Must be called from a
/// background thread.
nonisolated func startMoonlightStream(
    library: MoonlightLibrary,
    config: MoonlightStreamConfig,
    videoRenderer: MoonlightVideoRenderer,
    audioRenderer: MoonlightAudioRenderer,
    delegate: MoonlightStreamDelegate
) -> Int32 {
    // Defensive clean slate: each copy of moonlight-common-c keeps a single
    // connection's worth of internal threads and file-static depacketizer state.
    // If a prior session on this copy ended without a full teardown (e.g. a wifi
    // dropout terminated it), that stale state would corrupt this connection and
    // crash on the lingering VideoRecv thread. LiStopConnection is stage-driven
    // and a no-op when nothing is active, so it's safe to call unconditionally.
    library.functions.stopConnection()

    // Point this copy's callbacks at the session's renderers
    library.videoRenderer = videoRenderer
    library.audioRenderer = audioRenderer
    library.delegate = delegate

    // Build STREAM_CONFIGURATION
    var streamConfig = STREAM_CONFIGURATION()
    LiInitializeStreamConfiguration(&streamConfig)
    streamConfig.width = config.width
    streamConfig.height = config.height
    streamConfig.fps = config.fps
    streamConfig.bitrate = config.bitrate
    streamConfig.packetSize = config.packetSize
    streamConfig.streamingRemotely = STREAM_CFG_AUTO
    streamConfig.audioConfiguration = config.audioConfiguration
    streamConfig.supportedVideoFormats = config.supportedVideoFormats
    streamConfig.colorSpace = config.colorSpace
    streamConfig.colorRange = config.colorRange
    streamConfig.encryptionFlags = config.encryptionFlags

    // Copy AES key and IV into the fixed-size C arrays
    config.riKey.withUnsafeBytes { keyPtr in
        withUnsafeMutableBytes(of: &streamConfig.remoteInputAesKey) { dest in
            let count = min(keyPtr.count, dest.count)
            dest.copyBytes(from: UnsafeRawBufferPointer(rebasing: keyPtr.prefix(count)))
        }
    }

    // riKeyId encodes into first 4 bytes of IV as big-endian
    var ivData = Data(count: 16)
    let id = config.riKeyId.bigEndian
    withUnsafeBytes(of: id) { src in
        ivData.replaceSubrange(0..<4, with: src)
    }
    ivData.withUnsafeBytes { ivPtr in
        withUnsafeMutableBytes(of: &streamConfig.remoteInputAesIv) { dest in
            let count = min(ivPtr.count, dest.count)
            dest.copyBytes(from: UnsafeRawBufferPointer(rebasing: ivPtr.prefix(count)))
        }
    }

    // Build SERVER_INFORMATION using strdup'd strings
    var serverInfo = SERVER_INFORMATION()
    LiInitializeServerInformation(&serverInfo)

    let addressStr = strdup(config.serverAddress)
    let appVersionStr = strdup(config.serverAppVersion)
    let gfeVersionStr = strdup(config.serverGfeVersion)
    let sessionUrlStr = config.rtspSessionUrl.map { strdup($0) } ?? nil

    defer {
        free(addressStr)
        free(appVersionStr)
        free(gfeVersionStr)
        if let s = sessionUrlStr { free(s) }
    }

    serverInfo.address = UnsafePointer(addressStr)
    serverInfo.serverInfoAppVersion = UnsafePointer(appVersionStr)
    serverInfo.serverInfoGfeVersion = UnsafePointer(gfeVersionStr)
    serverInfo.rtspSessionUrl = sessionUrlStr.map { UnsafePointer($0) }
    serverInfo.serverCodecModeSupport = config.serverCodecModeSupport

    var callbacks = MoonlightBridge.makeCallbacks(slot: library.slot)

    // Start connection (blocks until connected or failed)
    AppLog.moonlightBridge.line("[\(library.slot)] Calling LiStartConnection...")
    let result = withUnsafeMutablePointer(to: &serverInfo) { serverInfoPtr in
        withUnsafeMutablePointer(to: &streamConfig) { streamConfigPtr in
            withUnsafeMutablePointer(to: &callbacks.connection) { clPtr in
                withUnsafeMutablePointer(to: &callbacks.video) { drPtr in
                    withUnsafeMutablePointer(to: &callbacks.audio) { arPtr in
                        library.functions.startConnection(
                            UnsafeMutableRawPointer(serverInfoPtr),
                            UnsafeMutableRawPointer(streamConfigPtr),
                            UnsafeMutableRawPointer(clPtr),
                            UnsafeMutableRawPointer(drPtr),
                            UnsafeMutableRawPointer(arPtr)
                        )
                    }
                }
            }
        }
    }
    AppLog.moonlightBridge.line("[\(library.slot)] LiStartConnection returned: \(result)")

    return result
}

/// Stops the streaming session running on `library`.
nonisolated func stopMoonlightStream(library: MoonlightLibrary) {
    AppLog.moonlightBridge.line("[\(library.slot)] Stopping stream...")
    library.functions.stopConnection()
    library.videoRenderer = nil
    library.audioRenderer = nil
    library.delegate = nil
    library.gamepadManager = nil
    AppLog.moonlightBridge.line("[\(library.slot)] Stream stopped")
}
#endif
