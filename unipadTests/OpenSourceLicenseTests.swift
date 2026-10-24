import Foundation
import Testing
@testable import unipad

/// The notices the app shows, read from the built app these tests run in.
/// Whether the list matches the packages the app is built from is checked
/// against the build itself by `ci/open_source_licenses.py`.
struct OpenSourceLicenseTests {

    private let licenses = OpenSourceLicense.bundled()

    @Test func theOggDecoderAndFirebaseAreListed() {
        let names = Set(licenses.map(\.name))
        #expect(names.isSuperset(of: ["libogg", "libvorbis", "libopus", "libopusfile", "Firebase Apple SDK"]))
    }

    @Test func everyListedComponentCarriesItsLicenseText() {
        #expect(!licenses.isEmpty)
        for license in licenses {
            #expect(license.text().count > 500, "\(license.name) has no license text")
        }
    }

    /// BSD 3-Clause asks binary redistributions to reproduce the copyright
    /// notice, the conditions and the disclaimer.
    @Test(arguments: [
        ("libogg", "Copyright (c) 2002"), ("libvorbis", "Copyright (c) 2002"),
        ("libopus", "Copyright 2001-2023"), ("libopusfile", "Copyright (c) 1994-2013"),
    ])
    func xiphNoticeIsReproducedInFull(name: String, copyright: String) throws {
        let license = try #require(licenses.first { $0.name == name })
        let text = license.text()
        #expect(text.contains(copyright))
        #expect(text.localizedCaseInsensitiveContains("Xiph.Org"))
        #expect(text.contains("Redistributions in binary form must reproduce the above copyright"))
        #expect(text.contains("THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS"))
    }
}
