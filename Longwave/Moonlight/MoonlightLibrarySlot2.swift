#if MOONLIGHT_ENABLED
import MoonlightCommonC2

// The entry points of linked copy 2 of moonlight-common-c. Its module exposes
// only these functions, under the ml2_ prefix and with every struct pointer
// as a raw pointer — the C types live once, in MoonlightCommonC, and the
// callers build them there (see make-instances.sh for why the copies must not
// redeclare them). MoonlightLibrarySlot1.swift and MoonlightLibrarySlot2.swift
// are identical apart from the prefix; edit them together.
extension MoonlightLibrary.Functions {
    nonisolated static let slot2 = MoonlightLibrary.Functions(
        startConnection: { serverInfo, streamConfig, connectionCallbacks, videoCallbacks, audioCallbacks in
            ml2_LiStartConnection(serverInfo, streamConfig, connectionCallbacks, videoCallbacks, audioCallbacks, nil, 0, nil, 0)
        },
        stopConnection: { ml2_LiStopConnection() },
        interruptConnection: { ml2_LiInterruptConnection() },
        stageName: { ml2_LiGetStageName($0) },
        estimatedRttInfo: { ml2_LiGetEstimatedRttInfo($0, $1) },
        hdrMetadata: { ml2_LiGetHdrMetadata($0) },
        requestIdrFrame: { ml2_LiRequestIdrFrame() },
        sendMouseMove: { ml2_LiSendMouseMoveEvent($0, $1) },
        sendMousePosition: { ml2_LiSendMousePositionEvent($0, $1, $2, $3) },
        sendMouseButton: { ml2_LiSendMouseButtonEvent($0, $1) },
        sendKeyboard: { ml2_LiSendKeyboardEvent($0, $1, $2) },
        sendHighResScroll: { ml2_LiSendHighResScrollEvent($0) },
        sendHighResHScroll: { ml2_LiSendHighResHScrollEvent($0) },
        sendMultiController: { ml2_LiSendMultiControllerEvent($0, $1, $2, $3, $4, $5, $6, $7, $8) },
        sendControllerArrival: { ml2_LiSendControllerArrivalEvent($0, $1, $2, $3, $4) }
    )
}
#endif
