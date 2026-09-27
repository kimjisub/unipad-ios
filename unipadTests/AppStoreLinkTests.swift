import Testing
@testable import unipad

struct AppStoreLinkTests {
    @Test func updateLinkOpensTheUniPadAppStorePage() {
        #expect(MainView.appStoreURL.absoluteString == "https://apps.apple.com/app/id6760479102")
    }
}
