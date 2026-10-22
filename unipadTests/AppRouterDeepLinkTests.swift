import Foundation
import SwiftUI
import Testing
@testable import unipad

@MainActor
struct AppRouterDeepLinkTests {
    @Test(arguments: [
        "unipad://unipack?code=retired-share",
        "unipad://unipack?code=a%20b%2F%3F%23",
        "unipad://unipack?code=",
        "unipad://unipack",
    ])
    func retiredShareLinksLeaveNavigationUnchanged(link: String) throws {
        let router = AppRouter()
        router.navigate(to: .settings)
        let routes = router.routeStack
        let pathCount = router.path.count
        let splash = router.showSplash

        router.handleDeepLink(try #require(URL(string: link)))

        #expect(router.routeStack == routes)
        #expect(router.path.count == pathCount)
        #expect(router.currentRoute == .settings)
        #expect(router.showSplash == splash)
    }

    @Test func retiredShareLinkKeepsHomeVisible() throws {
        let router = AppRouter()
        router.dismissSplash()

        router.handleDeepLink(try #require(URL(string: "unipad://unipack?code=retired-share")))

        #expect(router.currentRoute == .main)
        #expect(router.path.isEmpty)
        #expect(router.routeStack.isEmpty)
        #expect(!router.showSplash)
    }

    @Test func playLinkStillOpensTheDecodedPackPath() throws {
        let router = AppRouter()
        router.handleDeepLink(try #require(URL(string: "unipad://play?path=%2Fpacks%2FLocal%20Pack")))
        #expect(router.routeStack == [.play(packPath: "/packs/Local Pack")])
        #expect(router.path.count == 1)
    }

    @Test(arguments: ["unipad://play", "unipad://play?path=", "unipad://unknown?code=abc", "https://unipack?code=abc"])
    func unsupportedOrEmptyLinksDoNotNavigate(link: String) throws {
        let router = AppRouter()
        router.handleDeepLink(try #require(URL(string: link)))
        #expect(router.path.isEmpty)
        #expect(router.routeStack.isEmpty)
    }
}
