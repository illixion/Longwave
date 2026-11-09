// What this host asks of the Windows Companion that started it, and what the
// Companion answers (CompanionWindows/app/src/supervisor.js reads and writes
// both). One JSON object per line:
//
//   stdout  @longwave {"request":"pcvr-start"}        a headset started the PCVR stream
//           @longwave {"request":"pcvr-stop"}         it stopped it, or left long enough ago
//   stdin   {"pcvr":"running"}                        the PCVR stack is up
//           {"pcvr":"failed","detail":"..."}          it couldn't be started
//           {"pcvr":"stopped"}
//
// Run by hand there is no Companion: requests are only printed, and a PCVR
// stack started some other way streams as before.

import Foundation

final class CompanionLink: @unchecked Sendable {
    enum StackState: Equatable {
        case running
        case stopped
        case failed(String)
    }

    private static let prefix = "@longwave "
    /// Called on the reader thread for each answer.
    var onStackState: ((StackState) -> Void)?

    func request(_ request: String) {
        guard let json = try? JSONSerialization.data(withJSONObject: ["request": request]),
              let text = String(data: json, encoding: .utf8) else { return }
        FileHandle.standardOutput.write(Data((Self.prefix + text + "\n").utf8))
    }

    /// Reads answers until stdin closes (never, run by hand from a console: it just waits).
    func startReading() {
        let thread = Thread { [weak self] in
            while let line = readLine(strippingNewline: true) {
                guard let data = line.data(using: .utf8),
                      let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let pcvr = object["pcvr"] as? String else { continue }
                switch pcvr {
                case "running": self?.onStackState?(.running)
                case "stopped": self?.onStackState?(.stopped)
                case "failed": self?.onStackState?(.failed(object["detail"] as? String ?? "the PC couldn't start PCVR"))
                default: continue
                }
            }
        }
        thread.name = "companion link"
        thread.start()
    }
}
