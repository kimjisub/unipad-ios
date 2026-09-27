import SwiftUI
import Testing
import UIKit
@testable import unipad

/// The import-complete card: its strings in every language and how it fits the
/// smallest and the test iPhone in landscape.
///
/// No small iPhone is available to run on, so the layout checks draw the card at
/// the landscape sizes that matter (iPhone SE 667×375 and iPhone 17 Pro 874×402,
/// less its safe area) and attach the pictures for a person to look at.
@MainActor
struct ImportResultDialogTests {

    private static func bundle(for localization: String) throws -> Bundle {
        let url = Bundle.main.bundleURL.appendingPathComponent("\(localization).lproj")
        return try #require(Bundle(url: url), "no \(localization).lproj in the app")
    }

    private static var languages: [String] {
        Bundle.main.localizations.filter { $0 != "Base" }
    }

    private static func string(_ key: String, in localization: String) throws -> String {
        try bundle(for: localization).localizedString(forKey: key, value: "\u{0}", table: nil)
    }

    // MARK: - Strings

    @Test(arguments: [
        ("en", "Pack imported!", "Import failed", "Play now", "OK"),
        ("de", "Pack importiert!", "Import fehlgeschlagen", "Jetzt spielen", "OK"),
        ("es", "¡Pack importado!", "Error al importar", "Tocar ahora", "Aceptar"),
        ("ko", "불러오기 성공!", "불러오기 실패…", "지금 연주", "확인"),
    ])
    func approvedWording(localization: String, success: String, failed: String, playNow: String, ok: String) throws {
        #expect(try Self.string("importComplete", in: localization) == success)
        #expect(try Self.string("importFailed", in: localization) == failed)
        #expect(try Self.string("import_play_now", in: localization) == playNow)
        #expect(try Self.string("import_result_ok", in: localization) == ok)
    }

    /// Every language names this card in its own words rather than falling back to English.
    @Test func everyLanguageTranslatesTheCard() throws {
        let keys = ["importComplete", "importFailed", "import_play_now"]
        let english = try keys.map { try Self.string($0, in: "en") }
        for localization in Self.languages where localization != "en" {
            for (key, englishValue) in zip(keys, english) {
                let value = try Self.string(key, in: localization)
                #expect(value != "\u{0}", "\(localization) has no \(key)")
                #expect(value != englishValue, "\(localization) shows English for \(key)")
            }
            #expect(try Self.string("import_result_ok", in: localization) != "\u{0}", "\(localization) has no import_result_ok")
        }
    }

    // MARK: - Layout

    private final class StubPack: UniPack {
        override var id: String { "stub" }
        override var keyLedExist: Bool { true }
        override var autoPlayExist: Bool { true }
        override func getByteSize() -> Int64 { 32_988_938 }
    }

    private static func pack(long: Bool) -> UniPack {
        let pack = StubPack()
        pack.title = long
            ? "Alan Walker, Sabrina Carpenter & Farruko - On My Way (Extended Mashup Remix)"
            : "Alan Walker - Faded"
        pack.producerName = long
            ? "Otarygen, 김지섭, K1A2, Remix Project Team, UniPad Community"
            : "Otarygen, 김지섭, K1A2"
        pack.buttonX = 8
        pack.buttonY = 8
        pack.chain = 6
        return pack
    }

    struct Screen: CustomTestStringConvertible, Sendable {
        let name: String
        let size: CGSize
        /// Left, right and bottom insets of a landscape iPhone with the home indicator.
        let safeArea: (left: CGFloat, right: CGFloat, bottom: CGFloat)
        var available: CGSize {
            CGSize(width: size.width - safeArea.left - safeArea.right, height: size.height - safeArea.bottom)
        }
        var testDescription: String { name }
    }

    static let screens = [
        Screen(name: "iPhoneSE-667x375", size: CGSize(width: 667, height: 375), safeArea: (0, 0, 0)),
        Screen(name: "iPhone17Pro-874x402", size: CGSize(width: 874, height: 402), safeArea: (62, 62, 21)),
    ]

    private static func dialog(_ result: ImportResult, localization: String) throws -> ImportResultDialog {
        ImportResultDialog(result: result, onDismiss: {}, onPlayNow: { _ in }, bundle: try bundle(for: localization))
    }

    private static func naturalHeight(of dialog: ImportResultDialog, width: CGFloat) -> CGFloat {
        let host = UIHostingController(rootView: dialog.card.frame(width: width))
        return host.sizeThatFits(in: CGSize(width: width, height: .greatestFiniteMagnitude)).height
    }

    private static func buttonsFitSideBySide(localization: String, cardWidth: CGFloat) throws -> Bool {
        let bundle = try bundle(for: localization)
        let row = HStack(spacing: 10) {
            ImportResultSecondaryButton(
                title: bundle.localizedString(forKey: "import_result_ok", value: nil, table: nil),
                fillsWidth: false, action: {})
            ImportResultPrimaryButton(
                title: bundle.localizedString(forKey: "import_play_now", value: nil, table: nil), action: {})
        }
        let ideal = UIHostingController(rootView: row.fixedSize()).sizeThatFits(in: UIView.layoutFittingExpandedSize)
        return ideal.width <= cardWidth - 40
    }

    private static func attachPicture(of dialog: ImportResultDialog, on screen: Screen, named name: String) {
        let view = ZStack {
            AppColors.background1
            Color.black.opacity(0.5)
            dialog
                .padding(.leading, screen.safeArea.left)
                .padding(.trailing, screen.safeArea.right)
                .padding(.bottom, screen.safeArea.bottom)
        }
        .frame(width: screen.size.width, height: screen.size.height)
        .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let data = renderer.uiImage?.pngData() else {
            Issue.record("could not draw \(name)")
            return
        }
        Attachment.record(data, named: "\(name).png")
    }

    @Test(arguments: screens)
    func cardFitsInsideTheScreen(screen: Screen) throws {
        let width = ImportResultDialog.cardWidth(in: screen.available)
        #expect(width == ImportResultDialog.maxWidth)
        #expect(width <= screen.available.width - 2 * ImportResultDialog.screenMargin)

        let maxHeight = ImportResultDialog.cardMaxHeight(in: screen.available)
        for localization in ["ko", "en", "de"] {
            let faded = try Self.dialog(.success(Self.pack(long: false)), localization: localization)
            let height = Self.naturalHeight(of: faded, width: width)
            #expect(height <= maxHeight, "\(localization) Faded card is \(height)pt tall, \(maxHeight)pt available")
            Self.attachPicture(of: faded, on: screen, named: "\(screen.name)-\(localization)-faded")
        }

        let long = try Self.dialog(.success(Self.pack(long: true)), localization: "de")
        Self.attachPicture(of: long, on: screen, named: "\(screen.name)-de-long")

        let warning = try Self.dialog(
            .warning("keySound : [1 3 3 1 kick.wav] sound was not found\nkeyLED : [1 2 2 1] format is incorrect"),
            localization: "ko")
        #expect(Self.naturalHeight(of: warning, width: width) <= maxHeight)
        Self.attachPicture(of: warning, on: screen, named: "\(screen.name)-ko-warning")

        let failure = try Self.dialog(.error("The file couldn’t be opened because it isn’t in the correct format."), localization: "de")
        #expect(Self.naturalHeight(of: failure, width: width) <= maxHeight)
        Self.attachPicture(of: failure, on: screen, named: "\(screen.name)-de-error")
    }

    /// "Jetzt spielen" and the other approved labels sit next to OK on one line at the narrowest card.
    @Test(arguments: ["ko", "en", "de", "es"])
    func playNowFitsNextToOK(localization: String) throws {
        let width = ImportResultDialog.cardWidth(in: Self.screens[0].available)
        #expect(try Self.buttonsFitSideBySide(localization: localization, cardWidth: width))
    }
}
