// Run only under firebase emulators:exec --project demo-unipad, with the real app sources.
import Foundation

nonisolated final class AccountingTestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time = Date()
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return time }
    func advance(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; time += seconds }
}

@main struct DownloadAccountingEmulatorCheck {
    static func main() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GCLOUD_PROJECT"] == "demo-unipad",
              environment["FIREBASE_DATABASE_EMULATOR_HOST"] == "127.0.0.1:9051" else {
            fatalError("Requires the demo-unipad emulators on loopback; production is never allowed")
        }
        let folder = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let db = URL(string: "http://127.0.0.1:9051/")!
        let endpoint = URL(string: "http://127.0.0.1:5051/demo-unipad/us-central1/")!
        let client = DownloadAccountingHTTPClient()
        let clock = AccountingTestClock()
        func database(_ path: String, value: Any? = nil) async throws -> Any {
            var request = URLRequest(url: db.appendingPathComponent(path + ".json").appending(queryItems: [.init(name: "ns", value: "demo-unipad")]))
            request.setValue("Bearer owner", forHTTPHeaderField: "Authorization")
            if let value {
                request.httpMethod = "PUT"
                request.httpBody = try JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed)
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            return try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        }
        func count() async throws -> Int { try await database("store/a/downloadCount") as! Int }
        func check(_ value: Bool, _ message: String) { if !value { fatalError(message) }; print("ok \(message)") }
        func service(_ name: String, loseResponse: Bool = false) -> DownloadAccountingService {
            DownloadAccountingService(file: folder.appendingPathComponent(name + ".json"), now: { clock.read() }) { function, body in
                let data = await client.post(function, body: body, endpoint: endpoint)
                let response = data.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
                print("POST \(endpoint.appendingPathComponent(function)) keys=\(body.keys.sorted()) status=\(response?["status"] ?? "network_error")")
                return loseResponse && function == "completeDownload" ? nil : data
            }
        }
        _ = try await database("store", value: ["a": ["code": "ios-emulator", "downloadCount": 100]])
        _ = try await database("downloadAccounting", value: ["config": ["enabled": true]])
        let queue = service("normal")
        await queue.setActive(true)
        let receipt = await queue.issueReceipt(code: "ios-emulator")
        guard let receipt else { fatalError("receipt not issued") }
        check(try await count() == 100, "issuing alone preserves count")
        await queue.saved(code: "ios-emulator", receipt: receipt, at: clock.read())
        check(try await count() == 101, "saved pack adds one")
        let separate = await queue.issueReceipt(code: "ios-emulator")!
        await queue.saved(code: "ios-emulator", receipt: separate, at: clock.read())
        check(try await count() == 102, "a separate new save adds one")
        let lost = service("lost", loseResponse: true)
        await lost.setActive(true)
        let retryReceipt = await lost.issueReceipt(code: "ios-emulator")!
        await lost.saved(code: "ios-emulator", receipt: retryReceipt, at: clock.read())
        check(try await count() == 103, "server count survives a lost response")
        clock.advance(61)
        let restarted = service("lost")
        await restarted.setActive(true)
        check(try await count() == 103, "restart retries the original receipt without a second increment")
        _ = try await database("downloadAccounting/config/enabled", value: false)
        let disabled = await queue.issueReceipt(code: "ios-emulator")
        check(disabled == nil, "disabled issuance makes no pending completion")
        _ = try await database("downloadAccounting/config/enabled", value: true)
        let invalid = await queue.issueReceipt(code: "ios-emulator")!
        _ = try await database("store/a/downloadCount", value: "invalid-count")
        await queue.saved(code: "ios-emulator", receipt: invalid, at: clock.read())
        check(try await database("store/a/downloadCount") as? String == "invalid-count", "nonnumeric count is preserved and deferred")
        _ = try await database("store/a/downloadCount", value: 103)
        clock.advance(61)
        await queue.flush()
        check(try await count() == 104, "deferred save is retried with the same receipt")
        print("Demo emulator integration passed; only loopback accounting endpoints were used")
    }
}
