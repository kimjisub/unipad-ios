"""Exercise the real queue and its durable retry limits without a simulator or network."""
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DownloadAccountingTests(unittest.TestCase):
    def test_durable_completed_download_queue(self):
        source = ROOT / "unipad/Services/DownloadAccounting/DownloadAccounting.swift"
        program = '''
import Foundation
@main struct Check {
    static func main() async throws {
        try await DownloadAccountingChecks.run(in: URL(fileURLWithPath: CommandLine.arguments[1]))
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
                                       str(source), str(ROOT / "unipadTests/DownloadAccountingChecks.swift"), str(main),
                                       "-o", str(executable)], capture_output=True, text=True, timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(executable), str(folder)], capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            print(result.stdout.strip())


if __name__ == "__main__":
    unittest.main()
