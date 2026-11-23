"""Exercise the real queue and its durable retry limits without a simulator or network."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DownloadAccountingTests(unittest.TestCase):
    def test_durable_completed_download_queue(self):
        source = ROOT / "unipad/Services/DownloadAccounting/DownloadAccounting.swift"
        program = r'''
import Foundation

final class Clock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 1_790_000_000)
    func read() -> Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: Double) { lock.lock(); defer { lock.unlock() }; value += seconds }
}
func check(_ condition: Bool, _ message: String = "") {
    if !condition { fatalError(message) }
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
@main struct Check {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
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
        check(issued != nil)
        check(await server.count("completeDownload") == 0, "issuing a receipt is not a completed save")
        await server.set("deferred")
        await queue.saved(code: "pack", receipt: issued!, at: clock.read())
        check(await server.count("completeDownload") == 1)
        try check(records(file).count == 1)
        await queue.flush()
        check(await server.count("completeDownload") == 1, "one minute minimum")
        clock.advance(60)
        let restarted = service(file)
        await restarted.setActive(true)
        check(await server.count("completeDownload") == 2, "retry survives restart")
        clock.advance(60)
        await restarted.flush()
        clock.advance(60)
        await restarted.flush()
        check(await server.count("completeDownload") == 3, "three in rolling day")
        clock.advance(-3600)
        await restarted.flush()
        check(await server.count("completeDownload") == 3, "clock rollback cannot reset attempts")
        clock.advance(86400 + 3600)
        await server.set("already_counted")
        await restarted.flush()
        try check(records(file).isEmpty, "lost responses retry the same receipt and remove terminal results")
        let calls = await server.calls.filter { $0.0 == "completeDownload" }
        check(Set(calls.map { $0.1["receipt"]! }).count == 1)
        check(calls.allSatisfy { Set($0.1.keys) == ["code", "receipt"] })
        for status in ["counted", "already_counted", "expired", "invalid", "disabled", "deferred", "lost", "unknown"] {
            let other = service(root.appendingPathComponent(status + ".json"))
            await server.set(status)
            await other.setActive(true)
            await other.saved(code: "pack", receipt: DownloadReceipt(receipt: status, expiresAt: clock.read() + 1000), at: clock.read())
            let terminal = ["counted", "already_counted", "expired", "invalid"].contains(status)
            try check(records(root.appendingPathComponent(status + ".json")).isEmpty == terminal)
        }
        await server.set("disabled")
        check(await queue.issueReceipt(code: "pack") == nil, "disabled issuance creates no pending record")
        let cappedFile = root.appendingPathComponent("capped.json")
        let capped = service(cappedFile)
        for index in 0..<1002 {
            await capped.saved(code: "pack", receipt: DownloadReceipt(receipt: "r\(index)", expiresAt: clock.read() + 10000),
                               at: clock.read() + Double(index))
        }
        let saved = try records(cappedFile)
        check(saved.count == 1000 && saved.first!.receipt == "r2")
        check(saved.last!.expiresAt == clock.read() + 10000)
        let before = await server.count("completeDownload")
        await capped.flush()
        check(await server.count("completeDownload") == before, "background queue never sends")
        clock.advance(10000)
        await capped.setActive(true)
        try check(records(cappedFile).isEmpty, "server expiry wins")
        let earlier = service(root.appendingPathComponent("earlier.json"))
        await earlier.saved(code: "pack", receipt: DownloadReceipt(receipt: "early", expiresAt: clock.read() + 9 * 86400), at: clock.read())
        let earlyRecords = try records(root.appendingPathComponent("earlier.json"))
        check(earlyRecords[0].expiresAt == clock.read() + 7 * 86400)
        print("Download accounting: issuance, durable retry, terminal responses, clock changes, foreground, cap and expiry passed")
    }
}
'''
        with tempfile.TemporaryDirectory(prefix="download-accounting-") as temporary:
            folder = Path(temporary)
            main = folder / "Main.swift"
            main.write_text(program)
            executable = folder / "check"
            compiled = subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-swift-version", "5",
                                       "-default-isolation", "MainActor", "-warnings-as-errors",
                                       str(source), str(main),
                                       "-o", str(executable)], capture_output=True, text=True, timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(executable), str(folder)], capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout.strip())


if __name__ == "__main__":
    unittest.main()
