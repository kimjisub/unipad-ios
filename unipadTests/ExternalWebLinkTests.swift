import Foundation
import Testing
@testable import unipad

struct ExternalWebLinkTests {
    private let testArguments = ["UniPad", "-UniPadFirebaseLocalOnly", "YES"]

    @Test(arguments: ["https://unipad.io", "https://unipad.io/docs/get-started",
                      "https://unipad.io/en/docs/theme", "https://unipad.io/ko/docs/theme", "http://unipad.io/docs/guide", "https://UNIPAD.IO/docs"])
    func testLaunchMarksOfficialPages(address: String) throws {
        let original = try #require(URL(string: address))
        #expect(ExternalWebLink.url(original, launchArguments: testArguments).absoluteString
                == address + "?no_analytics=1")
    }

    @Test(arguments: ["https://unipad.io", "https://unipad.io/docs/guide?lang=ko%20KR&empty=#launchpad",
                      "https://example.com/path?query=one%2Btwo#part"])
    func ordinaryLaunchKeepsExactAddress(address: String) throws {
        let original = try #require(URL(string: address))
        for arguments in [[], ["UniPad"], ["-UniPadFirebaseLocalOnly", "NO"],
                          ["-UniPadFirebaseLocalOnly"], ["-OtherArgument", "YES"]] {
            #expect(ExternalWebLink.url(original, launchArguments: arguments).absoluteString == address)
        }
    }

    @Test
    func preservesEncodedQueryAndFragment() throws {
        let original = try #require(URL(string: "https://unipad.io/docs/guide?lang=ko%20KR&empty=&symbol=%2B#launchpad"))
        #expect(ExternalWebLink.url(original, launchArguments: testArguments).absoluteString
                == "https://unipad.io/docs/guide?lang=ko%20KR&empty=&symbol=%2B&no_analytics=1#launchpad")
    }

    @Test(arguments: ["https://unipad.io/docs/guide#custom-firmware",
                      "https://unipad.io/docs/guide?#custom-firmware"])
    func preservesFragmentWithNoQueryItems(address: String) throws {
        let original = try #require(URL(string: address))
        #expect(ExternalWebLink.url(original, launchArguments: testArguments).absoluteString
                == "https://unipad.io/docs/guide?no_analytics=1#custom-firmware")
    }

    @Test(arguments: ["https://unipad.io/?no_analytics=1#part",
                      "https://unipad.io/?lang=en&no_analytics=1&empty=#part"])
    func alreadyMarkedLinkIsUnchanged(address: String) throws {
        let original = try #require(URL(string: address))
        #expect(ExternalWebLink.url(original, launchArguments: testArguments) == original)
    }

    @Test
    func disabledMarkerBecomesOneEnabledMarker() throws {
        let original = try #require(URL(string: "https://unipad.io/?no_analytics=0&lang=en#part"))
        #expect(ExternalWebLink.url(original, launchArguments: testArguments).absoluteString
                == "https://unipad.io/?no_analytics=1&lang=en#part")
    }

    @Test
    func repeatedAndEncodedMarkersBecomeOne() throws {
        let original = try #require(URL(string: "https://unipad.io/?no%5Fanalytics=0&x=%2f&no_analytics=1#part"))
        #expect(ExternalWebLink.url(original, launchArguments: testArguments).absoluteString
                == "https://unipad.io/?no_analytics=1&x=%2f#part")
    }

    @Test(arguments: ["https://example.com/docs", "https://api.unipad.io/docs",
                      "https://unipad.io.example.com", "https://example.com/unipad.io",
                      "mailto:hello@unipad.io", "unipad://unipad.io/docs"])
    func otherDestinationsAreUnchanged(address: String) throws {
        let original = try #require(URL(string: address))
        #expect(ExternalWebLink.url(original, launchArguments: testArguments) == original)
    }
}
