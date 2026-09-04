#if MOONLIGHT_ENABLED
@preconcurrency import MoonlightCommonC

// The entry points of the unprefixed copy of moonlight-common-c — the module
// whose types and constants the whole app uses. Copies 1 and 2 expose the same
// functions under a prefix and with raw pointers (MoonlightLibrarySlot1.swift,
// MoonlightLibrarySlot2.swift); this one takes the typed pointers of the
// original API, hence the casts.
extension MoonlightLibrary.Functions {
    nonisolated static let slot0 = MoonlightLibrary.Functions(
        startConnection: { serverInfo, streamConfig, connectionCallbacks, videoCallbacks, audioCallbacks in
            LiStartConnection(
                serverInfo.assumingMemoryBound(to: SERVER_INFORMATION.self),
                streamConfig.assumingMemoryBound(to: STREAM_CONFIGURATION.self),
                connectionCallbacks.assumingMemoryBound(to: CONNECTION_LISTENER_CALLBACKS.self),
                videoCallbacks.assumingMemoryBound(to: DECODER_RENDERER_CALLBACKS.self),
                audioCallbacks.assumingMemoryBound(to: AUDIO_RENDERER_CALLBACKS.self),
                nil, 0, nil, 0
            )
        },
        stopConnection: { LiStopConnection() },
        interruptConnection: { LiInterruptConnection() },
        stageName: { LiGetStageName($0) },
        estimatedRttInfo: { LiGetEstimatedRttInfo($0, $1) },
        hdrMetadata: { LiGetHdrMetadata($0.assumingMemoryBound(to: SS_HDR_METADATA.self)) },
        requestIdrFrame: { LiRequestIdrFrame() },
        sendMouseMove: { LiSendMouseMoveEvent($0, $1) },
        sendMousePosition: { LiSendMousePositionEvent($0, $1, $2, $3) },
        sendMouseButton: { LiSendMouseButtonEvent($0, $1) },
        sendKeyboard: { LiSendKeyboardEvent($0, $1, $2) },
        sendHighResScroll: { LiSendHighResScrollEvent($0) },
        sendHighResHScroll: { LiSendHighResHScrollEvent($0) },
        sendMultiController: { LiSendMultiControllerEvent($0, $1, $2, $3, $4, $5, $6, $7, $8) },
        sendControllerArrival: { LiSendControllerArrivalEvent($0, $1, $2, $3, $4) }
    )
}
#endif
