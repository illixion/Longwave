#if MOONLIGHT_ENABLED
import Foundation
import os
@preconcurrency import MoonlightCommonC

// MARK: - Global Renderer References

/// Global references to active renderers, accessed from C callbacks.
/// Only one streaming session can be active at a time.
nonisolated(unsafe) var activeVideoRenderer: MoonlightVideoRenderer?
nonisolated(unsafe) var activeAudioRenderer: MoonlightAudioRenderer?
nonisolated(unsafe) var activeStreamDelegate: MoonlightStreamDelegate?
nonisolated(unsafe) var activeGamepadManager: MoonlightGamepadManager?

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

// MARK: - Video Decoder Callbacks

private nonisolated func bridgeVideoSetup(_ videoFormat: Int32, _ width: Int32, _ height: Int32,
                               _ redrawRate: Int32, _ context: UnsafeMutableRawPointer?,
                               _ drFlags: Int32) -> Int32 {
    AppLog.moonlightBridge.line("Video setup: \(width)x\(height)@\(redrawRate) format=0x\(String(videoFormat, radix: 16))")
    guard let renderer = activeVideoRenderer else {
        AppLog.moonlightBridge.line("ERROR: No video renderer!")
        return -1
    }
    return renderer.setup(videoFormat: videoFormat, width: width, height: height, fps: redrawRate)
}

private nonisolated func bridgeVideoStart() {
    AppLog.moonlightBridge.line("Video start")
    activeVideoRenderer?.start()
}

private nonisolated func bridgeVideoStop() {
    AppLog.moonlightBridge.line("Video stop")
    activeVideoRenderer?.stop()
}

private nonisolated func bridgeVideoCleanup() {
    AppLog.moonlightBridge.line("Video cleanup")
    activeVideoRenderer?.cleanup()
}

private nonisolated func bridgeVideoSubmitDecodeUnit(_ du: UnsafeMutablePointer<DECODE_UNIT>?) -> Int32 {
    guard let du = du, let renderer = activeVideoRenderer else { return DR_NEED_IDR }
    return renderer.submitDecodeUnit(du)
}

// MARK: - Audio Renderer Callbacks

private nonisolated func bridgeAudioInit(_ audioConfiguration: Int32,
                              _ opusConfig: UnsafeMutablePointer<OPUS_MULTISTREAM_CONFIGURATION>?,
                              _ context: UnsafeMutableRawPointer?,
                              _ arFlags: Int32) -> Int32 {
    guard let opusConfig = opusConfig, let renderer = activeAudioRenderer else { return -1 }
    return renderer.setup(audioConfig: audioConfiguration, opusConfig: opusConfig)
}

private nonisolated func bridgeAudioStart() {
    activeAudioRenderer?.start()
}

private nonisolated func bridgeAudioStop() {
    activeAudioRenderer?.stop()
}

private nonisolated func bridgeAudioCleanup() {
    activeAudioRenderer?.cleanup()
}

private nonisolated func bridgeAudioDecodeAndPlay(_ sampleData: UnsafeMutablePointer<CChar>?,
                                       _ sampleLength: Int32) {
    guard let sampleData = sampleData, let renderer = activeAudioRenderer else { return }
    renderer.decodeAndPlaySample(sampleData, length: sampleLength)
}

// MARK: - Connection Listener Callbacks

private nonisolated func bridgeStageStarting(_ stage: Int32) {
    let stageName = moonlightStageName(stage)
    AppLog.moonlightBridge.line("Stage starting: \(stageName) (\(stage))")
    let delegate = activeStreamDelegate
    Task { @MainActor in delegate?.moonlightStreamStageStarting(stage) }
}

private nonisolated func bridgeStageComplete(_ stage: Int32) {
    let stageName = moonlightStageName(stage)
    AppLog.moonlightBridge.line("Stage complete: \(stageName) (\(stage))")
    let delegate = activeStreamDelegate
    Task { @MainActor in delegate?.moonlightStreamStageComplete(stage) }
}

private nonisolated func bridgeStageFailed(_ stage: Int32, _ errorCode: Int32) {
    let stageName = moonlightStageName(stage)
    AppLog.moonlightBridge.line("Stage FAILED: \(stageName) (\(stage)), error=\(errorCode)")
    let delegate = activeStreamDelegate
    Task { @MainActor in delegate?.moonlightStreamStageFailed(stage, errorCode: errorCode) }
}

private nonisolated func bridgeConnectionStarted() {
    AppLog.moonlightBridge.line("Connection started successfully!")
    let delegate = activeStreamDelegate
    Task { @MainActor in delegate?.moonlightStreamConnectionStarted() }
}

private nonisolated func bridgeConnectionTerminated(_ errorCode: Int32) {
    AppLog.moonlightBridge.line("Connection terminated, error=\(errorCode)")
    let delegate = activeStreamDelegate
    Task { @MainActor in delegate?.moonlightStreamConnectionTerminated(errorCode) }
}

private nonisolated func bridgeConnectionStatusUpdate(_ status: Int32) {
    AppLog.moonlightBridge.line("Connection status update: \(status)")
    let delegate = activeStreamDelegate
    Task { @MainActor in delegate?.moonlightStreamConnectionStatusUpdate(status) }
}

/// Map moonlight-common-c stage constants to human-readable names
private nonisolated func moonlightStageName(_ stage: Int32) -> String {
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

// Rumble and other controller callbacks
private nonisolated func bridgeRumble(_ controllerNumber: UInt16, _ lowFreqMotor: UInt16, _ highFreqMotor: UInt16) {
    activeGamepadManager?.handleRumble(controllerNumber: controllerNumber, lowFreqMotor: lowFreqMotor, highFreqMotor: highFreqMotor)
}
private nonisolated func bridgeSetHdrMode(_ hdrEnabled: Bool) {
    AppLog.moonlightBridge.line("HDR mode: \(hdrEnabled)")
    // Forward HDR mode to renderer so it can update metadata and request IDR
    activeVideoRenderer?.setHdrMode(hdrEnabled)
    let delegate = activeStreamDelegate
    Task { @MainActor in delegate?.moonlightStreamSetHdrMode(hdrEnabled) }
}
private nonisolated func bridgeRumbleTriggers(_ controllerNumber: UInt16, _ leftTrigger: UInt16, _ rightTrigger: UInt16) {}
private nonisolated func bridgeSetMotionEventState(_ controllerNumber: UInt16, _ motionType: UInt8, _ reportRateHz: UInt16) {}
private nonisolated func bridgeSetControllerLED(_ controllerNumber: UInt16, _ r: UInt8, _ g: UInt8, _ b: UInt8) {}
private nonisolated func bridgeSetAdaptiveTriggers(_ controllerNumber: UInt16, _ eventFlags: UInt8,
                                        _ typeLeft: UInt8, _ typeRight: UInt8,
                                        _ left: UnsafeMutablePointer<UInt8>?,
                                        _ right: UnsafeMutablePointer<UInt8>?) {}

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

/// Starts a Moonlight streaming session. This function blocks until the connection
/// is established or fails. Must be called from a background thread.
nonisolated func startMoonlightStream(
    config: MoonlightStreamConfig,
    videoRenderer: MoonlightVideoRenderer,
    audioRenderer: MoonlightAudioRenderer,
    delegate: MoonlightStreamDelegate
) -> Int32 {
    // Defensive clean slate: moonlight-common-c keeps a single connection's
    // worth of internal threads and file-static depacketizer state. If a prior
    // session ended without a full teardown (e.g. a wifi dropout terminated it),
    // that stale state would corrupt this connection and crash on the lingering
    // VideoRecv thread. LiStopConnection is stage-driven and a no-op when nothing
    // is active, so it's safe to call unconditionally here.
    LiStopConnection()

    // Set global renderer references
    activeVideoRenderer = videoRenderer
    activeAudioRenderer = audioRenderer
    activeStreamDelegate = delegate

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

    // Build callback structs
    var drCallbacks = DECODER_RENDERER_CALLBACKS()
    LiInitializeVideoCallbacks(&drCallbacks)
    drCallbacks.setup = bridgeVideoSetup
    drCallbacks.start = bridgeVideoStart
    drCallbacks.stop = bridgeVideoStop
    drCallbacks.cleanup = bridgeVideoCleanup
    drCallbacks.submitDecodeUnit = bridgeVideoSubmitDecodeUnit
    drCallbacks.capabilities = Int32(CAPABILITY_REFERENCE_FRAME_INVALIDATION_AV1)

    var arCallbacks = AUDIO_RENDERER_CALLBACKS()
    LiInitializeAudioCallbacks(&arCallbacks)
    arCallbacks.`init` = bridgeAudioInit
    arCallbacks.start = bridgeAudioStart
    arCallbacks.stop = bridgeAudioStop
    arCallbacks.cleanup = bridgeAudioCleanup
    arCallbacks.decodeAndPlaySample = bridgeAudioDecodeAndPlay
    arCallbacks.capabilities = 0

    var clCallbacks = CONNECTION_LISTENER_CALLBACKS()
    LiInitializeConnectionCallbacks(&clCallbacks)
    clCallbacks.stageStarting = bridgeStageStarting
    clCallbacks.stageComplete = bridgeStageComplete
    clCallbacks.stageFailed = bridgeStageFailed
    clCallbacks.connectionStarted = bridgeConnectionStarted
    clCallbacks.connectionTerminated = bridgeConnectionTerminated
    clCallbacks.logMessage = nil  // variadic — can't bridge to Swift
    clCallbacks.rumble = bridgeRumble
    clCallbacks.connectionStatusUpdate = bridgeConnectionStatusUpdate
    clCallbacks.setHdrMode = bridgeSetHdrMode
    clCallbacks.rumbleTriggers = bridgeRumbleTriggers
    clCallbacks.setMotionEventState = bridgeSetMotionEventState
    clCallbacks.setControllerLED = bridgeSetControllerLED
    clCallbacks.setAdaptiveTriggers = bridgeSetAdaptiveTriggers

    // Start connection (blocks until connected or failed)
    AppLog.moonlightBridge.line("Calling LiStartConnection...")
    let result = LiStartConnection(
        &serverInfo,
        &streamConfig,
        &clCallbacks,
        &drCallbacks,
        &arCallbacks,
        nil,  // renderContext
        0,    // drFlags
        nil,  // audioContext
        0     // arFlags
    )
    AppLog.moonlightBridge.line("LiStartConnection returned: \(result)")

    return result
}

/// Stops the active Moonlight streaming session.
nonisolated func stopMoonlightStream() {
    AppLog.moonlightBridge.line("Stopping stream...")
    LiStopConnection()
    activeVideoRenderer = nil
    activeAudioRenderer = nil
    activeStreamDelegate = nil
    activeGamepadManager = nil
    AppLog.moonlightBridge.line("Stream stopped")
}
#endif
