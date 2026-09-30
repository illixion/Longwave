// longwave-sandbox-semd — keeps a host-global named POSIX semaphore unlinked.
//
// Why: the visionOS simulator's in-sim compositor, wakeboardd, opens the named
// semaphore "wakeboardd.first-boot". Named semaphores are global to the host
// kernel and persist after their creator exits, and macOS refuses to let a
// different user open one regardless of its mode (verified: even a
// root-created 0666 semaphore gives EACCES). So whichever macOS user boots a
// visionOS simulator first after a host boot locks every other user out:
// their wakeboardd aborts with "can't open first boot semaphore: Permission
// denied" and the device never gets past "Waiting on Data Migration".
//
// Unlinking only removes the name. A simulator that already has it open keeps
// working, and the next wakeboardd to start creates a fresh one owned by its
// own user. launchd_sim restarts a crashed wakeboardd every few seconds, so a
// boot that loses the race to this loop recovers on its next restart. Every
// boot then counts as a "first boot", which only affects the boot animation.
//
// Usage: longwave-sandbox-semd [name] [interval-seconds]   (runs forever)
//        longwave-sandbox-semd --once [name]
// Run as root by the pro.longwave.sandbox LaunchDaemon: the semaphore is owned
// by whoever created it, and only that user or root may unlink it.

#include <errno.h>
#include <semaphore.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

int main(int argc, char *argv[]) {
    int once = 0;
    int arg = 1;
    if (argc > arg && strcmp(argv[arg], "--once") == 0) {
        once = 1;
        arg++;
    }
    const char *name = argc > arg ? argv[arg] : "wakeboardd.first-boot";
    unsigned interval = argc > arg + 1 ? (unsigned)strtoul(argv[arg + 1], NULL, 10) : 2;
    if (interval < 1) interval = 1;
    if (interval > 60) interval = 60;

    if (once) {
        if (sem_unlink(name) == 0) return 0;
        if (errno == ENOENT) return 0;
        fprintf(stderr, "sem_unlink(%s): %s\n", name, strerror(errno));
        return 1;
    }

    for (;;) {
        // ENOENT is the normal case between simulator boots; anything else
        // (EACCES if not root) would repeat every tick, so it is not logged.
        (void)sem_unlink(name);
        sleep(interval);
    }
}
