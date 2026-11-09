import Foundation

/// Test-only metrics on truth-relative error. Temporal error compares error
/// fields after each crop is centred on the same world-space landmark; it is
/// not optical-flow compensation or a measure of the final headset compositor.
struct PCVRResidualMetrics: Codable {
    var mae: Double
    var p95: Double
    var edgeMAE: Double
    var gradientError: Double
    var temporalErrorChange: Double?
    var visibleMAE: Double
    var hiddenMAE: Double
    var hiddenFraction: Double
    var outsideFraction: Double

    static func evaluate(truth: [Float], actual: [Float], width: Int,
                         classification: [Float], previousError: [Float]?) -> (Self, [Float]) {
        precondition(truth.count == actual.count && truth.count % 3 == 0 && width > 1)
        let n = truth.count / 3
        precondition(n > 0 && n % width == 0 && classification.count == n)
        var error = [Float](repeating: 0, count: n), absolute = error
        var sum = 0.0, edge = 0.0, gradient = 0.0, temporal = 0.0
        var seen = 0.0, hidden = 0.0, seenN = 0, hiddenN = 0, outsideN = 0, edgeN = 0, gradientN = 0
        func luma(_ a: [Float], _ i: Int) -> Float { (a[i * 3] + a[i * 3 + 1] + a[i * 3 + 2]) / 3 }
        for i in 0..<n {
            error[i] = luma(actual, i) - luma(truth, i)
            let e = (0..<3).reduce(Float(0)) { $0 + abs(actual[i * 3 + $1] - truth[i * 3 + $1]) } / 3
            absolute[i] = e
            sum += Double(e)
            if classification[i] > 1.5 { outsideN += 1 }
            else if classification[i] > 0.5 { hidden += Double(e); hiddenN += 1 }
            else { seen += Double(e); seenN += 1 }
            var isEdge = false
            for j in [i % width + 1 < width ? i + 1 : -1, i + width < n ? i + width : -1] where j >= 0 {
                let tg = luma(truth, j) - luma(truth, i)
                let ag = luma(actual, j) - luma(actual, i)
                gradient += Double(abs(ag - tg)); gradientN += 1
                if abs(tg) > 0.08 { isEdge = true }
            }
            if isEdge { edge += Double(e); edgeN += 1 }
            if let previousError, previousError.count == n { temporal += Double(abs(error[i] - previousError[i])) }
        }
        absolute.sort()
        return (Self(mae: sum / Double(n), p95: Double(absolute[min(n - 1, Int(Double(n - 1) * 0.95))]),
                     edgeMAE: edge / Double(max(edgeN, 1)), gradientError: gradient / Double(max(gradientN, 1)),
                     temporalErrorChange: previousError?.count == n ? temporal / Double(n) : nil,
                     visibleMAE: seen / Double(max(seenN, 1)), hiddenMAE: hidden / Double(max(hiddenN, 1)),
                     hiddenFraction: Double(hiddenN) / Double(n), outsideFraction: Double(outsideN) / Double(n)), error)
    }
}
