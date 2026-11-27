import Foundation

extension E2E {
    /// The command files an app of ours reads (`E2ETarget`, `E2EHelper`): `cmd-<n>.json` in, one
    /// at a time, answered in `ack-<n>.json`.
    final class CommandFiles {
        let dir: URL
        /// Names the app in errors.
        private let name: String
        private var next = 1

        init(dir: URL, name: String) {
            self.dir = dir
            self.name = name
        }

        /// Returns the command's result, nil if none. Throws `ScriptError` for a script that
        /// threw (`E2ETarget`'s `eval`).
        @discardableResult
        func send(_ op: String, _ fields: [String: Any] = [:]) async throws -> Any? {
            let n = next
            next += 1
            var command = fields
            command["op"] = op
            let data = try JSONSerialization.data(withJSONObject: command)
            try data.write(to: dir.appendingPathComponent("cmd-\(n).json"), options: .atomic)
            let ack = dir.appendingPathComponent("ack-\(n).json")
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline {
                if let data = try? Data(contentsOf: ack) {
                    let body = try JSONSerialization.jsonObject(with: data) as? [String: Any]
                    if let error = body?["scriptError"] as? String {
                        throw ScriptError(description: "\(name) \(op): \(error)")
                    }
                    if let error = body?["error"] as? String {
                        throw E2EError("\(name) \(op): \(error)")
                    }
                    let result = body?["result"]
                    return result is NSNull ? nil : result
                }
                try await Task.sleep(for: .milliseconds(20))
            }
            throw E2EError("\(name) \(op): no answer in 10 s")
        }
    }
}
