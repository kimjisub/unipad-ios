import Foundation

enum Route: Hashable {
    case main
    case play(packPath: String)
    case store
    case settings
    case settingsStorage
    case theme
    case midiSelect
    case importByUrl(code: String)
}
