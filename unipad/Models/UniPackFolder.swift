import Foundation
import os
import CoreFoundation

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "UniPad", category: "UniPackFolder")

class UniPackFolder: UniPack {
    private let rootFolder: URL

    private var infoFile: URL?
    private var infoJsonFile: URL?
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
        if !criticalError && !detailLoaded {
            let totalPhases = 3
            onPhase("keySound", 0, totalPhases)
            parseKeySound()
            onPhase("keyLed", 1, totalPhases)
            parseKeyLed()
            onPhase("autoPlay", 2, totalPhases)
            parseAutoPlay()
            detailLoaded = true
        }
        return self
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
            case "info.json":
                infoJsonFile = item.isFileURL && !isDir ? item : nil
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

        logger.info("checkFile: info=\(self.infoFile != nil), infoJson=\(self.infoJsonFile != nil), keySound=\(self.keySoundFile != nil), sounds=\(self.soundsDir != nil), keyLed=\(self.keyLedDir != nil), autoPlay=\(self.autoPlayFile != nil)")

        if infoFile == nil && infoJsonFile == nil { addErr("info doesn't exist") }
        if keySoundFile == nil { addErr("keySound doesn't exist") }
        if infoFile == nil && infoJsonFile == nil && keySoundFile == nil { addErr("It does not seem to be UniPack.") }
        if (infoFile == nil && infoJsonFile == nil) || keySoundFile == nil {
            criticalError = true
        }
    }

    override func delete() {
        try? FileManager.default.removeItem(at: rootFolder)
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
        if let infoFile {
            guard let data = Self.readTextFile(infoFile) else { return }

            for rawLine in data.components(separatedBy: .newlines) {
                let s = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                if s.isEmpty { continue }

                let split = s.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                guard split.count == 2 else {
                    addErr("info : [\(s)] format is not found")
                    continue
                }
                let key = split[0]
                let value = split[1]

                switch key {
                case "title": title = value
                case "producerName": producerName = value
                case "buttonX": buttonX = Int(value) ?? 0
                case "buttonY": buttonY = Int(value) ?? 0
                case "chain": chain = Int(value) ?? 0
                case "squareButton": squareButton = value == "true"
                case "website": website = value
                default: break
                }
            }
        } else if let infoJsonFile {
            guard
                let data = try? Data(contentsOf: infoJsonFile),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { return }

            if let value = json["title"] as? String { title = value }
            if let value = json["producerName"] as? String { producerName = value }
            if let value = json["buttonX"] as? Int { buttonX = value }
            else if let value = json["buttonX"] as? String { buttonX = Int(value) ?? 0 }
            if let value = json["buttonY"] as? Int { buttonY = value }
            else if let value = json["buttonY"] as? String { buttonY = Int(value) ?? 0 }
            if let value = json["chain"] as? Int { chain = value }
            else if let value = json["chain"] as? String { chain = Int(value) ?? 0 }
            if let value = json["squareButton"] as? Bool { squareButton = value }
            else if let value = json["squareButton"] as? String {
                let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                squareButton = lower == "true" || lower == "1" || lower == "yes" || lower == "y"
            }
            if let value = json["website"] as? String { website = value }
        }

        if title.isEmpty { addErr("info : title was missing") }
        if producerName.isEmpty { addErr("info : producerName was missing") }
        if buttonX == 0 { addErr("info : buttonX was missing") }
        if buttonY == 0 { addErr("info : buttonY was missing") }
        if chain == 0 { addErr("info : chain was missing") }
        if !(1...24).contains(chain) {
            addErr("info : chain out of range")
            criticalError = true
        }
    }

    // MARK: - KeySound Parsing

    private func parseKeySound() {
        guard let keySoundFile else {
            logger.warning("parseKeySound: keySoundFile is nil")
            return
        }
        guard let data = Self.readTextFile(keySoundFile) else {
            logger.error("parseKeySound: failed to read keySoundFile at \(keySoundFile.path)")
            return
        }
        logger.info("parseKeySound: parsing file at \(keySoundFile.path)")

        var table = Array(repeating: Array(repeating: [Deque<Sound>?](repeating: nil, count: buttonY), count: buttonX), count: chain)
        soundTable = table
        soundCount = 0

        for rawLine in data.components(separatedBy: .newlines) {
            let s = rawLine.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }

            let split = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard split.count > 3 else { continue }

            guard let c = Int(split[0]).map({ $0 - 1 }),
                  let x = Int(split[1]).map({ $0 - 1 }),
                  let y = Int(split[2]).map({ $0 - 1 }) else {
                addErr("keySound : [\(s)] format is incorrect")
                continue
            }

            let soundURL = split[3]
            var loop = 0
            var wormhole = Sound.noWormhole

            if split.count >= 5 { loop = (Int(split[4]) ?? 1) - 1 }
            if split.count >= 6 {
                loop = (Int(split[4]) ?? 1) - 1
                if let wormholeVal = Int(split[5]) {
                    wormhole = wormholeVal - 1
                }
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

            let soundFile = soundsDir.appendingPathComponent(soundURL)
            guard FileManager.default.fileExists(atPath: soundFile.path) else {
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
            .sorted { $0.lastPathComponent.lowercased() < $1.lastPathComponent.lowercased() }

        for file in sortedFiles {
            let fileName = file.lastPathComponent.trimmingCharacters(in: .whitespaces)
            let split1 = fileName.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard split1.count > 2 else { continue }

            guard let c = Int(split1[0]).map({ $0 - 1 }),
                  let x = Int(split1[1]).map({ $0 - 1 }),
                  let y = Int(split1[2]).map({ $0 - 1 }) else {
                addErr("keyLed : [\(fileName)] format is incorrect"); continue
            }

            var loop = 1
            if split1.count >= 4 { loop = Int(split1[3]) ?? 1 }

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

            for rawLine in data.components(separatedBy: .newlines) {
                let s = rawLine.trimmingCharacters(in: .whitespaces)
                if s.isEmpty { continue }

                let split2 = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
                guard split2.count >= 2, let option = split2.first else { continue }

                switch option {
                case "on", "o":
                    guard split2.count >= 3 else {
                        addErr("keyLed : [\(fileName)].[\(s)] format is incorrect"); continue
                    }
                    let xToken = split2[1]
                    var ledX: Int
                    var ledY: Int

                    if xToken == "*" || xToken == "mc" {
                        guard let py = Int(split2[2]) else {
                            addErr("keyLed : [\(fileName)].[\(s)] format is incorrect"); continue
                        }
                        ledX = -1
                        ledY = py - 1
                    } else if xToken == "l" {
                        continue
                    } else {
                        guard let px = Int(xToken), let py = Int(split2[2]) else {
                            addErr("keyLed : [\(fileName)].[\(s)] format is incorrect"); continue
                        }
                        ledX = px - 1
                        ledY = py - 1
                    }

                    var ledColor = -1
                    var ledVelocity = 4

                    if split2.count == 4 {
                        guard let hexVal = Int(split2[3], radix: 16) else {
                            addErr("keyLed : [\(fileName)].[\(s)] format is incorrect"); continue
                        }
                        ledColor = hexVal | 0xFF000000
                    } else if split2.count == 5 {
                        if split2[3] == "auto" || split2[3] == "a" {
                            guard let vel = Int(split2[4]) else {
                                addErr("keyLed : [\(fileName)].[\(s)] format is incorrect"); continue
                            }
                            ledVelocity = vel
                            ledColor = Int(LaunchpadColor.colorFromCode(ledVelocity))
                        } else {
                            guard let vel = Int(split2[4]),
                                  let hexVal = Int(split2[3], radix: 16) else {
                                addErr("keyLed : [\(fileName)].[\(s)] format is incorrect"); continue
                            }
                            ledVelocity = vel
                            ledColor = hexVal | 0xFF000000
                        }
                    } else {
                        addErr("keyLed : [\(fileName)].[\(s)] format is incorrect")
                        continue
                    }

                    ledList.append(.on(x: ledX, y: ledY, color: ledColor, velocity: ledVelocity))

                case "off", "f":
                    guard split2.count >= 3 else {
                        addErr("keyLed : [\(fileName)].[\(s)] format is incorrect"); continue
                    }
                    let xToken = split2[1]
                    var ledX: Int
                    var ledY: Int

                    if xToken == "*" || xToken == "mc" {
                        guard let py = Int(split2[2]) else {
                            addErr("keyLed : [\(fileName)].[\(s)] format is incorrect"); continue
                        }
                        ledX = -1
                        ledY = py - 1
                    } else if xToken == "l" {
                        continue
                    } else {
                        guard let px = Int(xToken), let py = Int(split2[2]) else {
                            addErr("keyLed : [\(fileName)].[\(s)] format is incorrect"); continue
                        }
                        ledX = px - 1
                        ledY = py - 1
                    }

                    ledList.append(.off(x: ledX, y: ledY))

                case "delay", "d":
                    guard let delayValue = Int(split2[1]) else {
                        addErr("keyLed : [\(fileName)].[\(s)] format is incorrect"); continue
                    }
                    ledList.append(.delay(delay: delayValue))

                case "chain", "c":
                    guard let chainValue = Int(split2[1]) else {
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

        for rawLine in data.components(separatedBy: .newlines) {
            let s = rawLine.trimmingCharacters(in: .whitespaces)
            if s.isEmpty { continue }

            let split = s.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard let option = split.first else { continue }

            var x = -1, y = -1, chainVal = -1, delay = -1

            switch option {
            case "on", "o", "off", "f", "touch", "t":
                guard let px = Int(split[safe: 1] ?? "").map({ $0 - 1 }),
                      let py = Int(split[safe: 2] ?? "").map({ $0 - 1 }) else {
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
                guard let cv = Int(split[safe: 1] ?? "").map({ $0 - 1 }) else {
                    addErr("autoPlay : [\(s)] format is incorrect"); continue
                }
                chainVal = cv
                guard (0..<chain).contains(chainVal) else {
                    addErr("autoPlay : [\(s)] chain is incorrect"); continue
                }

            case "delay", "d":
                guard let dv = Int(split[safe: 1] ?? "") else {
                    addErr("autoPlay : [\(s)] format is incorrect"); continue
                }
                delay = dv

            default:
                addErr("autoPlay : [\(s)] format is incorrect"); continue
            }

            switch option {
            case "on", "o":
                autoPlay.elements.append(.on(x: x, y: y, currChain: currChain, num: map[x][y]))
                let sound = soundGet(c: currChain, x: x, y: y, num: map[x][y])
                map[x][y] += 1
                if let sound, sound.wormhole != Sound.noWormhole {
                    currChain = sound.wormhole
                    autoPlay.elements.append(.chain(c: currChain))
                    for i in 0..<map.count { map[i] = [Int](repeating: 0, count: map[i].count) }
                }

            case "off", "f":
                autoPlay.elements.append(.off(x: x, y: y, currChain: currChain))

            case "touch", "t":
                autoPlay.elements.append(.on(x: x, y: y, currChain: currChain, num: map[x][y]))
                autoPlay.elements.append(.off(x: x, y: y, currChain: currChain))
                map[x][y] += 1

            case "chain", "c":
                currChain = chainVal
                autoPlay.elements.append(.chain(c: currChain))
                for i in 0..<map.count { map[i] = [Int](repeating: 0, count: map[i].count) }

            case "delay", "d":
                autoPlay.elements.append(.delay(delay: delay))

            default:
                break
            }
        }

        autoPlayTable = autoPlay
    }

    // MARK: - Utility

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
        guard let data = try? Data(contentsOf: url) else { return nil }

        if let utf8 = String(data: data, encoding: .utf8) { return utf8 }
        if let utf16 = String(data: data, encoding: .utf16) { return utf16 }
        if let utf16le = String(data: data, encoding: .utf16LittleEndian) { return utf16le }
        if let utf16be = String(data: data, encoding: .utf16BigEndian) { return utf16be }

        let eucKR = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.EUC_KR.rawValue)))
        if let eucKrText = String(data: data, encoding: eucKR) { return eucKrText }

        let cp949 = String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(0x0422))
        if let cp949Text = String(data: data, encoding: cp949) { return cp949Text }

        return nil
    }
}
