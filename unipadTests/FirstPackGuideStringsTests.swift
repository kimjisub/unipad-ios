import Foundation
import Testing

/// The empty-library guide and Play label in translated languages and English fallbacks.
struct FirstPackGuideStringsTests {

    private static let keys = [
        "main_empty_title",
        "main_empty_step_get_pack",
        "main_empty_step_play",
        "main_empty_step_no_launchpad",
        "main_empty_guide_link",
        "unipack_play",
    ]

    private static let expected: [String: [String: String]] = [
        "en": [
            "main_empty_title": "Play your first UniPack",
            "main_empty_step_get_pack": "Get a pack: tap **Download new packs** to use the Store, or **Import downloaded packs** for a .zip you already have.",
            "main_empty_step_play": "Tap the pack in the list, then tap **Play**.",
            "main_empty_step_no_launchpad": "No Launchpad? Just tap the pads on screen.",
            "main_empty_guide_link": "Getting started guide",
            "unipack_play": "Play",
        ],
        "id": [
            "main_empty_title": "Mainkan UniPack pertama Anda",
            "main_empty_step_get_pack": "Dapatkan pack: ketuk **Unduh pack baru** untuk memakai Toko, atau **Impor pack yang diunduh** untuk file .zip yang sudah Anda miliki.",
            "main_empty_step_play": "Ketuk pack di daftar, lalu ketuk **Play**.",
            "main_empty_step_no_launchpad": "Tidak punya Launchpad? Cukup ketuk pad di layar.",
            "main_empty_guide_link": "Panduan memulai",
            "unipack_play": "Play",
        ],
        "pt-BR": [
            "main_empty_title": "Toque seu primeiro UniPack",
            "main_empty_step_get_pack": "Consiga um pack: toque em **Baixar novos packs** para usar a Loja, ou em **Importar packs baixados** se você já tem um arquivo .zip.",
            "main_empty_step_play": "Toque no pack na lista e depois toque em **Play**.",
            "main_empty_step_no_launchpad": "Não tem Launchpad? Basta tocar nos pads na tela.",
            "main_empty_guide_link": "Guia para começar",
            "unipack_play": "Play",
        ],
        "ko": [
            "main_empty_title": "첫 유니팩을 연주해 보세요",
            "main_empty_step_get_pack": "팩 구하기: 아래 **새로운 팩 다운로드**로 스토어에서 받거나, 갖고 있는 .zip 파일을 **다운로드한 팩 불러오기**로 가져오세요.",
            "main_empty_step_play": "목록에서 팩을 누른 뒤 **재생**을 누르세요.",
            "main_empty_step_no_launchpad": "런치패드가 없어도 화면의 패드를 눌러 연주할 수 있어요.",
            "main_empty_guide_link": "시작 안내 보기",
            "unipack_play": "재생",
        ],
        "es": [
            "main_empty_title": "Toca tu primer UniPack",
            "main_empty_step_get_pack": "Consigue un pack: toca **Descargar nuevos packs** para usar la tienda, o **Importar packs descargados** si ya tienes un archivo .zip.",
            "main_empty_step_play": "Toca el pack en la lista y luego toca **Reproducir**.",
            "main_empty_step_no_launchpad": "¿No tienes Launchpad? Toca los pads en la pantalla.",
            "main_empty_guide_link": "Guía de inicio",
            "unipack_play": "Reproducir",
        ],
    ]

    @Test(arguments: ["en", "ko", "es", "id", "pt-BR"])
    func translatedLanguagesUseTheExpectedWording(_ localization: String) throws {
        let table = try #require(LocalizationBundleTests.strings(for: localization))
        for key in Self.keys {
            #expect(table[key] == Self.expected[localization]?[key], "\(localization).\(key)")
        }
    }

    @Test(arguments: ["id", "pt-BR"])
    func guideUsesActualButtonLabels(_ localization: String) throws {
        let table = try #require(LocalizationBundleTests.strings(for: localization))
        let getPack = try #require(table["main_empty_step_get_pack"])
        for key in ["guide_download_new", "guide_import_external"] {
            let label = try #require(table[key])
            #expect(getPack.contains("**\(label)**"))
        }
        let play = try #require(table["unipack_play"])
        #expect(table["main_empty_step_play"]?.contains("**\(play)**") == true)
    }

    @Test func untranslatedLanguagesShowTheEnglishWording() throws {
        let english = try #require(Self.expected["en"])
        let untranslated = Bundle.main.localizations.filter { !["Base", "en", "ko", "es", "id", "pt-BR"].contains($0) }
        #expect(untranslated.contains("de"))
        for localization in untranslated {
            let table = try #require(LocalizationBundleTests.strings(for: localization))
            for key in Self.keys {
                #expect(table[key] == english[key], "\(localization).\(key)")
            }
        }
    }
}
