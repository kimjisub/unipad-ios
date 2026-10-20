import Foundation
import Testing
@testable import unipad

/// Root-name coverage is valid only where opening a differently cased path really fails.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["UNIPACK_CASE_ROOT"] != nil,
                "Requires an explicitly configured case-sensitive volume"))
struct UniPackRootNameTests {
    private func root() throws -> URL {
        let base = ProcessInfo.processInfo.environment["UNIPACK_CASE_ROOT"]
            .map { URL(fileURLWithPath: $0, isDirectory: true) } ?? FileManager.default.temporaryDirectory
        let root = base.appending(path: "RootNames-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func probe(_ root: URL) throws {
        let upper = root.appending(path: "CaseProbe")
        try Data("upper".utf8).write(to: upper)
        let lower = root.appending(path: "caseprobe")
        #expect(!FileManager.default.fileExists(atPath: lower.path), "F-01 requires a case-sensitive execution directory")
        #expect((try? Data(contentsOf: lower)) == nil, "an exact-path implementation would pass on this disk")
    }

    @Test func executionDirectoryDistinguishesLetterCase() throws {
        let folder = try root()
        defer { try? FileManager.default.removeItem(at: folder) }
        try probe(folder)
    }

    private func writePack(_ root: URL, info: String = "INFO", keySound: String = "KEYSOUND") throws {
        let files = [
            info: "title=Root names\nproducerName=Tester\nbuttonX=8\nbuttonY=8\nchain=1\n",
            keySound: "1 1 1 tone.wav\n",
            "AUTOPLAY": "on 1 1\ndelay 10\noff 1 1\n",
            "KEYLED/1 1 1": "on 1 1 auto 5\ndelay 10\noff 1 1\n",
            "SOUNDS/tone.wav": "sound",
        ]
        for (name, text) in files {
            let url = root.appending(path: name)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
    }

    @Test func uppercaseRootNamesLoadTheActualPack() throws {
        let folder = try root()
        defer { try? FileManager.default.removeItem(at: folder) }
        try probe(folder)
        try writePack(folder)
        let pack = UniPackFolder(rootFolder: folder)
        pack.load()
        pack.loadDetail()
        #expect(!pack.criticalError)
        #expect(pack.title == "Root names")
        #expect(pack.errorDetail == nil)
        #expect(pack.soundTable?[0][0][0]?.first?.file.lastPathComponent == "tone.wav")
        #expect(pack.keyLedExist)
        #expect(pack.ledAnimationTable?[0][0][0]?.first?.ledEvents.count == 3)
        #expect(pack.autoPlayExist)
        #expect(pack.autoPlayTable?.elements.count == 3)
    }

    @Test func infoWithAnExtensionDoesNotReplaceInfo() throws {
        try similarNamesDoNotReplaceRequiredFiles(name: "info.txt")
    }

    @Test func pluralKeySoundsDoesNotReplaceKeySound() throws {
        try similarNamesDoNotReplaceRequiredFiles(name: "keySounds")
    }

    private func similarNamesDoNotReplaceRequiredFiles(name: String) throws {
        let folder = try root()
        defer { try? FileManager.default.removeItem(at: folder) }
        try probe(folder)
        try writePack(folder, info: name == "info.txt" ? name : "INFO",
                      keySound: name == "keySounds" ? name : "KEYSOUND")
        let pack = UniPackFolder(rootFolder: folder)
        pack.load()
        #expect(pack.criticalError)
        #expect(pack.errorDetail?.contains(name == "info.txt" ? "info doesn't exist" : "keySound doesn't exist") == true)
    }
}
