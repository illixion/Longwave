import RAVECompanion

/// The listener behind one of the Companion's fixed stream ports, kept up for
/// as long as its server runs: RAVESDK's `RAVECompanionPortListener` since
/// 2026-11-01. A listener holds its PSKs for life, so pairing or revoking a
/// device replaces it, and a replacement bound before the old one reports
/// `.cancelled` fails with EADDRINUSE in `stateUpdateHandler` — which until
/// 2026-10-17 left the Native, audio and inject ports closed after every
/// pairing. It waits for the old listener, and retries a failed bind with
/// backoff for as long as the server runs.
typealias CompanionPortListener = RAVECompanionPortListener
