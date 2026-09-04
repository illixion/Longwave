#if MOONLIGHT_ENABLED
import MoonlightCommonC1

// The entry points of linked copy 1 of moonlight-common-c. Its module exposes
// only these functions, under the ml1_ prefix and with every struct pointer
// as a raw pointer — the C types live once, in MoonlightCommonC, and the
// callers build them there (see make-instances.sh for why the copies must not
// redeclare them). MoonlightLibrarySlot1.swift and MoonlightLibrarySlot2.swift
// are identical apart from the prefix; edit them together.
extension MoonlightLibrary.Functions {
    nonisolated static let slot1 = MoonlightLibrary.Functions(
        startConnection: { serverInfo, streamConfig, connectionCallbacks, videoCallbacks, audioCallbacks in
            ml1_LiStartConnection(serverInfo, streamConfig, connectionCallbacks, videoCallbacks, audioCallbacks, nil, 0, nil, 0)
        },
        stopConnection: { ml1_LiStopConnection() },
        interruptConnection: { ml1_LiInterruptConnection() },
        stageName: { ml1_LiGetStageName($0) },
        estimatedRttInfo: { ml1_LiGetEstimatedRttInfo($0, $1) },
        hdrMetadata: { ml1_LiGetHdrMetadata($0) },
        requestIdrFrame: { ml1_LiRequestIdrFrame() },
        sendMouseMove: { ml1_LiSendMouseMoveEvent($0, $1) },
        sendMousePosition: { ml1_LiSendMousePositionEvent($0, $1, $2, $3) },
        sendMouseButton: { ml1_LiSendMouseButtonEvent($0, $1) },
        sendKeyboard: { ml1_LiSendKeyboardEvent($0, $1, $2) },
        sendHighResScroll: { ml1_LiSendHighResScrollEvent($0) },
        sendHighResHScroll: { ml1_LiSendHighResHScrollEvent($0) },
        sendMultiController: { ml1_LiSendMultiControllerEvent($0, $1, $2, $3, $4, $5, $6, $7, $8) },
        sendControllerArrival: { ml1_LiSendControllerArrivalEvent($0, $1, $2, $3, $4) }
    )
}
#endif
