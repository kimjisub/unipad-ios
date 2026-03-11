import SwiftUI
import os
import AVFoundation
#if canImport(MediaPlayer)
import MediaPlayer
#endif

private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "UniPad", category: "PlayViewModel")

@Observable
final class PlayViewModel {
    // MARK: - Constants

    static let circleArraySize = 32
    static let chainIndexOffset = 8
    static let topBarCount = 8
    static let maxChainButtons = 24
    static let functionKeyCount = 36
    static let volumeLevels = 7
    static let lockedAlpha: Double = 0.3

    // MARK: - Checkbox State

    @Observable
    final class CheckBoxState: Identifiable {
        let id = UUID()
        var checked: Bool
        var locked = false
        var visible = true
        @ObservationIgnored var onCheckedChange: ((Bool) -> Void)?
        @ObservationIgnored var onLongPress: (() -> Void)?

        init(checked: Bool = false) {
            self.checked = checked
        }

        func setChecked(_ value: Bool) {
            guard !locked else { return }
            forceSetChecked(value)
        }

        func forceSetChecked(_ value: Bool) {
            checked = value
            onCheckedChange?(value)
        }

        func toggleChecked() {
            guard !locked else { return }
            forceSetChecked(!checked)
        }
    }

    // MARK: - State

    var unipack: UniPack?
    var uiLoaded = false
    var enable = true
    let chain = ChainObserver()

    // Checkbox states
    let scbFeedbackLight = CheckBoxState()
    let scbLed = CheckBoxState()
    let scbAutoPlay = CheckBoxState()
    let scbTraceLog = CheckBoxState()
    let scbRecord = CheckBoxState()
    let scbHideUI = CheckBoxState()
    let scbWatermark = CheckBoxState(checked: true)
    let scbProLightMode = CheckBoxState()

    // UI state
    var autoPlayControlVisible = false
    var autoPlayProgress = 0
    var autoPlayProgressMax = 0
    var isAutoPlayPlaying = false
    var isPracticeMode = false
    var optionViewVisible = true
    var isOptionWindowVisible = false
    var startReady = false
    var proLightModeEnabled = false

    // Loading state
    var unipackLoading = true
    var unipackLoadError: String?
    var unipackWarning: String?
    var loadingPhase = ""
    var loadingPhaseIndex = 0
    var loadingPhaseTotal = 1
    var soundLoadingActive = false
    var soundLoadingProgress = 0
    var soundLoadingMax = 0

    // LED color grid for SwiftUI rendering
    var padColors: [[Color]] = []
    var padLedColors: [[Color]] = []
    var padItems: [[ChannelManager.Item?]] = []
    var padGuideTargets: [[Int64]] = []  // target wall time per pad for guide animation
    var padRenderVersion: Int = 0
    var chainColors: [Color] = []
    var chainItems: [ChannelManager.Item?] = []

    // Channel-based LED management
    var channelManager: ChannelManager?

    // Toast
    var toastMessage: String?

    // Recording state
    private var recPrevEventMs: UInt64 = 0
    private var logBuilder = ""

    // MARK: - Runners

    var soundEngine: SoundEngine?
    var ledRunner: LedRunner?
    private var ledListenerAdapter: LedListenerAdapter?
    private var autoPlayListenerAdapter: AutoPlayListenerAdapter?
    var autoPlayRunner: AutoPlayRunner?

    // MARK: - Load

    func loadUnipack(path: String) async throws {
        logger.info("loadUnipack: path=\(path)")
        unipackLoading = true
        loadingPhase = "info"
        loadingPhaseIndex = 0
        loadingPhaseTotal = 4

        let url = URL(fileURLWithPath: path)
        logger.info("loadUnipack: url=\(url.path), exists=\(FileManager.default.fileExists(atPath: url.path))")

        let pack = UniPackFolder(rootFolder: url)
        pack.load()

        if pack.criticalError {
            logger.error("loadUnipack: critical error - \(pack.errorDetail ?? "unknown")")
            unipackLoadError = pack.errorDetail
            unipackLoading = false
            return
        }

        if let warning = pack.errorDetail {
            unipackWarning = warning
        }

        logger.info("loadUnipack: info loaded - title=\(pack.title), buttonX=\(pack.buttonX), buttonY=\(pack.buttonY), chain=\(pack.chain)")

        loadingPhase = "detail"
        loadingPhaseIndex = 1
        pack.loadDetailWithProgress { phase, index, total in
            self.loadingPhase = phase
            self.loadingPhaseIndex = index + 1
            self.loadingPhaseTotal = total + 1
        }

        logger.info("loadUnipack: detail loaded - soundCount=\(pack.soundCount), ledCount=\(pack.ledTableCount), keyLedExist=\(pack.keyLedExist), autoPlayExist=\(pack.autoPlayExist)")

        unipack = pack
        initState()
        setupCheckBoxVisibility()
        setupCheckBoxListeners()
        scbHideUI.forceSetChecked(false)
        optionViewVisible = true
        isOptionWindowVisible = false

        loadingPhase = "sound"
        loadingPhaseIndex = loadingPhaseTotal - 1
        soundLoadingActive = true

        soundEngine = SoundEngine(
            unipack: pack,
            chain: chain,
            loadingListener: SoundLoadingAdapter(viewModel: self)
        )

        if pack.keyLedExist {
            let adapter = LedListenerAdapter(viewModel: self)
            ledListenerAdapter = adapter
            ledRunner = LedRunner(
                unipack: pack,
                listener: adapter,
                chain: chain
            )
            logger.info("loadUnipack: LedRunner created")
        }

        if pack.autoPlayExist {
            let apAdapter = AutoPlayListenerAdapter(viewModel: self)
            autoPlayListenerAdapter = apAdapter
            autoPlayRunner = AutoPlayRunner(
                unipack: pack,
                listener: apAdapter,
                chain: chain
            )
            autoPlayProgressMax = pack.autoPlayTable?.elements.count ?? 0
            logger.info("loadUnipack: AutoPlayRunner created, elements=\(self.autoPlayProgressMax)")
        }

        setupChainObserver()

        unipackLoading = false
        logger.info("loadUnipack: loading phase complete, waiting for sound buffers")
    }

    func initState() {
        guard let unipack else { return }
        chain.range = 0...(unipack.chain - 1)
        padColors = Array(
            repeating: Array(repeating: .clear, count: unipack.buttonY),
            count: unipack.buttonX
        )
        padLedColors = Array(
            repeating: Array(repeating: .clear, count: unipack.buttonY),
            count: unipack.buttonX
        )
        padItems = Array(
            repeating: Array(repeating: nil, count: unipack.buttonY),
            count: unipack.buttonX
        )
        padGuideTargets = Array(
            repeating: Array(repeating: 0, count: unipack.buttonY),
            count: unipack.buttonX
        )
        chainColors = Array(repeating: .clear, count: Self.circleArraySize)
        chainItems = Array(repeating: nil, count: Self.circleArraySize)
        channelManager = ChannelManager(x: unipack.buttonX, y: unipack.buttonY)
        traceLogInit()
    }

    func setupCheckBoxVisibility() {
        guard let unipack else { return }

        // Reset every time to avoid carrying state from previous packs.
        [scbFeedbackLight, scbLed, scbAutoPlay, scbTraceLog, scbRecord, scbHideUI, scbWatermark, scbProLightMode].forEach {
            $0.visible = true
            $0.locked = false
        }

        if !unipack.squareButton {
            [scbFeedbackLight, scbLed, scbAutoPlay, scbTraceLog, scbRecord].forEach {
                $0.visible = false
                $0.locked = true
            }
        }
        if !unipack.keyLedExist || !unipack.squareButton {
            scbLed.locked = true
        }
        if !unipack.autoPlayExist || !unipack.squareButton {
            scbAutoPlay.locked = true
        }
    }

    /// Wire checkbox state changes to start/stop runners (mirrors Android setupCheckBoxListeners)
    func setupCheckBoxListeners() {
        scbFeedbackLight.onCheckedChange = { [weak self] _ in
            self?.padInit()
            self?.refreshWatermark()
        }

        scbLed.onCheckedChange = { [weak self] checked in
            guard let self, let unipack = self.unipack, unipack.keyLedExist else { return }
            if checked {
                self.ledRunner?.launch()
                logger.info("LedRunner launched via checkbox")
            } else {
                self.ledRunner?.stop()
                self.ledInit()
            }
            self.refreshWatermark()
        }

        scbAutoPlay.onCheckedChange = { [weak self] checked in
            guard let self else { return }
            if checked {
                self.autoPlayRunner?.launch()
                logger.info("AutoPlayRunner launched via checkbox")
            } else {
                self.autoPlayRunner?.practiceGuide = false
                self.isPracticeMode = false
                self.autoPlayRunner?.stop()
                self.padInit()
                self.ledInit()
                self.removeAllGuide()
                self.autoPlayControlVisible = false
                self.isAutoPlayPlaying = false
            }
            self.refreshWatermark()
        }

        scbHideUI.onCheckedChange = { [weak self] checked in
            self?.optionViewVisible = !checked
            self?.refreshWatermark()
        }

        scbRecord.onCheckedChange = { [weak self] checked in
            guard let self else { return }
            if checked {
                self.recPrevEventMs = Self.currentTimeMs()
                self.logBuilder = ""
                self.logBuilder.append("c \(self.chain.value + 1)")
            } else {
                PlatformPasteboard.copyString(self.logBuilder)
                self.logBuilder = ""
                self.toastMessage = String(localized: "copied")
            }
            self.refreshWatermark()
        }

        scbTraceLog.onCheckedChange = { [weak self] _ in
            self?.refreshWatermark()
        }

        scbTraceLog.onLongPress = { [weak self] in
            self?.traceLogInit()
            self?.toastMessage = String(localized: "traceLogClear")
            self?.refreshWatermark()
        }

        scbWatermark.onCheckedChange = { [weak self] _ in
            self?.refreshWatermark()
        }

        scbProLightMode.onCheckedChange = { [weak self] checked in
            guard let self else { return }
            self.proLightModeEnabled = checked
            self.proLightMode(checked)
            self.refreshWatermark()
        }
    }

    private static func currentTimeMs() -> UInt64 {
        UInt64(ProcessInfo.processInfo.systemUptime * 1000)
    }

    private func addRecordLog(_ msg: String) {
        logBuilder.append("\n\(msg)")
    }

    // MARK: - Trace Log

    // 3D: [chain][x][y] -> [Int] entries
    var traceLogTable: [[[[Int]]]] = []
    private var traceLogNextNum: [Int] = []

    func traceLogInit() {
        guard let unipack else { return }
        traceLogTable = Array(
            repeating: Array(
                repeating: Array(
                    repeating: [Int](),
                    count: unipack.buttonY
                ),
                count: unipack.buttonX
            ),
            count: unipack.chain
        )
        traceLogNextNum = Array(repeating: 1, count: unipack.chain)
    }

    private func traceLogLog(x: Int, y: Int) {
        let c = chain.value
        guard c >= 0, c < traceLogTable.count,
              x >= 0, x < traceLogTable[c].count,
              y >= 0, y < traceLogTable[c][x].count,
              c < traceLogNextNum.count else { return }
        traceLogTable[c][x][y].append(traceLogNextNum[c])
        traceLogNextNum[c] += 1
    }

    func traceLogText(x: Int, y: Int) -> String? {
        let c = chain.value
        guard scbTraceLog.checked,
              c >= 0, c < traceLogTable.count,
              x >= 0, x < traceLogTable[c].count,
              y >= 0, y < traceLogTable[c][x].count,
              !traceLogTable[c][x][y].isEmpty else { return nil }
        return traceLogTable[c][x][y].map { String($0) }.joined(separator: " ")
    }

    /// Set initial checkbox states after loading (mirrors Android initSetting)
    func initSetting() {
        guard let unipack else { return }
        logger.info("initSetting: squareButton=\(unipack.squareButton), keyLedExist=\(unipack.keyLedExist), autoPlayExist=\(unipack.autoPlayExist)")

        // Always restore visible UI state when entering Play.
        scbHideUI.forceSetChecked(false)
        optionViewVisible = true
        isOptionWindowVisible = false

        if unipack.keyLedExist {
            scbFeedbackLight.setChecked(false)
            scbLed.setChecked(true)
        } else {
            scbFeedbackLight.setChecked(true)
        }
        logger.info("initSetting: visible feedback=\(self.scbFeedbackLight.visible), led=\(self.scbLed.visible), autoplay=\(self.scbAutoPlay.visible), trace=\(self.scbTraceLog.visible), record=\(self.scbRecord.visible)")
        proLightMode(scbProLightMode.checked)
        chainBtnsRefresh()
    }

    /// Android parity: toggles chain visibility mode and LED circle channel filtering.
    /// - true: show all chain circles and allow LED channel on circles
    /// - false: show only valid chain range (handled in view) and ignore LED channel on circles
    func proLightMode(_ enabled: Bool) {
        guard let cm = channelManager else { return }
        proLightModeEnabled = enabled
        cm.setCirIgnore(channel: .led, ignore: !enabled)
        chainBtnsRefresh()
    }

    /// Register chain change observer to reset multi-mapping indices and refresh chain buttons
    func setupChainObserver() {
        chain.addObserver { [weak self] curr, _ in
            guard let self, let unipack = self.unipack else { return }

            if self.scbRecord.checked {
                let currTime = Self.currentTimeMs()
                self.addRecordLog("d \(currTime - self.recPrevEventMs)")
                self.addRecordLog("chain \(curr + 1)")
                self.recPrevEventMs = currTime
            }

            for i in 0..<unipack.buttonX {
                for j in 0..<unipack.buttonY {
                    unipack.soundPush(c: curr, x: i, y: j, num: 0)
                    unipack.ledPush(c: curr, x: i, y: j, num: 0)
                }
            }
            self.chainBtnsRefresh()
            self.padRenderVersion &+= 1
        }
    }

    /// Update chain button LED states based on current selection
    func chainBtnsRefresh() {
        guard let cm = channelManager else { return }
        for c in 0..<Self.maxChainButtons {
            let y = Self.chainIndexOffset + c
            if c == chain.value {
                cm.add(x: -1, y: y, channel: .chain, color: -1, code: Self.LED_RED)
            } else {
                cm.remove(x: -1, y: y, channel: .chain)
            }
            refreshChainFromChannel(index: y)
        }
    }

    func selectChain(_ c: Int) {
        chain.setValue(c)
    }

    /// Clear all pad states (sound, LED events, pressed channel)
    func padInit() {
        guard let unipack else { return }
        for i in 0..<unipack.buttonX {
            for j in 0..<unipack.buttonY {
                soundEngine?.soundOff(x: i, y: j)
                if let ledRunner, ledRunner.isEventExist(x: i, y: j) {
                    ledRunner.eventOff(x: i, y: j)
                }
                if let cm = channelManager {
                    cm.remove(x: i, y: j, channel: .pressed)
                    refreshPadFromChannel(x: i, y: j)
                } else {
                    clearPadColor(x: i, y: j)
                }
            }
        }
    }

    /// Clear all LED runner states from channel manager
    func ledInit() {
        guard let unipack, let cm = channelManager else { return }
        for i in 0..<unipack.buttonX {
            for j in 0..<unipack.buttonY {
                if let ledRunner, ledRunner.isEventExist(x: i, y: j) {
                    ledRunner.eventOff(x: i, y: j)
                }
                cm.remove(x: i, y: j, channel: .led)
                refreshPadFromChannel(x: i, y: j)
            }
        }
        for i in 0..<Self.functionKeyCount {
            if let ledRunner, ledRunner.isEventExist(x: -1, y: i) {
                ledRunner.eventOff(x: -1, y: i)
            }
            cm.remove(x: -1, y: i, channel: .led)
            if i < Self.circleArraySize {
                refreshChainFromChannel(index: i)
            } else {
                MidiManager.shared.driver.sendFunctionKeyLed(f: i, velocity: 0)
            }
        }
    }

    // MARK: - Pad Touch

    private static let pressedVelocity = 3 // LED_RED

    func padTouch(x: Int, y: Int, isDown: Bool) {
        guard let unipack, x >= 0, x < unipack.buttonX, y >= 0, y < unipack.buttonY else { return }

        if isDown {
            logger.debug("padTouch DOWN x=\(x) y=\(y) chain=\(self.chain.value)")

            if scbRecord.checked {
                let currTime = Self.currentTimeMs()
                addRecordLog("d \(currTime - recPrevEventMs)")
                addRecordLog("t \(x + 1) \(y + 1)")
                recPrevEventMs = currTime
            }

            if scbTraceLog.checked {
                traceLogLog(x: x, y: y)
            }

            soundEngine?.soundOn(x: x, y: y)
            if scbFeedbackLight.checked {
                if let cm = channelManager {
                    cm.add(x: x, y: y, channel: .pressed, color: -1, code: Self.pressedVelocity)
                    refreshPadFromChannel(x: x, y: y)
                } else {
                    setPadColor(x: x, y: y, color: .red)
                }
            }
            ledRunner?.eventOn(x: x, y: y)
        } else {
            soundEngine?.soundOff(x: x, y: y)
            if let cm = channelManager {
                cm.remove(x: x, y: y, channel: .pressed)
                refreshPadFromChannel(x: x, y: y)
            } else {
                clearPadColor(x: x, y: y)
            }
            ledRunner?.eventOff(x: x, y: y)
        }
    }

    // MARK: - LED

    func setPadColor(x: Int, y: Int, color: Color) {
        guard x >= 0, x < padColors.count, y >= 0, y < padColors[x].count else { return }
        padColors[x][y] = color
        padRenderVersion &+= 1
    }

    func clearPadColor(x: Int, y: Int) {
        setPadColor(x: x, y: y, color: .clear)
    }

    func clearAllPadColors() {
        guard let unipack else { return }
        padColors = Array(
            repeating: Array(repeating: .clear, count: unipack.buttonY),
            count: unipack.buttonX
        )
        padLedColors = Array(
            repeating: Array(repeating: .clear, count: unipack.buttonY),
            count: unipack.buttonX
        )
        padItems = Array(
            repeating: Array(repeating: nil, count: unipack.buttonY),
            count: unipack.buttonX
        )
    }

    /// Convert a 32-bit ARGB value to a SwiftUI Color
    private static func colorFromARGB(_ argb: UInt32) -> Color {
        let a = Double((argb >> 24) & 0xFF) / 255.0
        let r = Double((argb >> 16) & 0xFF) / 255.0
        let g = Double((argb >> 8) & 0xFF) / 255.0
        let b = Double(argb & 0xFF) / 255.0
        if a == 0 { return .clear }
        return Color(red: r, green: g, blue: b, opacity: a)
    }

    /// Refresh the displayed pad color from ChannelManager's priority resolution
    func refreshPadFromChannel(x: Int, y: Int) {
        guard enable, let cm = channelManager else { return }
        guard x >= 0, x < padItems.count, y >= 0, y < padItems[x].count else { return }
        if let item = cm.get(x: x, y: y) {
            padItems[x][y] = item
            let color = Self.colorFromARGB(item.color)
            setPadColor(x: x, y: y, color: color)
            MidiManager.shared.driver.sendPadLed(x: x, y: y, velocity: item.code)
        } else {
            padItems[x][y] = nil
            clearPadColor(x: x, y: y)
            MidiManager.shared.driver.sendPadLed(x: x, y: y, velocity: 0)
        }

        // LED overlay color: resolve LED/guide channel independently from pressed state
        if let ledItem = cm.get(x: x, y: y, channel: .led) {
            let ledColor = Self.colorFromARGB(ledItem.color)
            padLedColors[x][y] = ledColor
        } else if let guideItem = cm.get(x: x, y: y, channel: .guide) {
            let guideColor = Self.colorFromARGB(guideItem.color)
            padLedColors[x][y] = guideColor
        } else {
            padLedColors[x][y] = .clear
        }
    }

    /// Refresh the displayed chain color from ChannelManager's priority resolution
    func refreshChainFromChannel(index: Int) {
        guard enable, let cm = channelManager, index >= 0, index < chainColors.count, index < chainItems.count else { return }
        if let item = cm.get(x: -1, y: index) {
            chainItems[index] = item
            chainColors[index] = Self.colorFromARGB(item.color)
            MidiManager.shared.driver.sendFunctionKeyLed(f: index, velocity: item.code)
        } else {
            chainItems[index] = nil
            chainColors[index] = .clear
            MidiManager.shared.driver.sendFunctionKeyLed(f: index, velocity: 0)
        }
    }

    /// Remove all guide LEDs from pads and chain indicators
    func removeAllGuide() {
        guard let unipack, let cm = channelManager else { return }
        for i in 0..<unipack.buttonX {
            for j in 0..<unipack.buttonY {
                cm.remove(x: i, y: j, channel: .guide)
                refreshPadFromChannel(x: i, y: j)
            }
        }
        for i in 0..<Self.circleArraySize {
            cm.remove(x: -1, y: i, channel: .guide)
            refreshChainFromChannel(index: i)
        }
    }

    // MARK: - LED Velocity Constants (matches Android)

    private static let LED_RED_DIM = 1
    private static let LED_RED = 3
    private static let LED_RED_BRIGHT = 5
    private static let LED_WARM = 11
    private static let LED_ORANGE = 17
    private static let LED_YELLOW = 19
    private static let LED_BLUE = 40
    private static let LED_LAVENDER = 43
    private static let LED_CYAN = 52
    private static let LED_LIGHT_BLUE = 55
    private static let LED_GREEN = 61

    // MARK: - Option Window

    func toggleOptionWindow(_ show: Bool? = nil) {
        isOptionWindowVisible = show ?? !isOptionWindowVisible
        refreshWatermark()
    }

    // MARK: - Watermark

    func refreshWatermark() {
        guard let cm = channelManager else { return }

        var topBar = [Int](repeating: 0, count: Self.topBarCount)
        let showUi: Bool
        let showUiUnipad: Bool
        let showChain: Bool

        if !isOptionWindowVisible {
            if scbWatermark.checked {
                showUi = false
                showUiUnipad = true
                showChain = true
            } else {
                showUi = false
                showUiUnipad = false
                showChain = false
            }
        } else {
            if !scbHideUI.checked {
                showUi = true
                showUiUnipad = false
                showChain = false
            } else {
                showUi = false
                showUiUnipad = false
                showChain = false
            }
        }

        cm.setCirIgnore(channel: .ui, ignore: !showUi)
        cm.setCirIgnore(channel: .uiUnipad, ignore: !showUiUnipad)
        cm.setCirIgnore(channel: .chain, ignore: !showChain)

        if !isOptionWindowVisible {
            topBar[4] = Self.LED_GREEN
            topBar[5] = Self.LED_BLUE
            topBar[6] = Self.LED_GREEN
            topBar[7] = Self.LED_BLUE
            for i in 0..<Self.topBarCount {
                if topBar[i] != 0 {
                    cm.add(x: -1, y: i, channel: .uiUnipad, color: -1, code: topBar[i])
                } else {
                    cm.remove(x: -1, y: i, channel: .uiUnipad)
                }
                refreshChainFromChannel(index: i)
            }
        } else {
            topBar[0] = scbFeedbackLight.locked ? 0 : (scbFeedbackLight.checked ? Self.LED_RED : Self.LED_RED_DIM)
            topBar[1] = scbLed.locked ? 0 : (scbLed.checked ? Self.LED_CYAN : Self.LED_LIGHT_BLUE)
            topBar[2] = scbAutoPlay.locked ? 0 : (scbAutoPlay.checked ? Self.LED_ORANGE : Self.LED_YELLOW)
            topBar[3] = 0
            topBar[4] = scbHideUI.locked ? 0 : (scbHideUI.checked ? Self.LED_RED : Self.LED_RED_DIM)
            topBar[5] = scbWatermark.locked ? 0 : (scbWatermark.checked ? Self.LED_GREEN : Self.LED_WARM)
            topBar[6] = scbProLightMode.locked ? 0 : (scbProLightMode.checked ? Self.LED_BLUE : Self.LED_LAVENDER)
            topBar[7] = Self.LED_RED_BRIGHT
            for i in 0..<Self.topBarCount {
                if topBar[i] != 0 {
                    cm.add(x: -1, y: i, channel: .ui, color: -1, code: topBar[i])
                } else {
                    cm.remove(x: -1, y: i, channel: .ui)
                }
                refreshChainFromChannel(index: i)
            }
        }
        chainBtnsRefresh()
    }

    // MARK: - AutoPlay Controls

    func autoPlayPlay() {
        padInit()
        ledInit()
        autoPlayRunner?.playmode = true
        isAutoPlayPlaying = true
        if let unipack, unipack.keyLedExist {
            scbLed.setChecked(true)
            scbFeedbackLight.setChecked(false)
        } else {
            scbFeedbackLight.setChecked(true)
        }
        autoPlayRunner?.beforeStartPlaying = true
    }

    func autoPlayStop() {
        autoPlayRunner?.playmode = false
        padInit()
        ledInit()
        isAutoPlayPlaying = false
    }

    func autoPlayPrev() {
        padInit()
        ledInit()
        autoPlayRunner?.progressOffset(-40)
    }

    func autoPlayNext() {
        padInit()
        ledInit()
        autoPlayRunner?.progressOffset(40)
    }

    func togglePracticeMode() {
        guard let runner = autoPlayRunner else { return }
        let newMode = !runner.practiceGuide
        runner.practiceGuide = newMode
        isPracticeMode = newMode
        if !newMode {
            if let unipack, unipack.keyLedExist {
                scbLed.setChecked(true)
                scbFeedbackLight.setChecked(false)
            } else {
                scbFeedbackLight.setChecked(true)
            }
        }
    }

    func practiceStart() {
        guard let runner = autoPlayRunner else { return }
        if scbAutoPlay.checked {
            runner.practiceGuide = false
            isPracticeMode = false
            scbAutoPlay.setChecked(false)
        } else {
            runner.practiceGuide = true
            isPracticeMode = true
            scbAutoPlay.setChecked(true)
        }
    }

    // MARK: - MIDI Controller

    private var midiControllerAdapter: PlayMidiControllerAdapter?

    func setupMidiController() {
        let adapter = PlayMidiControllerAdapter(viewModel: self)
        midiControllerAdapter = adapter
        MidiManager.shared.controller = adapter
    }

    func redrawAllLaunchpadLeds() {
        guard let unipack, let cm = channelManager else { return }
        let driver = MidiManager.shared.driver
        for x in 0..<unipack.buttonX {
            for y in 0..<unipack.buttonY {
                if let item = cm.get(x: x, y: y) {
                    driver.sendPadLed(x: x, y: y, velocity: item.code)
                } else {
                    driver.sendPadLed(x: x, y: y, velocity: 0)
                }
            }
        }
        for i in 0..<Self.functionKeyCount {
            if let item = cm.get(x: -1, y: i) {
                driver.sendFunctionKeyLed(f: i, velocity: item.code)
            } else {
                driver.sendFunctionKeyLed(f: i, velocity: 0)
            }
        }
    }

    func handleFunctionKeyTouch(f: Int, upDown: Bool) {
        guard upDown else { return }

        if !isOptionWindowVisible {
            switch f {
            case 0: scbFeedbackLight.toggleChecked()
            case 1: scbLed.toggleChecked()
            case 2: scbAutoPlay.toggleChecked()
            case 3: toggleOptionWindow()
            case 4, 5, 6, 7: scbWatermark.toggleChecked()
            default: break
            }
        } else {
            if f < Self.topBarCount {
                switch f {
                case 0: scbFeedbackLight.toggleChecked()
                case 1: scbLed.toggleChecked()
                case 2: scbAutoPlay.toggleChecked()
                case 3: toggleOptionWindow()
                case 4: scbHideUI.toggleChecked()
                case 5: scbWatermark.toggleChecked()
                case 6: scbProLightMode.toggleChecked()
                case 7: quitRequested = true
                default: break
                }
            } else if f >= Self.chainIndexOffset, f < Self.chainIndexOffset + Self.topBarCount {
                setVolume(level: Self.chainIndexOffset + Self.volumeLevels - f)
            }
        }
    }

    var quitRequested = false

    // MARK: - Volume Control

    func setVolume(level: Int) {
        #if canImport(UIKit)
        let maxLevel = Float(Self.volumeLevels)
        let newVolume = Float(max(0, min(level, Self.volumeLevels))) / maxLevel
        MPVolumeViewHelper.setVolume(newVolume)
        updateVolumeUI()
        #endif
    }

    func updateVolumeUI() {
        guard let cm = channelManager else { return }
        #if canImport(UIKit)
        let volume = AVAudioSession.sharedInstance().outputVolume
        var level = Int((volume * Float(Self.volumeLevels)).rounded()) + 1
        if level == 1 { level = 0 }
        for c in 0..<Self.topBarCount {
            let y = Self.chainIndexOffset + c
            let threshold = Self.topBarCount - level
            if c >= threshold {
                cm.add(x: -1, y: y, channel: .ui, color: -1, code: Self.LED_BLUE)
            } else {
                cm.remove(x: -1, y: y, channel: .ui)
            }
            refreshChainFromChannel(index: y)
        }
        #endif
    }

    // MARK: - Cleanup

    func cleanup() {
        enable = false
        MidiManager.shared.driver.sendClearLed()
        MidiManager.shared.controller = nil
        midiControllerAdapter = nil
        autoPlayRunner?.stop()
        ledRunner?.stop()
        soundEngine?.destroy()
        chain.clearObservers()
    }

    func startLedRunner() {
        ledRunner?.launch()
    }

    func startAutoPlay() {
        autoPlayRunner?.launch()
        autoPlayControlVisible = true
        isAutoPlayPlaying = true
    }

    func stopAutoPlay() {
        autoPlayRunner?.stop()
        autoPlayControlVisible = false
        isAutoPlayPlaying = false
        clearAllPadColors()
    }

    /// Called when sound loading completes to apply initial settings
    func onSoundLoadingComplete() {
        startReady = true
        initSetting()
        setupMidiController()
        logger.info("Sound loading complete, startReady=true")
    }
}

// MARK: - Sound Loading Adapter

private final class SoundLoadingAdapter: SoundEngine.LoadingListener {
    private weak var viewModel: PlayViewModel?

    init(viewModel: PlayViewModel) {
        self.viewModel = viewModel
    }

    func onStart(soundCount: Int) {
        Task { @MainActor [weak self] in
            self?.viewModel?.soundLoadingMax = soundCount
            self?.viewModel?.soundLoadingProgress = 0
        }
    }

    func onProgressTick() {
        Task { @MainActor [weak self] in
            self?.viewModel?.soundLoadingProgress += 1
        }
    }

    func onEnd() {
        Task { @MainActor [weak self] in
            self?.viewModel?.soundLoadingActive = false
            self?.viewModel?.onSoundLoadingComplete()
        }
    }

    func onException(_ error: Error) {
        Task { @MainActor [weak self] in
            self?.viewModel?.soundLoadingActive = false
            self?.viewModel?.unipackLoadError = error.localizedDescription
            self?.viewModel?.quitRequested = true
        }
    }
}

// MARK: - LED Listener Adapter

private final class LedListenerAdapter: LedRunner.Listener {
    private weak var viewModel: PlayViewModel?

    init(viewModel: PlayViewModel) {
        self.viewModel = viewModel
    }

    func onPadLedTurnOn(x: Int, y: Int, color: Int, velocity: Int) {
        Task { @MainActor [weak self] in
            guard let vm = self?.viewModel, let cm = vm.channelManager else { return }
            cm.add(x: x, y: y, channel: .led, color: color, code: velocity)
            vm.refreshPadFromChannel(x: x, y: y)
        }
    }

    func onPadLedTurnOff(x: Int, y: Int) {
        Task { @MainActor [weak self] in
            guard let vm = self?.viewModel, let cm = vm.channelManager else { return }
            cm.remove(x: x, y: y, channel: .led)
            vm.refreshPadFromChannel(x: x, y: y)
        }
    }

    func onChainLedTurnOn(c: Int, color: Int, velocity: Int) {
        Task { @MainActor [weak self] in
            guard let vm = self?.viewModel, let cm = vm.channelManager else { return }
            guard c >= 0, c < vm.chainColors.count else { return }
            cm.add(x: -1, y: c, channel: .led, color: color, code: velocity)
            vm.refreshChainFromChannel(index: c)
        }
    }

    func onChainLedTurnOff(c: Int) {
        Task { @MainActor [weak self] in
            guard let vm = self?.viewModel, let cm = vm.channelManager else { return }
            guard c >= 0, c < vm.chainColors.count else { return }
            cm.remove(x: -1, y: c, channel: .led)
            vm.refreshChainFromChannel(index: c)
        }
    }
}

// MARK: - AutoPlay Listener Adapter

private final class AutoPlayListenerAdapter: AutoPlayRunner.Listener {
    private weak var viewModel: PlayViewModel?

    init(viewModel: PlayViewModel) {
        self.viewModel = viewModel
    }

    func onStart() {
        Task { @MainActor [weak self] in
            guard let vm = self?.viewModel else { return }
            vm.autoPlayProgress = 0
            if let unipack = vm.unipack, unipack.squareButton {
                vm.autoPlayControlVisible = true
            }
            vm.autoPlayPlay()
        }
    }

    func onPadTouchOn(x: Int, y: Int) {
        Task { @MainActor [weak self] in
            self?.viewModel?.padTouch(x: x, y: y, isDown: true)
        }
    }

    func onPadTouchOff(x: Int, y: Int) {
        Task { @MainActor [weak self] in
            self?.viewModel?.padTouch(x: x, y: y, isDown: false)
        }
    }

    func onChainChange(c: Int) {
        Task { @MainActor [weak self] in
            self?.viewModel?.chain.setValue(c)
        }
    }

    private static let guideVelocity = 17 // LED_ORANGE

    func onGuidePadOn(x: Int, y: Int, targetWallTimeMs: Int64) {
        Task { @MainActor [weak self] in
            guard let vm = self?.viewModel, let cm = vm.channelManager else { return }
            cm.add(x: x, y: y, channel: .guide, color: -1, code: Self.guideVelocity)
            vm.refreshPadFromChannel(x: x, y: y)
            if x >= 0, x < vm.padGuideTargets.count, y >= 0, y < vm.padGuideTargets[x].count {
                vm.padGuideTargets[x][y] = targetWallTimeMs
            }
        }
    }

    func onGuidePadOff(x: Int, y: Int) {
        Task { @MainActor [weak self] in
            guard let vm = self?.viewModel, let cm = vm.channelManager else { return }
            cm.remove(x: x, y: y, channel: .guide)
            vm.refreshPadFromChannel(x: x, y: y)
            if x >= 0, x < vm.padGuideTargets.count, y >= 0, y < vm.padGuideTargets[x].count {
                vm.padGuideTargets[x][y] = 0
            }
        }
    }

    func onGuideLedUpdate(x: Int, y: Int, velocity: Int) {
        Task { @MainActor [weak self] in
            guard let vm = self?.viewModel, let cm = vm.channelManager else { return }
            if velocity > 0 {
                cm.add(x: x, y: y, channel: .guide, color: -1, code: velocity)
            } else {
                cm.remove(x: x, y: y, channel: .guide)
            }
            vm.refreshPadFromChannel(x: x, y: y)
        }
    }

    func onGuideChainOn(c: Int) {
        Task { @MainActor [weak self] in
            guard let vm = self?.viewModel, let cm = vm.channelManager else { return }
            let index = PlayViewModel.chainIndexOffset + c
            cm.add(x: -1, y: index, channel: .guide, color: -1, code: Self.guideVelocity)
            vm.refreshChainFromChannel(index: index)
        }
    }

    func onRemoveGuide() {
        Task { @MainActor [weak self] in
            self?.viewModel?.removeAllGuide()
        }
    }

    func chainButsRefresh() {
        Task { @MainActor [weak self] in
            self?.viewModel?.chainBtnsRefresh()
        }
    }

    func onProgressUpdate(progress: Int) {
        Task { @MainActor [weak self] in
            self?.viewModel?.autoPlayProgress = progress
        }
    }

    func onEnd() {
        Task { @MainActor [weak self] in
            guard let vm = self?.viewModel else { return }
            vm.autoPlayRunner?.practiceGuide = false
            vm.isPracticeMode = false
            vm.scbAutoPlay.setChecked(false)
            if let unipack = vm.unipack, unipack.keyLedExist {
                vm.scbLed.setChecked(true)
                vm.scbFeedbackLight.setChecked(false)
            } else {
                vm.scbFeedbackLight.setChecked(true)
            }
            vm.autoPlayControlVisible = false
            vm.isAutoPlayPlaying = false
        }
    }
}

// MARK: - MIDI Controller Adapter

private final class PlayMidiControllerAdapter: MidiController {
    private weak var viewModel: PlayViewModel?

    init(viewModel: PlayViewModel) {
        self.viewModel = viewModel
    }

    func onAttach() {
        Task { @MainActor [weak self] in
            guard let vm = self?.viewModel else { return }
            vm.redrawAllLaunchpadLeds()
            vm.chain.refresh()
            vm.refreshWatermark()
        }
    }

    func onDetach() {}

    func onPadTouch(x: Int, y: Int, upDown: Bool, velocity: Int) {
        Task { @MainActor [weak self] in
            guard let vm = self?.viewModel else { return }
            if !vm.isOptionWindowVisible {
                vm.padTouch(x: x, y: y, isDown: upDown)
            }
        }
    }

    func onChainTouch(c: Int, upDown: Bool) {
        Task { @MainActor [weak self] in
            guard let vm = self?.viewModel else { return }
            if !vm.isOptionWindowVisible && upDown {
                if let unipack = vm.unipack, unipack.chain > c {
                    vm.chain.setValue(c)
                }
            }
        }
    }

    func onFunctionKeyTouch(f: Int, upDown: Bool) {
        Task { @MainActor [weak self] in
            self?.viewModel?.handleFunctionKeyTouch(f: f, upDown: upDown)
        }
    }

    func onUnknownEvent(cmd: Int, sig: Int, note: Int, velocity: Int) {
        Task { @MainActor [weak self] in
            guard let vm = self?.viewModel else { return }
            if cmd == 7 && sig == 46 && note == 0 && velocity == -9 {
                vm.chain.refresh()
                vm.refreshWatermark()
            }
        }
    }
}
