import Foundation

/// Framing shared by the macOS native screen host and the visionOS viewer.
/// The transport is authenticated before these frames are accepted.
nonisolated enum MacNativeStreamProtocol {
    static let defaultPort: UInt16 = 4857
    static let frameLengthPrefixSize = 4
    static let maxFrameBytes: UInt32 = 64 * 1024 * 1024

    enum FrameType: UInt8, Sendable {
        case keepAlive = 0x07
        case hello = 0x10
        case helloAck = 0x11
        case formatDescription = 0x20
        case videoFrame = 0x21
        case replaced = 0x30
        case error = 0x31
    }

    struct Hello: Codable, Sendable {
        let deviceName: String
    }

    struct VideoFrame: Sendable {
        let data: Data
        let isKeyFrame: Bool
        let sequence: UInt64
        let timestampNanoseconds: UInt64
    }

    static func encodeFrame(_ type: FrameType, _ payload: Data = Data()) -> Data {
        var frame = Data(capacity: frameLengthPrefixSize + 1 + payload.count)
        var length = UInt32(1 + payload.count).littleEndian
        withUnsafeBytes(of: &length) { frame.append(contentsOf: $0) }
        frame.append(type.rawValue)
        frame.append(payload)
        return frame
    }

    static func encodeHello(deviceName: String) -> Data {
        let name = deviceName.trimmingCharacters(in: .whitespacesAndNewlines)
        let hello = Hello(deviceName: name.isEmpty ? "Vision Pro" : name)
        let payload = (try? JSONEncoder().encode(hello)) ?? Data()
        return encodeFrame(.hello, payload)
    }

    static func decodeHello(_ payload: Data) -> Hello? {
        try? JSONDecoder().decode(Hello.self, from: payload)
    }

    static func encodeVideoFrame(
        _ data: Data,
        isKeyFrame: Bool,
        sequence: UInt64,
        timestampNanoseconds: UInt64
    ) -> Data {
        var payload = Data(capacity: 17 + data.count)
        payload.append(isKeyFrame ? 1 : 0)
        payload.appendLittleEndian(sequence)
        payload.appendLittleEndian(timestampNanoseconds)
        payload.append(data)
        return encodeFrame(.videoFrame, payload)
    }

    static func decodeVideoFrame(_ payload: Data) -> VideoFrame? {
        guard payload.count >= 17 else { return nil }
        let start = payload.startIndex
        guard let sequence = payload.readLittleEndianUInt64(at: start + 1),
              let timestamp = payload.readLittleEndianUInt64(at: start + 9) else {
            return nil
        }
        return VideoFrame(
            data: payload.subdata(in: (start + 17)..<payload.endIndex),
            isKeyFrame: payload[start] != 0,
            sequence: sequence,
            timestampNanoseconds: timestamp
        )
    }

    static func decodeFrameLength(_ data: Data) -> UInt32? {
        guard data.count >= frameLengthPrefixSize else { return nil }
        var value: UInt32 = 0
        for index in 0..<frameLengthPrefixSize {
            value |= UInt32(data[data.startIndex + index]) << (8 * index)
        }
        return value
    }

    static func drainFrames(_ buffer: inout Data) -> [(type: UInt8, payload: Data)] {
        var frames: [(type: UInt8, payload: Data)] = []
        while let length = decodeFrameLength(buffer) {
            guard length >= 1, length <= maxFrameBytes else {
                buffer.removeAll(keepingCapacity: false)
                break
            }
            let frameEnd = frameLengthPrefixSize + Int(length)
            guard buffer.count >= frameEnd else { break }

            let start = buffer.startIndex
            let type = buffer[start + frameLengthPrefixSize]
            let payloadStart = start + frameLengthPrefixSize + 1
            frames.append((
                type: type,
                payload: buffer.subdata(in: payloadStart..<(start + frameEnd))
            ))
            buffer.removeFirst(frameEnd)
        }
        return frames
    }
}

private nonisolated extension Data {
    mutating func appendLittleEndian(_ value: UInt64) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    func readLittleEndianUInt64(at index: Index) -> UInt64? {
        guard distance(from: index, to: endIndex) >= MemoryLayout<UInt64>.size else {
            return nil
        }
        var value: UInt64 = 0
        for offset in 0..<MemoryLayout<UInt64>.size {
            value |= UInt64(self[index + offset]) << (8 * offset)
        }
        return value
    }
}
