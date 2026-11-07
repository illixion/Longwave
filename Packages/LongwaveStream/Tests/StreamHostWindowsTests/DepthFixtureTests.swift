// The stereo estimate on a real frame's luminance grid, as the host's
// --depth-dump writes it: for tuning, with its maps written out as PGM.
// Opt-in: LW_DEPTH_FIXTURE=<...-luma-WxH.f32> (both eyes side by side, -1 outside
// an eye) and LW_DEPTH_OUT=<directory>; skipped otherwise.
import CStreamWin
@testable import StreamHostWindows
import Foundation
import XCTest

final class DepthFixtureTests: XCTestCase {
    override class func setUp() {
        try? StreamHostRuntime.initialize()
    }

    func testEstimateOnARecordedFrame() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let paths = environment["LW_DEPTH_FIXTURE"], let out = environment["LW_DEPTH_OUT"] else {
            throw XCTSkip("set LW_DEPTH_FIXTURE (frames in order, ';'-separated) and LW_DEPTH_OUT")
        }
        let device = try GraphicsDevice(for: nil)
        let pass = try DepthPass(device: device)
        var previous: [UInt8]?
        for path in paths.split(separator: ";").map(String.init) {
            let output = try estimate(path: path, out: out, device: device, pass: pass)
            if let previous {
                // How much the output moves between consecutive frames: noise
                // the headset would show as swimming when the head moves.
                let changes = zip(previous, output).map { abs(Int($0) - Int($1)) }
                let mean = Double(changes.reduce(0, +)) / Double(changes.count)
                let large = changes.filter { $0 > 8 }.count
                print(String(format: "  frame to frame: %.2f grey levels mean, %d texels changed by more than 8", mean, large))
            }
            previous = output
        }
    }

    private func estimate(path: String, out: String, device: GraphicsDevice, pass: DepthPass) throws -> [UInt8] {
        let environment = ProcessInfo.processInfo.environment
        let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        let size = try XCTUnwrap(name.split(separator: "-").last).split(separator: "x").compactMap { Int($0) }
        XCTAssertEqual(size.count, 2)
        let (width, height) = (size[0], size[1])
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let luma = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        XCTAssertEqual(luma.count, width * height)
        // A grey frame at the grid's own size: the luminance pass then reads it back.
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for (i, v) in luma.enumerated() {
            let g = UInt8(min(max(v, 0), 1) * 255)
            (pixels[4 * i], pixels[4 * i + 1], pixels[4 * i + 2], pixels[4 * i + 3]) = (g, g, g, 255)
        }
        let source = try pixels.withUnsafeBytes {
            try GraphicsTexture(device: device, width: width, height: height, format: .bgra8, pixels: $0)
        }
        let eye = width / 2
        let frustum = SIMD4<Float>(-1.7666, 1.02, 1.02, -1.2158)
        let baseline = Float(environment["LW_DEPTH_BASELINE"].flatMap(Double.init) ?? 0.0669)
        let spacing = (frustum.y - frustum.x) / Float(eye)
        let nearest = Float(environment["LW_DEPTH_NEAREST"].flatMap(Double.init) ?? 0.25)
        let maxDisparity = min(Int((baseline / (nearest * spacing)).rounded(.up)), 128)
        let near = DepthPass.stereoNear(baseline: baseline, maxDisparity: maxDisparity, leftTangents: frustum, depthEyeWidth: eye)
        let destination = try GraphicsTexture(device: device, width: width, height: height, format: .bgra8)
        try pass.apply(source: source, kind: .stereo(baseline: baseline, maxDisparity: maxDisparity),
                       sourceEye: (eye, height), destination: destination, depthEye: (eye, height),
                       tangents: (frustum, frustum), near: near)
        func pgm(_ file: String, _ bytes: [UInt8], _ w: Int, _ h: Int) {
            var d = Data("P5\n\(w) \(h)\n255\n".utf8)
            d.append(contentsOf: bytes)
            FileManager.default.createFile(atPath: out + "/" + file, contents: d)
        }
        func disparityBytes(_ values: [Float]) -> [UInt8] {
            values.map { $0 < 0 ? 0 : UInt8(min(1 + $0 / Float(maxDisparity) * 254, 255)) }
        }
        let raw = try pass.debugGrid(.disparity)
        let cleaned = try pass.debugGrid(.cleaned)
        let known = raw.values.filter { $0 >= 0 }.count, kept = cleaned.values.filter { $0 >= 0 }.count
        pgm("\(name)-disparity.pgm", disparityBytes(raw.values), raw.width, raw.height)
        pgm("\(name)-cleaned.pgm", disparityBytes(cleaned.values), cleaned.width, cleaned.height)
        let pixelsOut = try destination.read()
        let output = stride(from: 0, to: pixelsOut.count, by: 4).map { pixelsOut[$0] }
        pgm("\(name)-depth.pgm", output, width, height)
        print(String(format: "fixture %@: %d of %d grid texels matched (%.1f%%), %d kept after cleaning, near %.3f m, max disparity %d; GPU %.2f ms",
                     name, known, raw.values.count, 100 * Double(known) / Double(raw.values.count), kept, near, maxDisparity,
                     pass.gpuMilliseconds ?? -1))
        return output
    }
}
