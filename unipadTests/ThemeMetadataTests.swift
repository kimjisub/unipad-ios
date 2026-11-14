import Foundation
import Testing
@testable import unipad

/// `theme.json` reading: `version` is optional (as on Android and the web), `name` and `author` are not.
struct ThemeMetadataTests {
    private func themeFolder(json: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appending(path: "ThemeMetadata-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(json.utf8).write(to: dir.appending(path: "theme.json"))
        return dir
    }

    @Test func themeWithoutVersionLoadsAsVersionOne() throws {
        let dir = try themeFolder(json: #"{"name":"Minimal","author":"Tester"}"#)
        defer { try? FileManager.default.removeItem(at: dir) }

        let theme = try FolderThemeResources(themeDir: dir, fullLoad: false)

        #expect(theme.name == "Minimal")
        #expect(theme.author == "Tester")
        #expect(theme.version == "1.0")
    }

    @Test func themeWithNullVersionLoadsAsVersionOne() throws {
        let metadata = try JSONDecoder().decode(ThemeMetadata.self, from: Data(#"{"name":"a","author":"b","version":null}"#.utf8))
        #expect(metadata.version == "1.0")
    }

    @Test func themeVersionIsKeptWhenGiven() throws {
        let dir = try themeFolder(json: #"{"name":"Named","author":"Tester","version":"2.3"}"#)
        defer { try? FileManager.default.removeItem(at: dir) }

        let theme = try FolderThemeResources(themeDir: dir, fullLoad: false)

        #expect(theme.version == "2.3")
    }

    @Test(arguments: [#"{"author":"Tester","version":"1.0"}"#, #"{"name":"Nameless","version":"1.0"}"#])
    func themeWithoutNameOrAuthorIsRefused(json: String) throws {
        let dir = try themeFolder(json: json)
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(throws: DecodingError.self) {
            try FolderThemeResources(themeDir: dir, fullLoad: false)
        }
    }
}
