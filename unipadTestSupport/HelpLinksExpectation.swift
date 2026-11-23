/// Whether the Launchpad help shows its two web links in this build. UI tests cannot read the app's
/// `MidiHelpLinks.isEnabled`, so they follow this value; a unit test fails when the two differ.
/// The unit and UI test targets both build this file.
enum HelpLinksExpectation {
    static let enabled = false
}
