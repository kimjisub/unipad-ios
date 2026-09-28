import Foundation
import Testing
@testable import unipad

struct MainRecentPacksTests {
    private func item(_ name: String, lastOpenedAt: Date?, criticalError: Bool = false) -> UniPackItem {
        let unipack = UniPackFolder(rootFolder: URL(fileURLWithPath: "/tmp/MainRecentPacksTests/\(name)"))
        unipack.title = name
        unipack.criticalError = criticalError
        return UniPackItem(unipack: unipack, lastOpenedAt: lastOpenedAt)
    }

    @Test func neverPlayedLibraryShowsNothing() {
        let items = [item("a", lastOpenedAt: nil), item("b", lastOpenedAt: nil)]
        #expect(MainRecentPacks.select(from: items).isEmpty)
    }

    @Test func emptyLibraryShowsNothing() {
        #expect(MainRecentPacks.select(from: []).isEmpty)
    }

    @Test func newestPlayFirstAndCappedAtThree() {
        let now = Date()
        let items = [
            item("oldest", lastOpenedAt: now.addingTimeInterval(-400)),
            item("newest", lastOpenedAt: now),
            item("never", lastOpenedAt: nil),
            item("second", lastOpenedAt: now.addingTimeInterval(-100)),
            item("third", lastOpenedAt: now.addingTimeInterval(-200)),
        ]
        let titles = MainRecentPacks.select(from: items).map(\.unipack.title)
        #expect(titles == ["newest", "second", "third"])
    }

    @Test func brokenPacksAreSkipped() {
        let items = [
            item("broken", lastOpenedAt: Date(), criticalError: true),
            item("ok", lastOpenedAt: Date().addingTimeInterval(-10)),
        ]
        #expect(MainRecentPacks.select(from: items).map(\.unipack.title) == ["ok"])
    }

    @Test func limitIsHonoured() {
        let items = (0..<5).map { item("p\($0)", lastOpenedAt: Date().addingTimeInterval(TimeInterval(-$0))) }
        #expect(MainRecentPacks.select(from: items, limit: 1).map(\.unipack.title) == ["p0"])
        #expect(MainRecentPacks.select(from: items, limit: 0).isEmpty)
    }
}
