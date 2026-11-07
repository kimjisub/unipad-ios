"""Exercise corpus loading, including invalidation, with the actual Swift reader."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


class ConformanceLoadingTests(unittest.TestCase):
    def test_unchanged_corpus_is_parsed_once_but_every_load_checks_its_digest(self):
        root = Path(__file__).resolve().parents[1] / "unipadTests/UniPackConformance"
        reader = (root / "ConformanceCorpus.swift").read_text()
        signature = "static func parse(_ data: Data, source: String) throws -> ConformanceCorpus {"
        self.assertEqual(reader.count(signature), 1)
        # Count the real parser in this probe only; keep instrumentation out of the reader.
        reader = reader.replace(signature, signature + "\n        parseCalls += 1")
        program = "var parseCalls = 0\n" + (root / "ConformanceJSON.swift").read_text() + reader + r'''
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
let json = directory.appendingPathComponent("probe.json")
let digest = directory.appendingPathComponent("probe.sha256")
let source = directory.appendingPathComponent("source.swift").path
func write(_ data: Data) throws {
    try data.write(to: json)
    try (ConformanceCorpus.sha256Hex(data) + "  corpus.json\n").write(to: digest, atomically: true, encoding: .utf8)
}
func load() throws -> ConformanceCorpus { try ConformanceCorpus.load(name: "probe", sourceFile: source) }
var failures: [String] = []
func check(_ condition: Bool, _ message: String) { if !condition { failures.append(message) } }
func refuses(_ action: () throws -> Void, _ message: String) {
    do { try action(); failures.append(message) } catch {}
}
let first = Data(#"{"assets":{},"cases":[]}"#.utf8)
try write(first)
let original = try load()
let repeated = try load()
check(original.sha256 == repeated.sha256, "the repeated load changed the corpus")
check(parseCalls == 1, "unchanged corpus parsed \(parseCalls) times; expected 1")
try "wrong digest\n".write(to: digest, atomically: true, encoding: .utf8)
refuses({ _ = try load() }, "a cached corpus hid a broken digest")
try FileManager.default.removeItem(at: digest)
refuses({ _ = try load() }, "a cached corpus hid a missing digest")
try write(first)
try Data("changed bytes".utf8).write(to: json)
refuses({ _ = try load() }, "a cached corpus hid changed bytes with the old digest")
let changed = Data(#"{"assets":{"tone":{"base64":"AA=="}},"cases":[]}"#.utf8)
try write(changed)
let updated = try load()
check(updated.assets["tone"] == Data([0]), "a new valid corpus returned stale assets")
check(updated.sha256 != original.sha256, "a new valid corpus returned the old digest")
try write(Data("not JSON".utf8))
refuses({ _ = try load() }, "a valid digest hid invalid JSON")
try write(changed)
check(try load().assets["tone"] == Data([0]), "a failed load prevented recovery")
try changed.write(to: directory.appendingPathComponent("corpus.json"))
try (ConformanceCorpus.sha256Hex(changed) + "  corpus.json\n").write(
    to: directory.appendingPathComponent("corpus.sha256"), atomically: true, encoding: .utf8)
setenv("UNIPACK_CONFORMANCE_ROOT", directory.path, 1)
let external = try ConformanceCorpus.load()
check(external.source == "external", "identical bytes returned a stale corpus source")
check(external.assets["tone"] == Data([0]), "changing source changed the assets")
for message in failures { print("FAIL: \(message)") }
exit(failures.isEmpty ? 0 : 1)
'''
        scratch = os.environ.get("UNIPAD_TEST_TMPDIR") or os.environ.get("RUNNER_TEMP")
        with tempfile.TemporaryDirectory(dir=scratch) as directory:
            path = Path(directory)
            (path / "main.swift").write_text(program)
            compiled = subprocess.run(
                ["xcrun", "swiftc", "-swift-version", "5", str(path / "main.swift"), "-o", str(path / "probe")],
                capture_output=True, text=True, timeout=120,
            )
            self.assertEqual(compiled.returncode, 0, compiled.stdout + compiled.stderr)
            result = subprocess.run([str(path / "probe"), directory], capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
