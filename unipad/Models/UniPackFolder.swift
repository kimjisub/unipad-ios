import Foundation
import os
import CoreFoundation

nonisolated private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "UniPad", category: "UniPackFolder")

nonisolated class UniPackFolder: UniPack {
    private let rootFolder: URL

    private var infoFile: URL?
    private var soundsDir: URL?
    private var keySoundFile: URL?
    private var keyLedDir: URL?
    private(set) var autoPlayFile: URL?

    override var id: String { rootFolder.lastPathComponent }
    override var keyLedExist: Bool { keyLedDir != nil }
    override var autoPlayExist: Bool { autoPlayFile != nil }

    init(rootFolder: URL) {
        self.rootFolder = rootFolder
    }

    /// A pack to parse `source`'s detail into. It holds the files and the grid the parsers read and
    /// shares nothing else with `source`, so parsing it leaves `source` untouched.
    private init(parsingDetailOf source: UniPackFolder) {
        rootFolder = source.rootFolder
        super.init()
        soundsDir = source.soundsDir
        keySoundFile = source.keySoundFile
        keyLedDir = source.keyLedDir
        autoPlayFile = source.autoPlayFile
        buttonX = source.buttonX
        buttonY = source.buttonY
        chain = source.chain
    }

    override func lastModified() -> TimeInterval {
        Self.innerFileLastModified(rootFolder)
    }

    @discardableResult
    override func loadInfo() -> UniPack {
        if !criticalError {
            parseInfo()
        }
        return self
    }

    @discardableResult
    override func loadDetail() -> UniPack {
        return loadDetailWithProgress { _, _, _ in }
    }

    @discardableResult
    override func loadDetailWithProgress(onPhase: (String, Int, Int) -> Void) -> UniPack {
        if let read = makeDetailRead() {
            applyDetail(read(onPhase))
        }
        return self
    }

    override func makeDetailRead() -> DetailRead? {
        guard !criticalError && !detailLoaded else { return nil }
        let scratch = UniPackFolder(parsingDetailOf: self)
        return { onPhase in
            let totalPhases = 3
            onPhase("keySound", 0, totalPhases)
            scratch.parseKeySound()
            onPhase("keyLed", 1, totalPhases)
            scratch.parseKeyLed()
            onPhase("autoPlay", 2, totalPhases)
            scratch.parseAutoPlay()
            return scratch.parsedDetail
        }
    }

    override func checkFile() {
        let fm = FileManager.default
        logger.info("checkFile: rootFolder=\(self.rootFolder.path)")
        guard let contents = try? fm.contentsOfDirectory(at: rootFolder, includingPropertiesForKeys: nil) else {
            addErr("Cannot read directory contents")
            criticalError = true
            return
        }

        logger.info("checkFile: found \(contents.count) items in directory")
        for item in contents {
            let name = item.lastPathComponent.lowercased()
            let isDir = item.hasDirectoryPath
            logger.debug("checkFile: item=\(item.lastPathComponent), lowercased=\(name), isDir=\(isDir)")
            switch name {
            case "info":
                infoFile = item.isFileURL && !isDir ? item : nil
            case "sounds":
                soundsDir = isDir ? item : nil
            case "keysound":
                keySoundFile = item.isFileURL && !isDir ? item : nil
            case "keyled":
                keyLedDir = isDir ? item : nil
            case "autoplay":
                autoPlayFile = item.isFileURL && !isDir ? item : nil
            default:
                break
            }
        }

        logger.info("checkFile: info=\(self.infoFile != nil), keySound=\(self.keySoundFile != nil), sounds=\(self.soundsDir != nil), keyLed=\(self.keyLedDir != nil), autoPlay=\(self.autoPlayFile != nil)")

        if infoFile == nil { addErr("info doesn't exist") }
        if keySoundFile == nil { addErr("keySound doesn't exist") }
        if infoFile == nil && keySoundFile == nil { addErr("It does not seem to be UniPack.") }
        if infoFile == nil || keySoundFile == nil {
            criticalError = true
        }
    }

    override func delete() throws {
        try FileManager.default.removeItem(at: rootFolder)
    }

    override func getPathString() -> String {
        rootFolder.path
    }

    override func getByteSize() -> Int64 {
        Self.folderSize(rootFolder)
    }

    override var description: String { "UniPackFolder(folderName=\(rootFolder.lastPathComponent))" }

    // MARK: - Info Parsing

    private func parseInfo() {
        // Every branch falls through to the validation below: an unreadable info used to return
        // early with chain == 0 and criticalError == false, and PlayViewModel then formed the
        // range 0...(-1) and trapped.
        var hasButtonX = false
        var hasButtonY = false
        if let infoFile {
            guard let data = Self.readTextFile(infoFile) else {
                addErr("info : file could not be decoded")
                criticalError = true
                return
            }

            for rawLine in Self.lines(of: data) {
                let s = rawLine.trimmingCharacters(in: Self.lineTrim)
                // A line without "=" is skipped without a warning, as on the web (info.mdx).
                guard let separator = s.firstIndex(of: "=") else { continue }
                let key = s[..<separator].trimmingCharacters(in: .whitespacesAndNewlines)
                let value = s[s.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)

                switch key {
                case "title": title = value
                case "producerName": producerName = value
                case "buttonX": buttonX = gridSize(key, value); hasButtonX = true
                case "buttonY": buttonY = gridSize(key, value); hasButtonY = true
                case "chain": chain = Int(value) ?? 0
                case "squareButton": squareButton = value == "true"
                case "website": website = value
                default: break
                }
            }
        }

        if title.isEmpty { addErr("info : title was missing") }
        if producerName.isEmpty { addErr("info : producerName was missing") }
        if buttonX == 0 { addErr("info : buttonX was missing") }
        if buttonY == 0 { addErr("info : buttonY was missing") }
        // Without the key the pack has no pads to play; info.mdx marks both as required. A written 0
        // only warns.
        if !hasButtonX || !hasButtonY { criticalError = true }
        if chain == 0 { addErr("info : chain was missing") }
        if !(1...24).contains(chain) {
            addErr("info : chain out of range")
            criticalError = true
        }
        // The grid sizes feed Array(repeating:count:) in loadDetail and PlayViewModel; a negative
        // value trapped and a huge one allocated chain * x * y cells. 0 stays a soft error as before.
        if !(0...Self.maxGridSize).contains(buttonX) || !(0...Self.maxGridSize).contains(buttonY) {
            addErr("info : buttonX/buttonY out of range")
            criticalError = true
        }
    }

    /// A grid size that is not an integer (`buttonX=abc`) refuses the pack (info.mdx); reading it as
    /// 0 opened a pack with no pads.
    private func gridSize(_ key: String, _ value: String) -> Int {
        guard let size = Int(value) else {
            addErr("info : \(key) is not a number")
            criticalError = true
            return 0
        }
        return size
    }

    private static let maxGridSize = 64

    // MARK: - KeySound Parsing

    private func parseKeySound() {
        guard let keySoundFile else {
            logger.warning("parseKeySound: keySoundFile is nil")
            return
        }
        var table = Array(repeating: Array(repeating: [Deque<Sound>?](repeating: nil, count: buttonY), count: buttonX), count: chain)
        soundTable = table
        soundCount = 0

        guard let data = Self.readTextFile(keySoundFile) else {
            // Android (UniPackFolder.kt) treats an unreadable keySound as critical; returning
            // silently opened a pack with zero sounds and no message.
            logger.error("parseKeySound: failed to read keySoundFile at \(keySoundFile.path)")
            addErr("keySound : file could not be read")
            criticalError = true
            return
        }
        logger.info("parseKeySound: parsing file at \(keySoundFile.path)")
        let soundFinder = PackFileFinder()

        for rawLine in Self.lines(of: data) {
            let s = rawLine.trimmingCharacters(in: Self.lineTrim)
            if s.isEmpty { continue }

            let split = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            // Same tolerance as Android: one or two tokens are skipped silently, three tokens are
            // reported, and a non-numeric loop/wormhole drops the whole line (it used to be kept
            // with loop 0, so a line Android rejects played here).
            if split.count <= 2 { continue }
            guard split.count > 3 else {
                addErr("keySound : [\(s)] format is incorrect")
                continue
            }

            guard let c = Self.packInt(split[0]).map({ $0 - 1 }),
                  let x = Self.packInt(split[1]).map({ $0 - 1 }),
                  let y = Self.packInt(split[2]).map({ $0 - 1 }) else {
                addErr("keySound : [\(s)] format is incorrect")
                continue
            }

            let soundURL = split[3]
            var loop = 0
            var wormhole = Sound.noWormhole

            if split.count >= 5 {
                guard let loopRaw = Self.packInt(split[4]) else {
                    addErr("keySound : [\(s)] format is incorrect")
                    continue
                }
                loop = loopRaw - 1
            }
            if split.count >= 6 {
                guard let wormholeRaw = Self.packInt(split[5]) else {
                    addErr("keySound : [\(s)] format is incorrect")
                    continue
                }
                wormhole = wormholeRaw - 1
            }

            // The sound still plays and moves to the nearest chain the pack has. A chain it lacks
            // would become autoPlay's current chain, and practice would light that chain's button
            // past the end of the round button table. Checked before the other fields, as on Android and
            // the web, so a line skipped for one of them still reports its wormhole.
            if wormhole != Sound.noWormhole && !(0..<chain).contains(wormhole) {
                addErr("keySound : [\(s)] wormhole is incorrect")
                wormhole = min(max(wormhole, 0), chain - 1)
            }

            guard (0..<chain).contains(c) else {
                addErr("keySound : [\(s)] chain is incorrect"); continue
            }
            guard (0..<buttonX).contains(x) else {
                addErr("keySound : [\(s)] x is incorrect"); continue
            }
            guard (0..<buttonY).contains(y) else {
                addErr("keySound : [\(s)] y is incorrect"); continue
            }

            guard let soundsDir else {
                addErr("keySound : [\(s)] sounds directory not found"); continue
            }

            guard let soundFile = soundFinder.file(soundURL, in: soundsDir) else {
                addErr("keySound : [\(s)] sound was not found"); continue
            }

            var sound = Sound(file: soundFile, loop: loop, wormhole: wormhole)

            if table[c][x][y] == nil {
                table[c][x][y] = Deque()
            }
            sound.num = table[c][x][y]?.count ?? 0
            table[c][x][y]?.append(sound)
            soundCount += 1
        }

        soundTable = table
    }

    // MARK: - KeyLed Parsing

    private func parseKeyLed() {
        guard let keyLedDir else { return }
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: keyLedDir, includingPropertiesForKeys: nil) else { return }

        var table = Array(repeating: Array(repeating: [Deque<LedAnimation>?](repeating: nil, count: buttonY), count: buttonX), count: chain)
        ledAnimationTable = table
        ledTableCount = 0

        let sortedFiles = files
            .filter { !$0.hasDirectoryPath }
            .map { (key: Self.keyLedOrderKey($0.lastPathComponent), file: $0) }
            .sorted { $0.key.lexicographicallyPrecedes($1.key) }
            .map(\.file)

        for file in sortedFiles {
            let fileName = file.lastPathComponent.trimmingCharacters(in: .whitespaces)
            let split1 = fileName.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard split1.count > 2 else { continue }

            guard let c = Self.packInt(split1[0]).map({ $0 - 1 }),
                  let x = Self.packInt(split1[1]).map({ $0 - 1 }),
                  let y = Self.packInt(split1[2]).map({ $0 - 1 }) else {
                addErr("keyLed : [\(fileName)] format is incorrect"); continue
            }

            var loop = 1
            if split1.count >= 4 {
                guard let loopRaw = Self.packInt(split1[3]) else {
                    addErr("keyLed : [\(fileName)] format is incorrect"); continue
                }
                loop = loopRaw
            }

            guard (0..<chain).contains(c) else {
                addErr("keyLed : [\(fileName)] chain is incorrect"); continue
            }
            guard (0..<buttonX).contains(x) else {
                addErr("keyLed : [\(fileName)] x is incorrect"); continue
            }
            guard (0..<buttonY).contains(y) else {
                addErr("keyLed : [\(fileName)] y is incorrect"); continue
            }
            guard loop >= 0 else {
                addErr("keyLed : [\(fileName)] loop is incorrect"); continue
            }

            guard let data = Self.readTextFile(file) else { continue }
            var ledList: [LedAnimation.LedEvent] = []

            for rawLine in Self.lines(of: data) {
                let s = rawLine.trimmingCharacters(in: Self.lineTrim)
                if s.isEmpty { continue }

                let split2 = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                guard let option = split2.first else { continue }
                guard split2.count >= 2 else {
                    addErr("keyLed : [\(fileName)].[\(s)] format is incorrect"); continue
                }

                switch option {
                case "on", "o":
                    let xToken = split2[1]
                    var ledX: Int
                    var ledY: Int
                    var colorToken: String?
                    var autoToken: String?
                    var velToken: String?

                    if xToken == "*" || xToken == "mc" {
                        guard (4...5).contains(split2.count), let py = Self.packInt(split2[2]) else {
                            addErr("keyLed : [\(fileName)].[\(s)] format is incorrect"); continue
                        }
                        // Round LEDs are 1...32; index 32 is reserved for the logo token.
                        guard (1...32).contains(py) else { continue }
                        ledX = -1
                        ledY = py - 1
                        if split2.count == 4 { colorToken = split2[3] }
                        else if split2.count == 5 { autoToken = split2[3]; velToken = split2[4]; colorToken = split2[3] }
                    } else if xToken == "l" {
                        guard (3...5).contains(split2.count) else {
                            addErr("keyLed : [\(fileName)].[\(s)] format is incorrect"); continue
                        }
                        ledX = -1
                        ledY = 32
                        if split2.count == 3 {
                            colorToken = split2[2]
                        } else if split2.count == 4 {
                            if split2[2] == "auto" || split2[2] == "a" {
                                autoToken = split2[2]
                                velToken = split2[3]
                            } else {
                                colorToken = split2[3]
                            }
                        } else if split2.count == 5 {
                            autoToken = split2[3]
                            velToken = split2[4]
                            colorToken = split2[3]
                        }
                    } else {
                        guard (4...5).contains(split2.count), let px = Self.packInt(xToken), let py = Self.packInt(split2[2]) else {
                            addErr("keyLed : [\(fileName)].[\(s)] format is incorrect"); continue
                        }
                        ledX = px - 1
                        ledY = py - 1
                        if split2.count == 4 { colorToken = split2[3] }
                        else if split2.count == 5 { autoToken = split2[3]; velToken = split2[4]; colorToken = split2[3] }
                    }

                    var ledColor = -1
                    var ledVelocity = 4

                    // Once a velocity is supplied it must parse; never fall back to color-only.
                    if let vStr = velToken {
                        guard let velocity = Self.packInt(vStr) else {
                            addErr("keyLed : [\(fileName)].[\(s)] format is incorrect"); continue
                        }
                        ledVelocity = velocity
                    }

                    if let auto = autoToken, auto == "auto" || auto == "a" {
                        // A bad palette index must not be reinterpreted as the short hex color a.
                        guard (0..<LaunchpadColor.argb.count).contains(ledVelocity) else {
                            addErr("keyLed : [\(fileName)].[\(s)] format is incorrect"); continue
                        }
                        ledColor = Int(LaunchpadColor.colorFromCode(ledVelocity))
                    } else if let cStr = colorToken, let hexVal = Self.hexColor(cStr) {
                        ledColor = hexVal | 0xFF000000
                    } else {
                        addErr("keyLed : [\(fileName)].[\(s)] format is incorrect")
                        continue
                    }

                    ledList.append(.on(x: ledX, y: ledY, color: ledColor, velocity: ledVelocity))

                case "off", "f":
                    let xToken = split2[1]
                    var ledX: Int
                    var ledY: Int

                    if xToken == "*" || xToken == "mc" {
                        guard split2.count >= 3, let py = Self.packInt(split2[2]) else {
                            addErr("keyLed : [\(fileName)].[\(s)] format is incorrect"); continue
                        }
                        guard (1...32).contains(py) else { continue }
                        ledX = -1
                        ledY = py - 1
                    } else if xToken == "l" {
                        ledX = -1
                        ledY = 32
                    } else {
                        guard split2.count >= 3, let px = Self.packInt(xToken), let py = Self.packInt(split2[2]) else {
                            addErr("keyLed : [\(fileName)].[\(s)] format is incorrect"); continue
                        }
                        ledX = px - 1
                        ledY = py - 1
                    }

                    ledList.append(.off(x: ledX, y: ledY))

                case "delay", "d":
                    guard let delayValue = Self.packInt(split2[1]) else {
                        addErr("keyLed : [\(fileName)].[\(s)] format is incorrect"); continue
                    }
                    ledList.append(.delay(delay: delayValue))

                case "chain", "c":
                    guard let chainValue = Self.packInt(split2[1]) else {
                        addErr("keyLed : [\(fileName)].[\(s)] format is incorrect"); continue
                    }
                    ledList.append(.chain(chain: chainValue - 1))

                default:
                    addErr("keyLed : [\(fileName)].[\(s)] format is incorrect")
                }
            }

            if table[c][x][y] == nil {
                table[c][x][y] = Deque()
            }
            let animation = LedAnimation(
                ledEvents: ledList,
                loop: loop,
                num: table[c][x][y]?.count ?? 0
            )
            table[c][x][y]?.append(animation)
            ledTableCount += 1
        }

        ledAnimationTable = table
    }

    func reloadAutoPlay() {
        autoPlayTable = nil
        parseAutoPlay()
    }

    // MARK: - AutoPlay Parsing

    private func parseAutoPlay() {
        guard let autoPlayFile else { return }
        guard let data = Self.readTextFile(autoPlayFile) else { return }

        var autoPlay = AutoPlay(elements: [])
        autoPlayTable = autoPlay
        var map = Array(repeating: [Int](repeating: 0, count: buttonY), count: buttonX)
        var currChain = 0
        func moveToChain(_ c: Int) {
            currChain = c
            autoPlay.elements.append(.chain(c: currChain))
            for i in 0..<map.count { map[i] = [Int](repeating: 0, count: map[i].count) }
        }

        for rawLine in Self.lines(of: data) {
            let s = rawLine.trimmingCharacters(in: Self.lineTrim)
            if s.isEmpty { continue }

            let split = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let option = split.first else { continue }

            var x = -1, y = -1, chainVal = -1, delay = -1

            switch option {
            case "on", "o", "off", "f", "touch", "t":
                guard let px = Self.packInt(split[safe: 1]).map({ $0 - 1 }),
                      let py = Self.packInt(split[safe: 2]).map({ $0 - 1 }) else {
                    addErr("autoPlay : [\(s)] format is incorrect"); continue
                }
                x = px; y = py
                guard (0..<buttonX).contains(x) else {
                    addErr("autoPlay : [\(s)] x is incorrect"); continue
                }
                guard (0..<buttonY).contains(y) else {
                    addErr("autoPlay : [\(s)] y is incorrect"); continue
                }

            case "chain", "c":
                guard let cv = Self.packInt(split[safe: 1]).map({ $0 - 1 }) else {
                    addErr("autoPlay : [\(s)] format is incorrect"); continue
                }
                chainVal = cv
                guard (0..<chain).contains(chainVal) else {
                    addErr("autoPlay : [\(s)] chain is incorrect"); continue
                }

            case "delay", "d":
                guard let dv = Self.packInt(split[safe: 1]) else {
                    addErr("autoPlay : [\(s)] format is incorrect"); continue
                }
                delay = dv

            default:
                addErr("autoPlay : [\(s)] format is incorrect"); continue
            }

            // `touch` is `on` and `off` in one line: both count the pad's next sound and follow
            // that sound's wormhole.
            switch option {
            case "on", "o", "touch", "t":
                autoPlay.elements.append(.on(x: x, y: y, currChain: currChain, num: map[x][y]))
                if option == "touch" || option == "t" {
                    autoPlay.elements.append(.off(x: x, y: y, currChain: currChain))
                }
                let sound = soundGet(c: currChain, x: x, y: y, num: map[x][y])
                map[x][y] += 1
                if let sound, sound.wormhole != Sound.noWormhole {
                    moveToChain(sound.wormhole)
                }

            case "off", "f":
                autoPlay.elements.append(.off(x: x, y: y, currChain: currChain))

            case "chain", "c":
                moveToChain(chainVal)

            case "delay", "d":
                autoPlay.elements.append(.delay(delay: delay))

            default:
                break
            }
        }

        autoPlayTable = autoPlay
    }

    // MARK: - Utility

    /// A number field of keySound, keyLED or autoPlay, read as Android's `toInt()` reads it: a signed
    /// decimal that fits in 32 bits. A larger value is a format error rather than a number outside the
    /// pack, and turning it into a 0-based index (`- 1`) cannot overflow.
    private static func packInt(_ token: String?) -> Int? {
        token.flatMap { Int32($0) }.map(Int.init)
    }

    /// Where a keyLed file goes in its pad's queue, the order Android and the web use: the name composed
    /// (NFC), lower-cased, as UTF-16 code units. Names in composed and decomposed form then sort alike,
    /// and characters past U+FFFF sort by their surrogates rather than by code point, as `<` would.
    /// Files with equal keys keep the order the folder listed them in.
    private static func keyLedOrderKey(_ fileName: String) -> [UInt16] {
        Array(fileName.precomposedStringWithCanonicalMapping.lowercased().utf16)
    }

    private static func folderSize(_ url: URL) -> Int64 {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }

        if isDir.boolValue {
            guard let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
            return children.reduce(0) { $0 + folderSize($1) }
        } else {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return Int64(attrs?[.size] as? UInt64 ?? 0)
        }
    }

    private static func innerFileLastModified(_ url: URL) -> TimeInterval {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }

        if isDir.boolValue {
            guard let children = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.contentModificationDateKey]) else { return 0 }
            return children.reduce(0) { max($0, innerFileLastModified($1)) }
        } else {
            let attrs = try? fm.attributesOfItem(atPath: url.path)
            return (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        }
    }

    private static func readTextFile(_ url: URL) -> String? {
        guard let text = decodeTextFile(url) else { return nil }
        // A UTF-8 BOM (Windows Notepad) is not whitespace for trimmingCharacters, so the first
        // key used to come out as "\u{FEFF}title" and the first line of every table was lost.
        if text.hasPrefix("\u{FEFF}") { return String(text.dropFirst()) }
        return text
    }

    /// UTF-8, then UTF-16 with a byte order mark, then CP949 (T-01 to T-04). Only a file that cannot be
    /// read gives nil: refusing a pack, or dropping an LED file, over a few bytes from another code page
    /// lost what Android and the web open.
    private static func decodeTextFile(_ url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }

        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        // BOM-less UTF-16 decodes almost any even-length byte sequence, so it must not run before
        // the Korean encodings: a legacy EUC-KR keySound used to come out as UTF-16 garbage with
        // zero sounds, where Android at least keeps the ASCII skeleton.
        if data.count >= 2 {
            let b0 = data[data.startIndex], b1 = data[data.startIndex + 1]
            if (b0 == 0xFE && b1 == 0xFF) || (b0 == 0xFF && b1 == 0xFE) {
                if let utf16 = String(data: data, encoding: .utf16) { return utf16 }
            }
        }
        return LegacyText.cp949(data)
    }

    /// A line ends at LF, CRLF or a lone CR (T-05). The other Unicode line breaks (VT, FF, NEL,
    /// U+2028, U+2029) stay inside the line, as Android's and the web's line readers leave them.
    private static func lines(of text: String) -> [Substring] {
        text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r" || $0 == "\r\n" }
    }

    /// Trimmed from both ends of every line. U+FEFF is included: two files joined into one leave a
    /// byte order mark at the start of a line, and Android and the web read that line.
    private static let lineTrim = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\u{FEFF}"))

    /// One to six ASCII hex digits (E-02). `Int(_:radix:)` also takes a sign, so `-1` lit white here
    /// and another colour on Android; the web skips such a line with a format warning.
    private static func hexColor(_ token: String) -> Int? {
        let digits = token.utf8
        guard (1...6).contains(digits.count),
              digits.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x46).contains($0) || (0x61...0x66).contains($0) })
        else { return nil }
        return Int(token, radix: 16)
    }
}
