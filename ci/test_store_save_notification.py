"""Run the actual store delegate without UI or networking, including the base revision."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class StoreSaveNotificationTests(unittest.TestCase):
    def test_store_completion_notifies_once_without_changing_the_count(self):
        path = "unipad/ViewModels/StoreViewModel.swift"
        revision = os.environ.get("UNIPAD_STORE_DELEGATE_REVISION")
        source = (subprocess.check_output(["git", "show", f"{revision}:{path}"], cwd=ROOT, text=True)
                  if revision else (ROOT / path).read_text())
        delegate = source[source.index("private final class StoreDownloadDelegate:"):source.index("\nextension Color")]
        constructor = ("StoreDownloadDelegate(viewModel: vm, itemId: \"pack\", accounting: spy, receipt: receipt)"
                       if "accounting: any DownloadAccounting" in delegate else
                       "StoreDownloadDelegate(viewModel: vm, itemId: \"pack\")")
        program = r'''
import Foundation
nonisolated struct DownloadReceipt: Sendable { let receipt: String; let expiresAt: Date }
nonisolated protocol DownloadAccounting: Sendable {
    func issueReceipt(code: String) async -> DownloadReceipt?
    func saved(code: String, receipt: DownloadReceipt, at completion: Date) async
}
enum UniPackDownloader {
    protocol Delegate: AnyObject, Sendable {
        @MainActor func onInstallStart()
        @MainActor func onGetFileSize(fileSize: Int64, contentLength: Int64, preKnownFileSize: Int64)
        @MainActor func onDownloadProgress(percent: Int, downloadedSize: Int64, fileSize: Int64)
        @MainActor func onImportStart()
        @MainActor func onInstallComplete(folder: URL)
        @MainActor func onError(_ error: Error)
    }
}
@MainActor final class StoreViewModel {
    struct StoreItem {
        let id: String
        var downloadCount = 123
        var downloading = true
        var downloaded = false
        var downloadFailed = false
        var playText = ""
        var flagColorOverride: String?
    }
    var storeItems = [StoreItem(id: "pack")]
}
enum AppColors { static let orange = "orange", green = "green", red = "red" }
@MainActor final class UsageAnalytics {
    enum Source { case store }
    static let shared = UsageAnalytics()
    func packImportSucceeded(source: Source) {}
    func packImportFailed(source: Source, error: Error) {}
}
actor Spy: DownloadAccounting {
    var completed = 0
    func issueReceipt(code: String) -> DownloadReceipt? { nil }
    func saved(code: String, receipt: DownloadReceipt, at completion: Date) { completed += 1 }
}
''' + delegate + r'''
@main struct Check {
    @MainActor static func main() async {
        let spy = Spy()
        let vm = StoreViewModel()
        let receipt = Task<DownloadReceipt?, Never> { DownloadReceipt(receipt: "r", expiresAt: Date() + 1000) }
        let delegate = CONSTRUCTOR
        delegate.onInstallStart()
        delegate.onImportStart()
        let before = await spy.completed
        guard before == 0 else { fatalError("notification before publication") }
        delegate.onInstallComplete(folder: URL(fileURLWithPath: "/saved-pack"))
        for _ in 0..<10000 {
            if await spy.completed == 1 { break }
            await Task.yield()
        }
        let count = await spy.completed
        guard count == 1 else { print("FAIL: saved pack sent \(count) completion notifications, expected 1"); exit(1) }
        guard vm.storeItems[0].downloaded && vm.storeItems[0].downloadCount == 123 else { exit(2) }
        let failedVM = StoreViewModel()
        let failedReceipt = Task<DownloadReceipt?, Never> { DownloadReceipt(receipt: "failed", expiresAt: Date() + 1000) }
        let failedDelegate = FAILED_CONSTRUCTOR
        failedDelegate.onError(URLError(.cannotWriteToFile))
        for _ in 0..<100 { await Task.yield() }
        let afterFailure = await spy.completed
        guard afterFailure == 1 && failedVM.storeItems[0].downloadFailed else { exit(3) }
        let missingVM = StoreViewModel()
        let missingReceipt = Task<DownloadReceipt?, Never> { nil }
        let missingDelegate = MISSING_CONSTRUCTOR
        missingDelegate.onInstallComplete(folder: URL(fileURLWithPath: "/saved-without-receipt"))
        for _ in 0..<100 { await Task.yield() }
        let afterMissingReceipt = await spy.completed
        guard afterMissingReceipt == 1 && missingVM.storeItems[0].downloaded &&
              missingVM.storeItems[0].downloadCount == 123 else { exit(4) }
        print("Store save notification: published save 1, failed save 0, missing receipt still saves, displayed count unchanged")
    }
}
'''
        program = program.replace("FAILED_CONSTRUCTOR", constructor.replace("vm,", "failedVM,").replace("receipt: receipt", "receipt: failedReceipt"))
        program = program.replace("MISSING_CONSTRUCTOR", constructor.replace("vm,", "missingVM,").replace("receipt: receipt", "receipt: missingReceipt"))
        program = program.replace("CONSTRUCTOR", constructor)
        with tempfile.TemporaryDirectory(prefix="store-save-") as temporary:
            folder = Path(temporary)
            main = folder / "Main.swift"
            main.write_text(program)
            executable = folder / "check"
            result = subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-default-isolation", "MainActor", str(main), "-o", str(executable)],
                                    capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            result = subprocess.run([str(executable)], capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout.strip())


if __name__ == "__main__":
    unittest.main()
