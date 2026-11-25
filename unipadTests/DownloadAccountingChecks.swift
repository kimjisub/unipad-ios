import Foundation
#if canImport(unipad)
@testable import unipad
#endif

/// The same queue checks run in the app test host and the offline compiler check.
nonisolated enum DownloadAccountingChecks {
    nonisolated final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var value = Date(timeIntervalSince1970: 1_790_000_000)
        func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
        func advance(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; value += seconds }
    }
    nonisolated private struct Failure: Error, CustomStringConvertible {
        let description: String
    }
    private static func check(_ condition: Bool, _ message: String = "Download accounting check failed",
                              file: StaticString = #fileID, line: UInt = #line) throws {
        if !condition { throw Failure(description: "\(file):\(line): \(message)") }
    }
    actor Server {
        var calls: [(String, [String: String])] = []
        var status = "issued"
        var expiry: Date
        init(expiry: Date) { self.expiry = expiry }
        func set(_ value: String) { status = value }
        func count(_ function: String) -> Int { calls.filter { $0.0 == function }.count }
        func send(_ function: String, _ body: [String: String]) -> Data? {
            calls.append((function, body))
            if status == "lost" { return nil }
            if function == "issueDownloadReceipt", status == "issued" {
                return try! JSONSerialization.data(withJSONObject: ["status": "issued", "receipt": UUID().uuidString,
                                                                   "expiresAt": expiry.timeIntervalSince1970 * 1000])
            }
            return try! JSONSerialization.data(withJSONObject: ["status": status])
        }
    }

    static func run(in root: URL) async throws {
        let clock = Clock()
        let server = Server(expiry: clock.read() + 7 * 86400)
        let file = root.appendingPathComponent("queue.json")
        func service(_ file: URL) -> DownloadAccountingService {
            DownloadAccountingService(file: file, now: { clock.read() }) { await server.send($0, $1) }
        }
        func records(_ file: URL) throws -> [DownloadAccountingService.Pending] {
            try JSONDecoder().decode([DownloadAccountingService.Pending].self, from: Data(contentsOf: file))
        }
        let queue = service(file)
        await queue.setActive(true)
        let issued = await queue.issueReceipt(code: "pack")
        try check(issued != nil)
        try check(await server.count("completeDownload") == 0, "issuing a receipt is not a completed save")
        await server.set("deferred")
        await queue.saved(code: "pack", receipt: issued!, at: clock.read())
        try check(await server.count("completeDownload") == 1)
        try check(records(file).count == 1)
        await queue.flush()
        try check(await server.count("completeDownload") == 1, "one minute minimum")
        clock.advance(60)
        let restarted = service(file)
        await restarted.setActive(true)
        try check(await server.count("completeDownload") == 2, "retry survives restart")
        clock.advance(60)
        await restarted.flush()
        clock.advance(60)
        await restarted.flush()
        try check(await server.count("completeDownload") == 3, "three in rolling day")
        clock.advance(-3600)
        await restarted.flush()
        try check(await server.count("completeDownload") == 3, "clock rollback cannot reset attempts")
        clock.advance(86400 + 3600)
        await server.set("already_counted")
        await restarted.flush()
        try check(records(file).isEmpty, "lost responses retry the same receipt and remove terminal results")
        let calls = await server.calls.filter { $0.0 == "completeDownload" }
        let receipts = calls.compactMap { $0.1["receipt"] }
        try check(receipts.count == calls.count && Set(receipts).count == 1)
        try check(calls.allSatisfy { Set($0.1.keys) == ["code", "receipt"] })
        for status in ["counted", "already_counted", "expired", "invalid", "disabled", "deferred", "lost", "unknown"] {
            let other = service(root.appendingPathComponent(status + ".json"))
            await server.set(status)
            await other.setActive(true)
            await other.saved(code: "pack", receipt: DownloadReceipt(receipt: status, expiresAt: clock.read() + 1000), at: clock.read())
            let terminal = ["counted", "already_counted", "expired", "invalid"].contains(status)
            try check(records(root.appendingPathComponent(status + ".json")).isEmpty == terminal)
        }
        await server.set("disabled")
        try check(await queue.issueReceipt(code: "pack") == nil, "disabled issuance creates no pending record")
        let cappedFile = root.appendingPathComponent("capped.json")
        let capped = service(cappedFile)
        for index in 0..<1002 {
            await capped.saved(code: "pack", receipt: DownloadReceipt(receipt: "r\(index)", expiresAt: clock.read() + 10000),
                               at: clock.read() + Double(index))
        }
        let saved = try records(cappedFile)
        try check(saved.count == 1000 && saved.first!.receipt == "r2")
        try check(saved.last!.expiresAt == clock.read() + 10000)
        let before = await server.count("completeDownload")
        await capped.flush()
        try check(await server.count("completeDownload") == before, "background queue never sends")
        clock.advance(10000)
        await capped.setActive(true)
        try check(records(cappedFile).isEmpty, "server expiry wins")
        let earlier = service(root.appendingPathComponent("earlier.json"))
        await earlier.saved(code: "pack", receipt: DownloadReceipt(receipt: "early", expiresAt: clock.read() + 9 * 86400), at: clock.read())
        let earlyRecords = try records(root.appendingPathComponent("earlier.json"))
        try check(earlyRecords[0].expiresAt == clock.read() + 7 * 86400)
        print("Download accounting: issuance, durable retry, terminal responses, clock changes, foreground, cap and expiry passed")
    }
}
