import Foundation

/// A third-party component built into the app, with the license text it is
/// distributed under. The list and the texts are bundled from
/// `Resources/OpenSourceLicenses`, which `ci/open_source_licenses.py` keeps in
/// step with the packages the app is built from.
struct OpenSourceLicense: Decodable, Identifiable, Hashable {
    let name: String
    let version: String
    let license: String
    let url: String
    let file: String

    var id: String { file }

    private struct Manifest: Decodable {
        let components: [OpenSourceLicense]
    }

    static func bundled(in bundle: Bundle = .main) -> [OpenSourceLicense] {
        guard let url = bundle.url(forResource: "OpenSourceLicenses", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else {
            return []
        }
        return manifest.components
    }

    func text(in bundle: Bundle = .main) -> String {
        let fileURL = URL(fileURLWithPath: file)
        guard let url = bundle.url(forResource: fileURL.deletingPathExtension().lastPathComponent,
                                   withExtension: fileURL.pathExtension),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return ""
        }
        return text
    }
}
