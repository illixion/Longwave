#if MOONLIGHT_ENABLED
import Foundation
import os
import AVFoundation
@preconcurrency import MoonlightCommonC

// MARK: - AV1 Bitstream Reader

/// Reads bits from a byte buffer at bit granularity for AV1 sequence header parsing.
private struct BitstreamReader {
    private let data: Data
    private var bitOffset: Int = 0

    init(_ data: Data) {
        self.data = data
    }

    var bitsRemaining: Int { data.count * 8 - bitOffset }

    mutating func readBits(_ n: Int) -> UInt32 {
        guard n > 0, n <= 32 else { return 0 }
        var result: UInt32 = 0
        for _ in 0..<n {
            let byteIndex = bitOffset / 8
            let bitIndex = 7 - (bitOffset % 8)
            guard byteIndex < data.count else { return result }
            let bit = (UInt32(data[byteIndex]) >> bitIndex) & 1
            result = (result << 1) | bit
            bitOffset += 1
        }
        return result
    }

    mutating func readBit() -> Bool {
        readBits(1) != 0
    }

    mutating func skipBits(_ n: Int) {
        bitOffset += n
    }

    /// Read unsigned variable-length coded value (AV1 uvlc)
    mutating func readUvlc() -> UInt32 {
        var leadingZeros = 0
        while bitsRemaining > 0 && !readBit() {
            leadingZeros += 1
            if leadingZeros >= 32 { return UInt32.max }
        }
        if leadingZeros >= 32 { return UInt32.max }
        let value = readBits(leadingZeros)
        return (1 << leadingZeros) - 1 + value
    }
}

// MARK: - AV1 Sequence Header

/// Parsed fields from an AV1 sequence header OBU needed for format description creation.
private struct AV1SequenceHeader {
    var seqProfile: UInt8 = 0
    var seqLevelIdx0: UInt8 = 0
    var seqTier0: UInt8 = 0
    var highBitDepth: Bool = false
    var twelveBit: Bool = false
    var monochrome: Bool = false
    var chromaSubsamplingX: UInt8 = 0
    var chromaSubsamplingY: UInt8 = 0
    var chromaSamplePosition: UInt8 = 0
    var colorDescriptionPresent: Bool = false
    var colorPrimaries: UInt8 = 2       // CP_UNSPECIFIED
    var transferCharacteristics: UInt8 = 2 // TC_UNSPECIFIED
    var matrixCoefficients: UInt8 = 2   // MC_UNSPECIFIED
    var colorRange: Bool = false        // false = limited, true = full
    var frameWidth: Int32 = 0
    var frameHeight: Int32 = 0

    var bitDepth: Int {
        twelveBit ? 12 : (highBitDepth ? 10 : 8)
    }
}

// MARK: - Video Renderer

/// Decodes H.264/HEVC/AV1 video from moonlight-common-c using AVSampleBufferDisplayLayer,
/// which handles both hardware decoding and display with native HDR support.
class MoonlightVideoRenderer: @unchecked Sendable {
    /// Display layer for hardware-accelerated video decode and display.
    /// Created on the main thread by MoonlightConnectionManager, set before streaming starts.
    nonisolated(unsafe) var displayLayer: AVSampleBufferDisplayLayer?

    private nonisolated(unsafe) var formatDescription: CMVideoFormatDescription?
    private nonisolated(unsafe) var videoFormat: Int32 = 0
    nonisolated(unsafe) var frameCount: UInt64 = 0

    // Stats tracking
    nonisolated(unsafe) var totalDecodeTimeMs: Double = 0
    nonisolated(unsafe) var lastDecodeTimeMs: Double = 0
    nonisolated(unsafe) var droppedFrames: UInt64 = 0

    /// Whether the current stream has HDR active (set by server callback)
    nonisolated(unsafe) var isHDRContent: Bool = false

    // Cached parameter sets for H.264/HEVC format descriptions
    private nonisolated(unsafe) var currentSPS: Data?
    private nonisolated(unsafe) var currentPPS: Data?
    private nonisolated(unsafe) var currentVPS: Data?  // HEVC only

    // AV1 cached state
    private nonisolated(unsafe) var currentAV1SequenceHeader: AV1SequenceHeader?
    private nonisolated(unsafe) var currentAV1RawSequenceHeaderOBU: Data?

    // HDR metadata packed as binary for format description extensions
    private nonisolated(unsafe) var contentLightLevelInfo: Data?
    private nonisolated(unsafe) var masteringDisplayColorVolume: Data?

    nonisolated init() {}

    nonisolated func setup(videoFormat: Int32, width: Int32, height: Int32, fps: Int32) -> Int32 {
        self.videoFormat = videoFormat
        self.formatDescription = nil
        self.currentSPS = nil
        self.currentPPS = nil
        self.currentVPS = nil
        self.currentAV1SequenceHeader = nil
        self.currentAV1RawSequenceHeaderOBU = nil
        self.frameCount = 0
        self.isHDRContent = false
        self.contentLightLevelInfo = nil
        self.masteringDisplayColorVolume = nil

        let codecName: String
        if (videoFormat & VIDEO_FORMAT_MASK_AV1) != 0 {
            codecName = "AV1"
        } else if (videoFormat & VIDEO_FORMAT_MASK_H265) != 0 {
            codecName = "HEVC"
        } else {
            codecName = "H.264"
        }
        let is10Bit = (videoFormat & Int32(VIDEO_FORMAT_MASK_10BIT)) != 0
        AppLog.moonlightVideo.line("Setup: \(width)x\(height)@\(fps) format=0x\(String(videoFormat, radix: 16)) (\(codecName)\(is10Bit ? " 10-bit" : ""))")

        return 0
    }

    nonisolated func start() {
        AppLog.moonlightVideo.line("Start")
    }

    nonisolated func stop() {
        AppLog.moonlightVideo.line("Stop")
    }

    nonisolated func cleanup() {
        formatDescription = nil
        currentSPS = nil
        currentPPS = nil
        currentVPS = nil
        currentAV1SequenceHeader = nil
        currentAV1RawSequenceHeaderOBU = nil
        contentLightLevelInfo = nil
        masteringDisplayColorVolume = nil
    }

    // MARK: - HDR Metadata

    /// Called when the server signals an HDR mode change.
    /// Retrieves HDR metadata and packs it as binary for format description extensions.
    nonisolated func setHdrMode(_ enabled: Bool) {
        let wasHDR = isHDRContent
        isHDRContent = enabled
        AppLog.moonlightVideo.line("HDR mode: \(enabled)")

        if enabled {
            var metadata = SS_HDR_METADATA()
            if LiGetHdrMetadata(&metadata) {
                // Pack MDCV and CLL from SS_HDR_METADATA
                // displayPrimaries[3] is RGB order; MDCV spec requires GBR order
                packHdrMetadata(&metadata)
            }
        } else {
            masteringDisplayColorVolume = nil
            contentLightLevelInfo = nil
        }

        // Request IDR to rebuild format description with updated HDR metadata
        if wasHDR != enabled {
            formatDescription = nil
            displayLayer?.flush()
            LiRequestIdrFrame()
        }
    }

    // MARK: - Decode Unit Dispatch

    /// Process a decode unit from moonlight-common-c. Called from a background thread.
    nonisolated func submitDecodeUnit(_ du: UnsafeMutablePointer<DECODE_UNIT>) -> Int32 {
        // Track HDR state from per-frame metadata
        let hdrActive = du.pointee.hdrActive
        if hdrActive != isHDRContent {
            isHDRContent = hdrActive
            AppLog.moonlightVideo.line("HDR state changed: \(hdrActive ? "active" : "inactive")")
        }

        if (videoFormat & VIDEO_FORMAT_MASK_AV1) != 0 {
            return submitAV1DecodeUnit(du)
        } else {
            return submitH264HevcDecodeUnit(du)
        }
    }

    // MARK: - H.264/HEVC Decode Path

    private nonisolated func submitH264HevcDecodeUnit(_ du: UnsafeMutablePointer<DECODE_UNIT>) -> Int32 {
        let processStart = CACurrentMediaTime()

        var spsData: Data?
        var ppsData: Data?
        var vpsData: Data?
        var pictureData = Data()
        var currentNAL = Data()

        // Walk the LENTRY linked list.
        // moonlight-common-c splits large NAL units across multiple LENTRYs for network
        // packet alignment. Only the first entry of a NAL has an Annex B start code;
        // subsequent entries (startCode=0) are continuation data for the same NAL.
        var entry = du.pointee.bufferList
        while let e = entry {
            let length = Int(e.pointee.length)
            guard length > 0, let dataPtr = e.pointee.data else {
                entry = e.pointee.next
                continue
            }

            let rawData = Data(bytes: dataPtr, count: length)
            let startCodeLen = detectStartCodeLength(rawData)

            switch e.pointee.bufferType {
            case BUFFER_TYPE_SPS:
                spsData = Data(rawData.dropFirst(startCodeLen))
            case BUFFER_TYPE_PPS:
                ppsData = Data(rawData.dropFirst(startCodeLen))
            case BUFFER_TYPE_VPS:
                vpsData = Data(rawData.dropFirst(startCodeLen))
            default:
                if startCodeLen > 0 {
                    if !currentNAL.isEmpty {
                        var nalLength = UInt32(currentNAL.count).bigEndian
                        pictureData.append(Data(bytes: &nalLength, count: 4))
                        pictureData.append(currentNAL)
                    }
                    currentNAL = Data(rawData.dropFirst(startCodeLen))
                } else {
                    currentNAL.append(rawData)
                }
            }

            entry = e.pointee.next
        }

        if !currentNAL.isEmpty {
            var nalLength = UInt32(currentNAL.count).bigEndian
            pictureData.append(Data(bytes: &nalLength, count: 4))
            pictureData.append(currentNAL)
        }

        // Update format description if we got new parameter sets
        if let sps = spsData, let pps = ppsData {
            let spsChanged = (currentSPS != sps)
            let ppsChanged = (currentPPS != pps)
            let vpsChanged = (vpsData != nil && currentVPS != vpsData)

            if spsChanged || ppsChanged || vpsChanged || formatDescription == nil {
                currentSPS = sps
                currentPPS = pps
                if let vps = vpsData {
                    currentVPS = vps
                }
                updateH264HevcFormatDescription()
                // Flush display layer when format changes
                displayLayer?.flush()
            }
        }

        guard !pictureData.isEmpty, let fmtDesc = formatDescription else {
            if frameCount == 0 {
                AppLog.moonlightVideo.line("No format description yet, requesting IDR")
            }
            return DR_NEED_IDR
        }

        let pts = CMTimeMake(value: Int64(du.pointee.rtpTimestamp), timescale: 90000)
        guard let sampleBuffer = createSampleBuffer(
            from: pictureData, formatDescription: fmtDesc, pts: pts
        ) else {
            return DR_OK
        }

        let result = enqueueToDisplayLayer(sampleBuffer)

        let elapsed = (CACurrentMediaTime() - processStart) * 1000.0
        lastDecodeTimeMs = elapsed
        totalDecodeTimeMs += elapsed

        return result
    }

    // MARK: - AV1 Decode Path

    private nonisolated func submitAV1DecodeUnit(_ du: UnsafeMutablePointer<DECODE_UNIT>) -> Int32 {
        let processStart = CACurrentMediaTime()

        // Concatenate all LENTRY buffers into a single Data.
        // AV1 data arrives as raw OBUs — no Annex B start codes, all BUFFER_TYPE_PICDATA.
        var frameData = Data()
        var entry = du.pointee.bufferList
        while let e = entry {
            let length = Int(e.pointee.length)
            guard length > 0, let dataPtr = e.pointee.data else {
                entry = e.pointee.next
                continue
            }
            dataPtr.withMemoryRebound(to: UInt8.self, capacity: length) { ptr in
                frameData.append(ptr, count: length)
            }
            entry = e.pointee.next
        }

        guard !frameData.isEmpty else { return DR_NEED_IDR }

        // On IDR frames, look for the sequence header OBU and create/update format description
        if du.pointee.frameType == FRAME_TYPE_IDR || formatDescription == nil {
            if let (seqHeader, rawSeqOBU) = parseAV1SequenceHeader(from: frameData) {
                let needsUpdate = (formatDescription == nil) ||
                    (rawSeqOBU != currentAV1RawSequenceHeaderOBU)

                if needsUpdate {
                    currentAV1SequenceHeader = seqHeader
                    currentAV1RawSequenceHeaderOBU = rawSeqOBU
                    if let desc = createAV1FormatDescription(
                        sequenceHeader: seqHeader,
                        rawSequenceHeaderOBU: rawSeqOBU
                    ) {
                        formatDescription = desc
                        // Flush display layer when format changes
                        displayLayer?.flush()
                    }
                }
            } else if formatDescription == nil {
                if frameCount == 0 {
                    AppLog.moonlightVideo.line("AV1: No sequence header found, requesting IDR")
                }
                return DR_NEED_IDR
            }
        }

        guard let fmtDesc = formatDescription else { return DR_NEED_IDR }

        let pts = CMTimeMake(value: Int64(du.pointee.rtpTimestamp), timescale: 90000)
        guard let sampleBuffer = createSampleBuffer(
            from: frameData, formatDescription: fmtDesc, pts: pts
        ) else {
            return DR_OK
        }

        let result = enqueueToDisplayLayer(sampleBuffer)

        let elapsed = (CACurrentMediaTime() - processStart) * 1000.0
        lastDecodeTimeMs = elapsed
        totalDecodeTimeMs += elapsed

        return result
    }

    // MARK: - Display Layer Enqueue

    /// Enqueue a sample buffer to the display layer for decode and display.
    private nonisolated func enqueueToDisplayLayer(_ sampleBuffer: CMSampleBuffer) -> Int32 {
        guard let layer = displayLayer else { return DR_NEED_IDR }

        if layer.status == .failed {
            AppLog.moonlightVideo.line("Display layer failed: \(layer.error?.localizedDescription ?? "unknown")")
            layer.flush()
            formatDescription = nil
            return DR_NEED_IDR
        }

        layer.enqueue(sampleBuffer)

        frameCount += 1
        if frameCount == 1 {
            AppLog.moonlightVideo.line("First frame enqueued!")
        } else if frameCount % 300 == 0 {
            AppLog.moonlightVideo.line("Frame \(frameCount) enqueued")
        }

        return DR_OK
    }

    // MARK: - H.264/HEVC Format Description

    private nonisolated func updateH264HevcFormatDescription() {
        guard let sps = currentSPS, let pps = currentPPS else { return }

        var newFmtDesc: CMVideoFormatDescription?
        var status: OSStatus

        let isHEVC = (videoFormat & VIDEO_FORMAT_MASK_H265) != 0

        if isHEVC, let vps = currentVPS {
            // Build extensions dict with HDR metadata for HEVC
            var extensions: [String: Any] = [:]
            if let mdcv = masteringDisplayColorVolume {
                extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String] = mdcv
            }
            if let cll = contentLightLevelInfo {
                extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] = cll
            }
            let extensionsDict: CFDictionary? = extensions.isEmpty ? nil : extensions as CFDictionary

            status = vps.withUnsafeBytes { vpsPtr in
                sps.withUnsafeBytes { spsPtr in
                    pps.withUnsafeBytes { ppsPtr in
                        let parameterSetPointers: [UnsafePointer<UInt8>] = [
                            vpsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                            ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        ]
                        let parameterSetSizes: [Int] = [vps.count, sps.count, pps.count]
                        return parameterSetPointers.withUnsafeBufferPointer { ptrsBuffer in
                            parameterSetSizes.withUnsafeBufferPointer { sizesBuffer in
                                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                                    allocator: kCFAllocatorDefault,
                                    parameterSetCount: 3,
                                    parameterSetPointers: ptrsBuffer.baseAddress!,
                                    parameterSetSizes: sizesBuffer.baseAddress!,
                                    nalUnitHeaderLength: 4,
                                    extensions: extensionsDict,
                                    formatDescriptionOut: &newFmtDesc
                                )
                            }
                        }
                    }
                }
            }
        } else {
            status = sps.withUnsafeBytes { spsPtr in
                pps.withUnsafeBytes { ppsPtr in
                    let parameterSetPointers: [UnsafePointer<UInt8>] = [
                        spsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        ppsPtr.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ]
                    let parameterSetSizes: [Int] = [sps.count, pps.count]
                    return parameterSetPointers.withUnsafeBufferPointer { ptrsBuffer in
                        parameterSetSizes.withUnsafeBufferPointer { sizesBuffer in
                            CMVideoFormatDescriptionCreateFromH264ParameterSets(
                                allocator: kCFAllocatorDefault,
                                parameterSetCount: 2,
                                parameterSetPointers: ptrsBuffer.baseAddress!,
                                parameterSetSizes: sizesBuffer.baseAddress!,
                                nalUnitHeaderLength: 4,
                                formatDescriptionOut: &newFmtDesc
                            )
                        }
                    }
                }
            }
        }

        if status == noErr, let desc = newFmtDesc {
            formatDescription = desc
            let dimensions = CMVideoFormatDescriptionGetDimensions(desc)
            AppLog.moonlightVideo.line("Format description created: \(dimensions.width)x\(dimensions.height)\(masteringDisplayColorVolume != nil ? " (HDR)" : "")")
        } else {
            AppLog.moonlightVideo.line("Failed to create format description: OSStatus \(status)")
        }
    }

    // MARK: - AV1 Format Description

    private nonisolated func createAV1FormatDescription(
        sequenceHeader: AV1SequenceHeader,
        rawSequenceHeaderOBU: Data
    ) -> CMVideoFormatDescription? {
        var extensions: [String: Any] = [:]

        // av1C configuration record
        let av1cData = buildAV1ConfigurationRecord(
            sequenceHeader: sequenceHeader,
            rawSequenceHeaderOBU: rawSequenceHeaderOBU
        )
        extensions[kCMFormatDescriptionExtension_SampleDescriptionExtensionAtoms as String] =
            ["av1C": av1cData]

        // Color primaries
        if sequenceHeader.colorDescriptionPresent {
            switch sequenceHeader.colorPrimaries {
            case 1:  // CP_BT_709
                extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] =
                    kCMFormatDescriptionColorPrimaries_ITU_R_709_2
            case 9:  // CP_BT_2020
                extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] =
                    kCMFormatDescriptionColorPrimaries_ITU_R_2020
            case 6, 7:  // CP_BT_601 variants
                extensions[kCMFormatDescriptionExtension_ColorPrimaries as String] =
                    kCMFormatDescriptionColorPrimaries_SMPTE_C
            default: break
            }

            // Transfer function
            switch sequenceHeader.transferCharacteristics {
            case 1, 6:  // TC_BT_709, TC_BT_601
                extensions[kCMFormatDescriptionExtension_TransferFunction as String] =
                    kCMFormatDescriptionTransferFunction_ITU_R_709_2
            case 16:    // TC_SMPTE_2084 (PQ / HDR10)
                extensions[kCMFormatDescriptionExtension_TransferFunction as String] =
                    kCMFormatDescriptionTransferFunction_SMPTE_ST_2084_PQ
            case 18:    // TC_HLG
                extensions[kCMFormatDescriptionExtension_TransferFunction as String] =
                    kCMFormatDescriptionTransferFunction_ITU_R_2100_HLG
            default: break
            }

            // YCbCr matrix
            switch sequenceHeader.matrixCoefficients {
            case 1:  // MC_BT_709
                extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] =
                    kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
            case 6:  // MC_BT_601
                extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] =
                    kCMFormatDescriptionYCbCrMatrix_ITU_R_601_4
            case 9:  // MC_BT_2020_NCL
                extensions[kCMFormatDescriptionExtension_YCbCrMatrix as String] =
                    kCMFormatDescriptionYCbCrMatrix_ITU_R_2020
            default: break
            }
        }

        // Full range video
        extensions[kCMFormatDescriptionExtension_FullRangeVideo as String] = sequenceHeader.colorRange

        // Progressive content
        extensions[kCMFormatDescriptionExtension_FieldCount as String] = 1

        // Chroma location
        if sequenceHeader.chromaSamplePosition == 1 {
            extensions[kCMFormatDescriptionExtension_ChromaLocationTopField as String] =
                kCMFormatDescriptionChromaLocation_Left
        } else if sequenceHeader.chromaSamplePosition == 2 {
            extensions[kCMFormatDescriptionExtension_ChromaLocationTopField as String] =
                kCMFormatDescriptionChromaLocation_TopLeft
        }

        // HDR metadata
        if let mdcv = masteringDisplayColorVolume {
            extensions[kCMFormatDescriptionExtension_MasteringDisplayColorVolume as String] = mdcv
        }
        if let cll = contentLightLevelInfo {
            extensions[kCMFormatDescriptionExtension_ContentLightLevelInfo as String] = cll
        }

        var formatDesc: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            codecType: kCMVideoCodecType_AV1,
            width: sequenceHeader.frameWidth,
            height: sequenceHeader.frameHeight,
            extensions: extensions as CFDictionary,
            formatDescriptionOut: &formatDesc
        )

        if status == noErr, let desc = formatDesc {
            let dims = CMVideoFormatDescriptionGetDimensions(desc)
            AppLog.moonlightVideo.line("AV1 format description: \(dims.width)x\(dims.height), \(sequenceHeader.bitDepth)-bit\(masteringDisplayColorVolume != nil ? " (HDR)" : "")")
            return desc
        } else {
            AppLog.moonlightVideo.line("AV1 format description failed: OSStatus \(status)")
            return nil
        }
    }

    /// Builds the AV1 Codec Configuration Record (av1C) per ISO 14496-12.
    private nonisolated func buildAV1ConfigurationRecord(
        sequenceHeader: AV1SequenceHeader,
        rawSequenceHeaderOBU: Data
    ) -> Data {
        var av1c = Data(capacity: 4 + rawSequenceHeaderOBU.count)

        // Byte 0: marker(1) = 1, version(7) = 1
        av1c.append(0x81)

        // Byte 1: seq_profile(3) | seq_level_idx_0(5)
        av1c.append((sequenceHeader.seqProfile << 5) | (sequenceHeader.seqLevelIdx0 & 0x1F))

        // Byte 2: tier(1) | high_bitdepth(1) | twelve_bit(1) | monochrome(1) |
        //          sub_x(1) | sub_y(1) | chroma_pos(2)
        var byte2: UInt8 = 0
        byte2 |= (sequenceHeader.seqTier0 & 1) << 7
        byte2 |= (sequenceHeader.highBitDepth ? 1 : 0) << 6
        byte2 |= (sequenceHeader.twelveBit ? 1 : 0) << 5
        byte2 |= (sequenceHeader.monochrome ? 1 : 0) << 4
        byte2 |= (sequenceHeader.chromaSubsamplingX & 1) << 3
        byte2 |= (sequenceHeader.chromaSubsamplingY & 1) << 2
        byte2 |= (sequenceHeader.chromaSamplePosition & 3)
        av1c.append(byte2)

        // Byte 3: reserved(3)=0 | initial_presentation_delay_present(1)=0 | reserved(4)=0
        av1c.append(0x00)

        // Append raw sequence header OBU
        av1c.append(rawSequenceHeaderOBU)

        return av1c
    }

    // MARK: - AV1 OBU Parsing

    /// Parse AV1 OBUs from frame data to find and extract the sequence header.
    /// Returns the parsed header and the raw sequence header OBU bytes if found.
    private nonisolated func parseAV1SequenceHeader(from data: Data) -> (AV1SequenceHeader, Data)? {
        var offset = 0

        while offset < data.count {
            let obuStart = offset
            guard offset < data.count else { break }

            // OBU header byte
            let headerByte = data[offset]
            offset += 1

            let obuType = (headerByte >> 3) & 0x0F
            let extensionFlag = (headerByte >> 2) & 1
            let hasSizeField = (headerByte >> 1) & 1

            // Extension byte (skip if present)
            if extensionFlag != 0 {
                guard offset < data.count else { break }
                offset += 1
            }

            // OBU size (LEB128 encoded)
            var obuSize: Int = 0
            if hasSizeField != 0 {
                var shift = 0
                while offset < data.count {
                    let byte = data[offset]
                    offset += 1
                    obuSize |= Int(byte & 0x7F) << shift
                    if byte & 0x80 == 0 { break }
                    shift += 7
                    if shift >= 28 { break }
                }
            } else {
                // Without size field, the OBU extends to end of data
                obuSize = data.count - offset
            }

            let obuPayloadStart = offset
            let obuEnd = min(offset + obuSize, data.count)

            if obuType == 1 {
                // OBU_SEQUENCE_HEADER
                let rawOBU = data[obuStart..<obuEnd]
                let payloadData = data[obuPayloadStart..<obuEnd]

                if let seqHeader = parseSequenceHeaderPayload(Data(payloadData)) {
                    AppLog.moonlightVideo.line("AV1 sequence header: \(seqHeader.frameWidth)x\(seqHeader.frameHeight), \(seqHeader.bitDepth)-bit, profile=\(seqHeader.seqProfile)")
                    return (seqHeader, Data(rawOBU))
                }
            }

            offset = obuEnd
        }

        return nil
    }

    /// Parse the payload of an AV1 sequence header OBU (AV1 spec Section 5.5).
    private nonisolated func parseSequenceHeaderPayload(_ data: Data) -> AV1SequenceHeader? {
        var reader = BitstreamReader(data)
        var header = AV1SequenceHeader()

        guard reader.bitsRemaining >= 24 else { return nil }

        header.seqProfile = UInt8(reader.readBits(3))
        let _stillPicture = reader.readBit()
        let reducedStillPictureHeader = reader.readBit()

        if reducedStillPictureHeader {
            header.seqLevelIdx0 = UInt8(reader.readBits(5))
            header.seqTier0 = 0
        } else {
            let timingInfoPresent = reader.readBit()
            if timingInfoPresent {
                // timing_info()
                reader.skipBits(32)  // num_units_in_display_tick
                reader.skipBits(32)  // time_scale
                let equalPictureInterval = reader.readBit()
                if equalPictureInterval {
                    _ = reader.readUvlc()  // num_ticks_per_picture_minus_1
                }

                let decoderModelInfoPresent = reader.readBit()
                if decoderModelInfoPresent {
                    reader.skipBits(5)  // buffer_delay_length_minus_1
                    reader.skipBits(32) // num_units_in_decoding_tick
                    reader.skipBits(5)  // buffer_removal_time_length_minus_1
                    reader.skipBits(5)  // frame_presentation_time_length_minus_1
                }
            }

            let initialDisplayDelayPresent = reader.readBit()
            let operatingPointsCntMinus1 = reader.readBits(5)

            for i in 0...operatingPointsCntMinus1 {
                reader.skipBits(12)  // operating_point_idc
                let seqLevelIdx = UInt8(reader.readBits(5))
                var seqTier: UInt8 = 0
                if seqLevelIdx > 7 {
                    seqTier = UInt8(reader.readBits(1))
                }
                if i == 0 {
                    header.seqLevelIdx0 = seqLevelIdx
                    header.seqTier0 = seqTier
                }

                if timingInfoPresent {
                    let decoderModelPresent = reader.readBit()
                    if decoderModelPresent {
                        reader.skipBits(10 + 10 + 1)  // encoder/decoder buffer delay + low_delay_mode
                    }
                }

                if initialDisplayDelayPresent {
                    let hasDisplayDelay = reader.readBit()
                    if hasDisplayDelay {
                        reader.skipBits(4)  // initial_display_delay_minus_1
                    }
                }
            }
        }

        guard reader.bitsRemaining >= 12 else { return nil }

        // Frame size
        let frameWidthBitsMinus1 = reader.readBits(4)
        let frameHeightBitsMinus1 = reader.readBits(4)
        header.frameWidth = Int32(reader.readBits(Int(frameWidthBitsMinus1) + 1)) + 1
        header.frameHeight = Int32(reader.readBits(Int(frameHeightBitsMinus1) + 1)) + 1

        if !reducedStillPictureHeader {
            let frameIdNumbersPresent = reader.readBit()
            if frameIdNumbersPresent {
                reader.skipBits(4)  // delta_frame_id_length_minus_2
                reader.skipBits(3)  // additional_frame_id_length_minus_1
            }
        }

        // Skip feature flags
        reader.skipBits(1)  // use_128x128_superblock
        reader.skipBits(1)  // enable_filter_intra
        reader.skipBits(1)  // enable_intra_edge_filter

        if !reducedStillPictureHeader {
            reader.skipBits(1)  // enable_interintra_compound
            reader.skipBits(1)  // enable_masked_compound
            reader.skipBits(1)  // enable_warped_motion
            reader.skipBits(1)  // enable_dual_filter
            let enableOrderHint = reader.readBit()
            if enableOrderHint {
                reader.skipBits(1)  // enable_jnt_comp
                reader.skipBits(1)  // enable_ref_frame_mvs
            }
            let seqChooseScreenContentTools = reader.readBit()
            var seqForceScreenContentTools: UInt32 = 2  // SELECT_SCREEN_CONTENT_TOOLS
            if !seqChooseScreenContentTools {
                seqForceScreenContentTools = reader.readBits(1)
            }
            if seqForceScreenContentTools > 0 {
                let seqChooseIntegerMv = reader.readBit()
                if !seqChooseIntegerMv {
                    reader.skipBits(1)  // seq_force_integer_mv
                }
            }
            if enableOrderHint {
                reader.skipBits(3)  // order_hint_bits_minus_1
            }
        }

        reader.skipBits(1)  // enable_superres
        reader.skipBits(1)  // enable_cdef
        reader.skipBits(1)  // enable_restoration

        // color_config() — Section 5.5.2
        guard reader.bitsRemaining >= 4 else { return nil }

        header.highBitDepth = reader.readBit()
        if header.seqProfile == 2 && header.highBitDepth {
            header.twelveBit = reader.readBit()
        }

        if header.seqProfile != 1 {
            header.monochrome = reader.readBit()
        }

        header.colorDescriptionPresent = reader.readBit()
        if header.colorDescriptionPresent {
            header.colorPrimaries = UInt8(reader.readBits(8))
            header.transferCharacteristics = UInt8(reader.readBits(8))
            header.matrixCoefficients = UInt8(reader.readBits(8))
        } else {
            header.colorPrimaries = 2       // CP_UNSPECIFIED
            header.transferCharacteristics = 2 // TC_UNSPECIFIED
            header.matrixCoefficients = 2   // MC_UNSPECIFIED
        }

        if header.monochrome {
            header.colorRange = reader.readBit()
            header.chromaSubsamplingX = 1
            header.chromaSubsamplingY = 1
        } else if header.colorPrimaries == 1 && header.transferCharacteristics == 13 &&
                    header.matrixCoefficients == 0 {
            // sRGB / BT.709 + identity matrix = RGB 4:4:4
            header.colorRange = true
            header.chromaSubsamplingX = 0
            header.chromaSubsamplingY = 0
        } else {
            header.colorRange = reader.readBit()
            if header.seqProfile == 0 {
                header.chromaSubsamplingX = 1
                header.chromaSubsamplingY = 1
            } else if header.seqProfile == 1 {
                header.chromaSubsamplingX = 0
                header.chromaSubsamplingY = 0
            } else {
                // Profile 2
                if header.bitDepth == 12 {
                    header.chromaSubsamplingX = UInt8(reader.readBits(1))
                    if header.chromaSubsamplingX != 0 {
                        header.chromaSubsamplingY = UInt8(reader.readBits(1))
                    }
                } else {
                    header.chromaSubsamplingX = 1
                    header.chromaSubsamplingY = 0
                }
            }

            if header.chromaSubsamplingX != 0 && header.chromaSubsamplingY != 0 {
                header.chromaSamplePosition = UInt8(reader.readBits(2))
            }
        }

        return header
    }

    // MARK: - Sample Buffer Creation

    private nonisolated func createSampleBuffer(
        from pictureData: Data,
        formatDescription: CMVideoFormatDescription,
        pts: CMTime
    ) -> CMSampleBuffer? {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: pictureData.count,
            blockAllocator: nil,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: pictureData.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )

        guard status == kCMBlockBufferNoErr, let buffer = blockBuffer else { return nil }

        pictureData.withUnsafeBytes { ptr in
            guard let baseAddress = ptr.baseAddress else { return }
            CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: buffer,
                offsetIntoDestination: 0,
                dataLength: pictureData.count
            )
        }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = pictureData.count
        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )

        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: buffer,
            formatDescription: formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )

        guard status == noErr, let sb = sampleBuffer else {
            AppLog.moonlightVideo.line("Failed to create sample buffer: OSStatus \(status)")
            return nil
        }

        return sb
    }

    // MARK: - Helpers

    /// Detect Annex B start code length (3 or 4 bytes)
    private nonisolated func detectStartCodeLength(_ data: Data) -> Int {
        guard data.count >= 4 else { return 0 }
        if data[0] == 0x00 && data[1] == 0x00 && data[2] == 0x00 && data[3] == 0x01 {
            return 4
        }
        if data[0] == 0x00 && data[1] == 0x00 && data[2] == 0x01 {
            return 3
        }
        return 0
    }

    /// Pack SS_HDR_METADATA into MDCV and CLL binary data for format description extensions.
    /// Uses raw memory access because Swift imports the C anonymous struct array differently.
    private nonisolated func packHdrMetadata(_ metadata: UnsafePointer<SS_HDR_METADATA>) {
        // SS_HDR_METADATA memory layout (all UInt16):
        // offset 0:  displayPrimaries[0].x (Red)
        // offset 2:  displayPrimaries[0].y (Red)
        // offset 4:  displayPrimaries[1].x (Green)
        // offset 6:  displayPrimaries[1].y (Green)
        // offset 8:  displayPrimaries[2].x (Blue)
        // offset 10: displayPrimaries[2].y (Blue)
        // offset 12: whitePoint.x
        // offset 14: whitePoint.y
        // offset 16: maxDisplayLuminance
        // offset 18: minDisplayLuminance
        // offset 20: maxContentLightLevel
        // offset 22: maxFrameAverageLightLevel
        // offset 24: maxFullFrameLuminance
        let raw = UnsafeRawPointer(metadata)
        let fields = raw.bindMemory(to: UInt16.self, capacity: 13)

        let redX = fields[0], redY = fields[1]
        let greenX = fields[2], greenY = fields[3]
        let blueX = fields[4], blueY = fields[5]
        let wpX = fields[6], wpY = fields[7]
        let maxLum = fields[8], minLum = fields[9]
        let maxCLL = fields[10], maxFALL = fields[11]

        // Pack Mastering Display Color Volume (MDCV) - 24 bytes big-endian
        // MDCV spec requires GBR order (not RGB)
        var mdcv = Data(capacity: 24)
        appendBigEndianUInt16(&mdcv, greenX)
        appendBigEndianUInt16(&mdcv, greenY)
        appendBigEndianUInt16(&mdcv, blueX)
        appendBigEndianUInt16(&mdcv, blueY)
        appendBigEndianUInt16(&mdcv, redX)
        appendBigEndianUInt16(&mdcv, redY)
        appendBigEndianUInt16(&mdcv, wpX)
        appendBigEndianUInt16(&mdcv, wpY)
        // Max luminance in 1/10000th of a nit
        appendBigEndianUInt32(&mdcv, UInt32(maxLum) * 10000)
        // Min luminance (already in 1/10000th of a nit)
        appendBigEndianUInt32(&mdcv, UInt32(minLum))
        masteringDisplayColorVolume = mdcv

        // Pack Content Light Level (CLL) - 4 bytes big-endian
        var cll = Data(capacity: 4)
        appendBigEndianUInt16(&cll, maxCLL)
        appendBigEndianUInt16(&cll, maxFALL)
        contentLightLevelInfo = cll

        AppLog.moonlightVideo.line("HDR metadata: maxCLL=\(maxCLL), maxFALL=\(maxFALL), maxLum=\(maxLum)")
    }

    private nonisolated func appendBigEndianUInt16(_ data: inout Data, _ value: UInt16) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }

    private nonisolated func appendBigEndianUInt32(_ data: inout Data, _ value: UInt32) {
        withUnsafeBytes(of: value.bigEndian) { data.append(contentsOf: $0) }
    }
}
#endif
