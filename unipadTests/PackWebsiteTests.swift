import Foundation
import Testing
@testable import unipad

/// The page the pack panel's website button opens; without one the button is not shown.
struct PackWebsiteTests {
    @Test(arguments: [nil, "", "   "])
    func anEmptyWebsiteIsNone(website: String?) {
        #expect(UniPack.websiteURL(website) == nil)
    }

    @Test func aWebsiteWithoutASchemeOpensOverHTTPS() {
        #expect(UniPack.websiteURL("unipad.io")?.absoluteString == "https://unipad.io")
        #expect(UniPack.websiteURL("www.youtube.com/@unipad")?.absoluteString == "https://www.youtube.com/@unipad")
    }

    @Test func anHTTPWebsiteIsOpenedAsWritten() {
        #expect(UniPack.websiteURL("http://example.com/a?b=1")?.absoluteString == "http://example.com/a?b=1")
        #expect(UniPack.websiteURL("HTTPS://UniPad.io")?.absoluteString == "HTTPS://UniPad.io")
    }

    @Test(arguments: ["javascript:alert(1)", "mailto:a@example.com", "file:///etc/hosts", "unipad://open", "https://"])
    func onlyHTTPPagesAreOpened(website: String) {
        #expect(UniPack.websiteURL(website) == nil)
    }

    @Test(arguments: ["website=\n", "website=   \n", ""])
    func aPackWithoutAWebsiteHasNoPageToOpen(line: String) throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "PackWebsiteTests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("title=Web\nproducerName=UniPad\nbuttonX=4\nbuttonY=4\nchain=1\n\(line)".utf8).write(to: root.appending(path: "info"))
        try Data().write(to: root.appending(path: "keySound"))
        let pack = UniPackFolder(rootFolder: root)
        pack.load()
        #expect(!pack.criticalError)
        #expect(pack.websiteURL == nil)
    }
}
