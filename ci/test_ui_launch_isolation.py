"""Run the actual Swift launch-argument helpers without launching a simulator."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


PROBE = r"""
func has(_ arguments: [String], _ key: String, _ value: String? = nil) -> Bool {
    guard let index = arguments.firstIndex(of: key) else { return false }
    return value == nil || (index + 1 < arguments.count && arguments[index + 1] == value)
}
let suite = ProcessInfo.processInfo.environment["UNIPAD_RELEASE_SUITE"] == "1"
let plain = Support.englishLaunchArguments()
let deletion = Support.englishLaunchArguments(library: "deletion")
let file = Support.launchArguments(language: "en", locale: "en_US", library: "empty", file: true)
let archive = Support.englishLaunchArguments(archive: Data([1]))
let results = [
    "plain launch isolated only in the suite": has(plain, "-UniPadReleaseTest") == suite,
    "a named library is always isolated": has(deletion, "-UniPadReleaseTest") && has(deletion, "-UniPadUITestLibrary", "deletion"),
    "a requested file is always isolated": has(file, "-UniPadReleaseTest") && has(file, "-UniPadReleaseFile", "YES"),
    "a given archive is always isolated": has(archive, "-UniPadReleaseTest") && has(archive, "-UniPadReleaseArchive"),
]
for (name, passed) in results.sorted(by: { $0.key < $1.key }) { print(passed ? "ok  " : "FAIL", name) }
exit(results.values.allSatisfy { $0 } ? 0 : 1)
"""


class UILaunchIsolationTests(unittest.TestCase):
    def run_probe(self, suite):
        source = (Path(__file__).resolve().parents[1] / "unipadUITests/UITestSupport.swift").read_text()
        start = source.index("    static var isReleaseSuite")
        end = source.index("    /// Creates a recent-play record", start)
        program = "import Foundation\nenum Support {\n" + source[start:end] + "}\n" + PROBE
        scratch = os.environ.get("UNIPAD_TEST_TMPDIR") or os.environ.get("RUNNER_TEMP")
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            path = Path(directory)
            (path / "probe.swift").write_text(program)
            compiled = subprocess.run(["xcrun", "swiftc", "-swift-version", "5", str(path / "probe.swift"),
                                       "-o", str(path / "probe")], capture_output=True, text=True, timeout=120)
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            environment = {k: v for k, v in os.environ.items() if k != "UNIPAD_RELEASE_SUITE"}
            if suite:
                environment["UNIPAD_RELEASE_SUITE"] = "1"
            result = subprocess.run([str(path / "probe")], capture_output=True, text=True, timeout=20, env=environment)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_fixture_requests_stay_isolated_outside_the_suite(self):
        self.run_probe(suite=False)

    def test_every_launch_is_isolated_in_the_suite(self):
        self.run_probe(suite=True)


if __name__ == "__main__":
    unittest.main()
