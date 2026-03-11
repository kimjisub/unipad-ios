import Foundation

enum Route: Hashable {
    case main
    case play(packPath: String)
    case store
    case settings
    case settingsStorage
    case theme
    case midiSelect
    case transfer(config: TransferConfig)
    case importByUrl(code: String)

    struct TransferConfig: Hashable {
        var sourceType: String?
        var sourcePath: String?
        var targetType: String?
        var mode: String?
        var title: String?
    }
}
