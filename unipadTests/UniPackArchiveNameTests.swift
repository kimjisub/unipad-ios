import Foundation
import Testing
@testable import unipad

@MainActor
struct UniPackArchiveNameTests {
    @Test func flaggedUTF8NamesResolveTheSound() async throws {
        try await rawArchiveNamesResolveTheSameSound(encoding: "flagged-utf8")
    }

    @Test func unflaggedUTF8NamesResolveTheSound() async throws {
        try await rawArchiveNamesResolveTheSameSound(encoding: "unflagged-utf8")
    }

    @Test func unflaggedCP949NamesResolveTheSound() async throws {
        try await rawArchiveNamesResolveTheSameSound(encoding: "unflagged-cp949")
    }

    private func rawArchiveNamesResolveTheSameSound(encoding: String) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "ArchiveNames-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let name = "소리.wav"
        // CP949 BC D2 B8 AE is '소리'; these bytes are not valid UTF-8.
        let cp949 = Data("sounds/".utf8) + Data([0xBC, 0xD2, 0xB8, 0xAE]) + Data(".wav".utf8)
        #expect(String(data: cp949, encoding: .utf8) == nil)
        let sound = try SoundEngineTestSupport.writeSilentSound()
        defer { try? FileManager.default.removeItem(at: sound) }
        let soundData = try Data(contentsOf: sound)
        let files: [(name: Data, data: Data)] = [
            (Data("info".utf8), Data("title=Archive names\nproducerName=Tester\nbuttonX=8\nbuttonY=8\nchain=1\n".utf8)),
            (Data("keySound".utf8), Data("1 1 1 \(name)\n".utf8)),
            (encoding == "unflagged-cp949" ? cp949 : Data("sounds/\(name)".utf8), soundData),
        ]
        let archive = TestZip.storedRawNames(files, utf8Flag: encoding == "flagged-utf8")
        let source = root.appending(path: "names.zip")
        try archive.write(to: source)
        let installed = try await UniPackImporter(stagingRoot: root.appending(path: "staging"))
            .importPack(from: source, to: root.appending(path: "packs"), delegate: nil)
        let pack = UniPackFolder(rootFolder: installed)
        pack.load()
        pack.loadDetail()
        #expect(!pack.criticalError)
        #expect(pack.errorDetail == nil)
        let file = try #require(pack.soundTable?[0][0][0]?.first?.file)
        #expect(file.lastPathComponent == name)
        #expect(file.deletingLastPathComponent().lastPathComponent == "sounds")
        #expect(try Data(contentsOf: file) == soundData)
        let (engine, listener) = try await SoundEngineTestSupport.loadedEngine(pack)
        defer { engine.destroy() }
        #expect(listener.failure == nil)
        engine.soundOn(x: 0, y: 0)
        #expect(engine.playsStarted == 1)
    }
}
