import Foundation
import Combine
import CoreMIDI
import os.log

// MARK: - MidiController Protocol

protocol MidiController: AnyObject {
    func onAttach()
    func onDetach()
    func onPadTouch(x: Int, y: Int, upDown: Bool, velocity: Int)
    func onChainTouch(c: Int, upDown: Bool)
    func onFunctionKeyTouch(f: Int, upDown: Bool)
    func onUnknownEvent(cmd: Int, sig: Int, note: Int, velocity: Int)
}

// MARK: - MidiManager

@MainActor
final class MidiManager: ObservableObject {
    static let shared = MidiManager()

    private let logger = Logger(subsystem: "com.kimjisub.unipad", category: "MIDI")

    private var midiClient: MIDIClientRef = 0
    private var inputPort: MIDIPortRef = 0
    private var outputPort: MIDIPortRef = 0
    private var connectedSource: MIDIEndpointRef = 0
    private var connectedPriority = DevicePriority.generic
    private var connectedDestination: MIDIEndpointRef = 0
    private var connectedDawDestination: MIDIEndpointRef = 0
    private var connectedDeviceEntity: MIDIEntityRef = 0
    private var connectedSourcePortIndex: Int = 0
    private var connectedDestinationPortIndex: Int = 0

    @Published private(set) var isConnected = false
    @Published private(set) var connectedDeviceName: String?
    @Published private(set) var debugLog: [String] = []

    private func log(_ message: String) {
        logger.info("\(message)")
        debugLog.append(message)
        if debugLog.count > 50 { debugLog.removeFirst() }
        listener?.onLog(message)
    }

    func clearDebugLog() {
        debugLog.removeAll()
    }

    private(set) var driver: MidiDriver = NotingDriver() {
        didSet {
            oldValue.sendClearLed()
            oldValue.cycleListener?.onDisconnected()
            driverVersion += 1
            setupDriverListeners()
            if isConnected {
                let version = driverVersion
                sendQueue.initialize(driver) { [weak self] in
                    Task { @MainActor [weak self] in
                        guard let self, self.isConnected, self.driverVersion == version else { return }
                        self.driver.cycleListener?.onConnected()
                    }
                }
            } else {
                driver.initialize()
            }
            listener?.onChangeDriver(driver: driver)
        }
    }

    weak var controller: MidiController?
    weak var listener: MidiManagerListener?

    // Send queue for batching MIDI output
    private let sendQueue: MidiOutputQueue
    private var driverVersion = 0
    private let inputDecoder = MidiInputDecoder()

    private var midiInputLogCount: Int = 0

    /// One channel message for the driver: `cmd` carries the port in its high nibble and the message
    /// kind in its low nibble, as the first byte of a USB MIDI packet does.
    typealias InputEvent = MidiInputDecoder.Event

    // Stored as nonisolated(unsafe) so the MIDI callback can reference it without actor hop
    nonisolated(unsafe) private var midiInputCallback: ((_ events: [InputEvent]) -> Void)?

    // MARK: - Device Registry

    enum DevicePriority: Int {
        case generic, keyboard, dedicated
    }

    struct DriverEntry {
        let name: String
        let factory: () -> MidiDriver
        let preferredPort: Int
        let priority: DevicePriority

        init(name: String, factory: @escaping () -> MidiDriver, preferredPort: Int, priority: DevicePriority = .dedicated) {
            self.name = name
            self.factory = factory
            self.preferredPort = preferredPort
            self.priority = priority
        }
    }

    private static let keyboardDriver = DriverEntry(
        name: "Master Keyboard", factory: { MasterKeyboardDriver() }, preferredPort: 0, priority: .keyboard
    )

    // MARK: - Initialization

    init(sendQueue: MidiOutputQueue = MidiOutputQueue()) {
        self.sendQueue = sendQueue
    }

    func start() {
        log("MidiManager.start()")
        setupDriverListeners()
        setupCoreMIDI()
        scanForDevices()
    }

    func stop() {
        disconnect()
        if midiClient != 0 {
            MIDIClientDispose(midiClient)
            midiClient = 0
        }
        // Disposing the client invalidates its ports; a send between stop() and the next start()
        // passed the stale refs to MIDISend.
        inputPort = 0
        outputPort = 0
        midiInputCallback = nil
        // The CoreMIDI read block captured this pointer and may still be running on the MIDI
        // thread when the client is disposed; one leaked Int per stop() is cheaper than a
        // use-after-free there.
        _portIndexPtr = nil
    }

    // MARK: - CoreMIDI Setup

    private func setupCoreMIDI() {
        guard midiClient == 0 else { return }

        // Set up the input callback closure (captured by the MIDI port, no actor hop needed)
        midiInputCallback = { [weak self] events in
            Task { @MainActor [weak self] in
                self?.receive(events)
            }
        }

        let clientName = "UniPad" as CFString

        let status = MIDIClientCreateWithBlock(clientName, &midiClient) { [weak self] notification in
            let messageID = notification.pointee.messageID
            Task { @MainActor in
                self?.handleMIDINotification(messageID)
            }
        }

        log("MIDI client create status: \(status)")
        guard status == noErr else {
            log("ERROR: Failed to create MIDI client: \(status)")
            return
        }

        // Capture values needed by the MIDI input callback to avoid actor-isolated access
        let callback = midiInputCallback
        let decoder = inputDecoder
        let portIndex = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        portIndex.initialize(to: 0)
        _portIndexPtr = portIndex

        let inputName = "UniPad Input" as CFString
        var inPort: MIDIPortRef = 0
        let inputOSStatus = MIDIInputPortCreateWithProtocol(
            midiClient,
            inputName,
            ._1_0,
            &inPort
        ) { eventList, srcConnRefCon in
            // Parse MIDI data synchronously — no actor access
            let events = Self.channelMessages(in: eventList, port: portIndex.pointee, decoder: decoder)
            guard !events.isEmpty else { return }
            callback?(events)
        }
        log("MIDI input port create status: \(inputOSStatus)")
        if inputOSStatus == noErr {
            inputPort = inPort
        } else {
            log("ERROR: Failed to create MIDI input port: \(inputOSStatus)")
        }

        var outPort: MIDIPortRef = 0
        let outputStatus = MIDIOutputPortCreate(midiClient, "UniPad Output" as CFString, &outPort)
        log("MIDI output port create status: \(outputStatus)")
        if outputStatus == noErr {
            outputPort = outPort
        } else {
            log("ERROR: Failed to create MIDI output port: \(outputStatus)")
        }
    }

    /// Shared pointer for MIDI callback to read portIndex without actor hop
    private var _portIndexPtr: UnsafeMutablePointer<Int>?

    /// Reads the actual packet storage, including packets longer than the struct's 64-word tuple.
    /// Keep the decoder across callbacks so a split Pro Live notification can complete, while each
    /// Universal MIDI Packet is still consumed by its full length before reading the next message.
    nonisolated static func channelMessages(
        in eventList: UnsafePointer<MIDIEventList>, port: Int,
        decoder: MidiInputDecoder = MidiInputDecoder()
    ) -> [InputEvent] {
        var events: [InputEvent] = []
        for packet in eventList.unsafeSequence() {
            events += decoder.decode(Array(packet.words()), portIndex: port)
        }
        return events
    }

    /// Hands channel messages read from the connected source to the driver, in order.
    func receive(_ events: [InputEvent]) {
        if midiInputLogCount < 20 {
            for event in events {
                log("MIDI IN: cmd=\(event.cmd) sig=\(event.sig) note=\(event.note) vel=\(event.velocity)")
            }
            midiInputLogCount += events.count
        }
        for event in events {
            driver.getSignal(cmd: event.cmd, sig: event.sig, note: event.note, velocity: event.velocity)
        }
    }

    private func handleMIDINotification(_ messageID: MIDINotificationMessageID) {
        log("MIDI notification: \(messageID.rawValue)")
        switch messageID {
        case .msgSetupChanged:
            scanForDevices()
        case .msgObjectAdded:
            scanForDevices()
        case .msgObjectRemoved:
            if connectedSource != 0 {
                let sourceCount = MIDIGetNumberOfSources()
                var found = false
                for i in 0..<sourceCount {
                    if MIDIGetSource(i) == connectedSource {
                        found = true
                        break
                    }
                }
                if !found {
                    disconnect()
                }
            }
        default:
            break
        }
    }

    // MARK: - Device Discovery

    func scanForDevices() {
        let sourceCount = MIDIGetNumberOfSources()
        let destCount = MIDIGetNumberOfDestinations()

        log("MIDI scan: \(sourceCount) sources, \(destCount) destinations")

        // Dedicated drivers already have the highest priority. Preserve manual model choices too.
        if connectedSource != 0 && !(driver is MasterKeyboardDriver) {
            log("Already connected to \(connectedDeviceName ?? "?"), skip scan")
            return
        }

        // Rank the whole list before the first connection. GenericDriver aliases MasterKeyboardDriver,
        // so the discovered entry, rather than the driver's type, distinguishes fallback from keyboard.
        var best: (index: Int, source: MIDIEndpointRef, entry: DriverEntry)?
        for i in 0..<sourceCount {
            let source = MIDIGetSource(i)
            let name = getMIDIObjectName(source)
            log("Source[\(i)]: \(name)")

            let entry: DriverEntry
            if let matched = findDriverForSource(source) {
                entry = matched
            } else {
                if isVirtualSource(name: name) {
                    log("Skipping virtual: \(name)")
                    continue
                }
                entry = DriverEntry(name: name, factory: { GenericDriver() }, preferredPort: 0, priority: .generic)
            }
            if let best, best.entry.priority.rawValue >= entry.priority.rawValue { continue }
            best = (i, source, entry)
        }

        guard let best else { return }
        if connectedSource != 0 {
            guard best.source != connectedSource, best.entry.priority.rawValue > connectedPriority.rawValue else {
                log("Keeping connection to \(connectedDeviceName ?? "?")")
                return
            }
            disconnect()
        }
        connectToDevice(sourceIndex: best.index, driverEntry: best.entry)
    }

    private func isVirtualSource(name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.contains("session") || lowered.contains("network") || lowered == "bluetooth"
    }

    /// CoreMIDI source name prefix → driver mapping.
    /// Order matters: more specific prefixes must come before generic ones (e.g. "lppromk3" before "lppro").
    private static let sourceNameDriverMap: [(prefix: String, entry: DriverEntry)] = [
        // Launchpad Mini MK3 — sources: "LPMiniMK3 DAW Out", "LPMiniMK3 MIDI Out"
        ("lpminimk3", DriverEntry(name: "Launchpad Mini MK3", factory: { LaunchpadMiniMK3Driver() }, preferredPort: 1)),
        // Launchpad X — sources: "LPX DAW Out", "LPX MIDI Out"
        ("lpx",       DriverEntry(name: "Launchpad X", factory: { LaunchpadXDriver() }, preferredPort: 1)),
        // Launchpad Pro MK3 — interfaces in order: "LPProMK3 MIDI", "LPProMK3 DIN", "LPProMK3 DAW".
        // Programmer mode reports the pads on, and lights LEDs sent to, the first (MIDI) one.
        ("lppromk3",  DriverEntry(name: "Launchpad Pro MK3", factory: { LaunchpadProMK3Driver() }, preferredPort: 0)),
        // Launchpad Pro — sources: "Launchpad Pro ..." (full name)
        ("lppro",     DriverEntry(name: "Launchpad Pro", factory: { LaunchpadProDriver() }, preferredPort: 0)),
        // Launchpad MK2 — sources: "Launchpad MK2 ..."
        ("lpmk2",     DriverEntry(name: "Launchpad MK2", factory: { LaunchpadMK2Driver() }, preferredPort: 0)),

        // Full-name fallbacks for stock firmware (checked before CFW)
        ("launchpad mini mk3", DriverEntry(name: "Launchpad Mini MK3", factory: { LaunchpadMiniMK3Driver() }, preferredPort: 1)),
        ("launchpad x",        DriverEntry(name: "Launchpad X", factory: { LaunchpadXDriver() }, preferredPort: 1)),
        ("launchpad pro mk3",  DriverEntry(name: "Launchpad Pro MK3", factory: { LaunchpadProMK3Driver() }, preferredPort: 0)),
        ("launchpad open",     DriverEntry(name: "Launchpad Pro (mat1jaczyyy CFW)", factory: { LaunchpadProCFWDriver() }, preferredPort: 0)),
        ("launchpad pro",      DriverEntry(name: "Launchpad Pro", factory: { LaunchpadProDriver() }, preferredPort: 0)),
        ("launchpad mk2",      DriverEntry(name: "Launchpad MK2", factory: { LaunchpadMK2Driver() }, preferredPort: 0)),
        ("launchpad s",        DriverEntry(name: "Launchpad S", factory: { LaunchpadSDriver() }, preferredPort: 0)),
        ("launchpad mini",     DriverEntry(name: "Launchpad S", factory: { LaunchpadSDriver() }, preferredPort: 0)),
        ("launchpad",          DriverEntry(name: "Launchpad", factory: { LaunchpadSDriver() }, preferredPort: 0)),

        // CoreFW mappings (Pro, MK2, S, Mini, X, Mini MK3, Pro MK3)
        ("pro (midi)",         DriverEntry(name: "Launchpad (CoreFW)", factory: { LaunchpadCoreCFWDriver() }, preferredPort: 1)),
        ("pro (daw)",          DriverEntry(name: "Launchpad (CoreFW)", factory: { LaunchpadCoreCFWDriver() }, preferredPort: 1)),
        ("mk2 (midi)",         DriverEntry(name: "Launchpad (CoreFW)", factory: { LaunchpadCoreCFWDriver() }, preferredPort: 1)),
        ("mk2 (daw)",          DriverEntry(name: "Launchpad (CoreFW)", factory: { LaunchpadCoreCFWDriver() }, preferredPort: 1)),
        ("lps (midi)",         DriverEntry(name: "Launchpad (CoreFW)", factory: { LaunchpadCoreCFWDriver(ledColors: .redGreen) }, preferredPort: 1)),
        ("lps (daw)",          DriverEntry(name: "Launchpad (CoreFW)", factory: { LaunchpadCoreCFWDriver(ledColors: .redGreen) }, preferredPort: 1)),
        ("mini (midi)",        DriverEntry(name: "Launchpad (CoreFW)", factory: { LaunchpadCoreCFWDriver(ledColors: .redGreen) }, preferredPort: 1)),
        ("mini (daw)",         DriverEntry(name: "Launchpad (CoreFW)", factory: { LaunchpadCoreCFWDriver(ledColors: .redGreen) }, preferredPort: 1)),
        ("lpx (midi)",         DriverEntry(name: "Launchpad (CoreFW)", factory: { LaunchpadCoreCFWDriver() }, preferredPort: 1)),
        ("lpx (daw)",          DriverEntry(name: "Launchpad (CoreFW)", factory: { LaunchpadCoreCFWDriver() }, preferredPort: 1)),
        ("mini mk3 (midi)",    DriverEntry(name: "Launchpad (CoreFW)", factory: { LaunchpadCoreCFWDriver() }, preferredPort: 1)),
        ("mini mk3 (daw)",     DriverEntry(name: "Launchpad (CoreFW)", factory: { LaunchpadCoreCFWDriver() }, preferredPort: 1)),
        ("pro mk3 (midi)",     DriverEntry(name: "Launchpad (CoreFW)", factory: { LaunchpadCoreCFWDriver() }, preferredPort: 1)),
        ("pro mk3 (daw)",      DriverEntry(name: "Launchpad (CoreFW)", factory: { LaunchpadCoreCFWDriver() }, preferredPort: 1)),

        // Non-Novation
        ("midi fighter", DriverEntry(name: "Midi Fighter", factory: { MidiFighterDriver() }, preferredPort: 0)),
        ("mystrix pro",  DriverEntry(name: "Mystrix", factory: { MatrixDriver() }, preferredPort: 0)),
        ("mystrix",      DriverEntry(name: "Mystrix", factory: { MatrixDriver() }, preferredPort: 0)),
        ("matrix pro",   DriverEntry(name: "Mystrix", factory: { MatrixDriver() }, preferredPort: 0)),
        ("matrix",       DriverEntry(name: "Mystrix", factory: { MatrixDriver() }, preferredPort: 0)),
    ]

    /// CoreFW endpoints are always named "<target> (PORT)", which stock firmware never uses.
    static func coreFWDriverEntry(sourceName: String) -> DriverEntry? {
        let lowered = sourceName.lowercased()
        return sourceNameDriverMap.first { mapping in
            mapping.entry.name == "Launchpad (CoreFW)" && lowered.hasPrefix(mapping.prefix)
        }?.entry
    }

    private func findDriverForSource(_ source: MIDIEndpointRef) -> DriverEntry? {
        let sourceName = getMIDIObjectName(source)
        let displayName = getMIDIObjectStringProperty(source, kMIDIPropertyDisplayName) ?? sourceName

        var entity: MIDIEntityRef = 0
        MIDIEndpointGetEntity(source, &entity)

        var entityName = ""
        var deviceName = ""
        var modelName = ""

        if entity != 0 {
            entityName = getMIDIObjectName(entity)
            var device: MIDIDeviceRef = 0
            MIDIEntityGetDevice(entity, &device)
            if device != 0 {
                deviceName = getMIDIObjectName(device)
                modelName = getMIDIObjectStringProperty(device, kMIDIPropertyModel) ?? ""
            }
        }

        // 1. Check CoreFW by source/endpoint name first
        if let coreFW = Self.coreFWDriverEntry(sourceName: sourceName) {
            return coreFW
        }

        // 2. Check sourceName, displayName, deviceName, entityName, and modelName against sourceNameDriverMap
        let candidateNames = [displayName, deviceName, entityName, modelName, sourceName].filter { !$0.isEmpty }
        if let named = candidateNames.lazy.compactMap({ Self.driverEntry(forName: $0) }).first {
            return named
        }

        // 3. Keyboard / Piano keywords
        for candidate in candidateNames {
            let lowered = candidate.lowercased()
            if lowered.contains("keyboard") || lowered.contains("piano") {
                return Self.keyboardDriver
            }
        }

        return nil
    }

    /// The driver whose prefix starts a CoreMIDI source, display, device, entity or model name.
    static func driverEntry(forName name: String) -> DriverEntry? {
        let lowered = name.lowercased()

        for mapping in Self.sourceNameDriverMap {
            if lowered.hasPrefix(mapping.prefix) {
                return mapping.entry
            }
        }

        if lowered.contains("keyboard") || lowered.contains("piano") {
            return Self.keyboardDriver
        }

        return nil
    }

    // MARK: - Connection

    private func connectToDevice(sourceIndex: Int, driverEntry: DriverEntry) {
        log("MIDI:start: \(driverEntry.name), sourceIndex=\(sourceIndex), preferredPort=\(driverEntry.preferredPort)")
        let discoveredSource = MIDIGetSource(sourceIndex)

        // Navigate: Source → Entity → Device to find the correct entity for preferredPort
        var discoveredEntity: MIDIEntityRef = 0
        MIDIEndpointGetEntity(discoveredSource, &discoveredEntity)

        var device: MIDIDeviceRef = 0
        if discoveredEntity != 0 {
            MIDIEntityGetDevice(discoveredEntity, &device)
        }

        // Resolve source entity: use Device's entity[preferredPort] if available
        let sourceEntity: MIDIEntityRef
        if device != 0 {
            let entityCount = MIDIDeviceGetNumberOfEntities(device)
            log("MIDI:device entities=\(entityCount)")
            if driverEntry.preferredPort < entityCount {
                sourceEntity = MIDIDeviceGetEntity(device, driverEntry.preferredPort)
            } else {
                sourceEntity = discoveredEntity
            }
        } else {
            sourceEntity = discoveredEntity
        }

        // Get source from the resolved entity
        let source: MIDIEndpointRef
        let srcCount = sourceEntity != 0 ? MIDIEntityGetNumberOfSources(sourceEntity) : 0
        if srcCount > 0 {
            source = MIDIEntityGetSource(sourceEntity, 0)
            connectedSourcePortIndex = driverEntry.preferredPort
            _portIndexPtr?.pointee = driverEntry.preferredPort
        } else {
            source = discoveredSource
            connectedSourcePortIndex = 0
            _portIndexPtr?.pointee = 0
        }
        log("MIDI:source entity=\(sourceEntity), source=\(source), srcName=\(getMIDIObjectName(source))")

        connectedDeviceEntity = discoveredEntity  // keep DAW entity for SysEx routing

        let status = MIDIPortConnectSource(inputPort, source, nil)
        guard status == noErr else {
            log("ERROR: Failed to connect to MIDI source: \(status)")
            return
        }

        connectedSource = source
        connectedPriority = driverEntry.priority
        connectedDeviceName = driverEntry.name

        // Resolve destination: use DAW entity (entity 0) for SysEx, MIDI entity for pad LEDs
        // For multi-entity devices, store both DAW and MIDI destinations
        if device != 0 {
            let entityCount = MIDIDeviceGetNumberOfEntities(device)
            // DAW destination (entity 0) — used for SysEx
            if entityCount > 0 {
                let dawEntity = MIDIDeviceGetEntity(device, 0)
                let dawDestCount = MIDIEntityGetNumberOfDestinations(dawEntity)
                if dawDestCount > 0 {
                    connectedDawDestination = MIDIEntityGetDestination(dawEntity, 0)
                    log("MIDI:DAW dest=\(connectedDawDestination), name=\(getMIDIObjectName(connectedDawDestination))")
                }
            }
            // MIDI destination (entity[preferredPort]) — used for pad LEDs
            if driverEntry.preferredPort < entityCount {
                let midiEntity = MIDIDeviceGetEntity(device, driverEntry.preferredPort)
                let midiDestCount = MIDIEntityGetNumberOfDestinations(midiEntity)
                if midiDestCount > 0 {
                    connectedDestination = MIDIEntityGetDestination(midiEntity, 0)
                    connectedDestinationPortIndex = driverEntry.preferredPort
                    log("MIDI:MIDI dest=\(connectedDestination), name=\(getMIDIObjectName(connectedDestination))")
                }
            }
        }

        // Fallback: if no MIDI destination, use DAW destination
        if connectedDestination == 0 {
            connectedDestination = connectedDawDestination
            connectedDestinationPortIndex = 0
        }
        // Fallback: global destination
        if connectedDestination == 0 {
            let globalDestCount = MIDIGetNumberOfDestinations()
            if globalDestCount > 0 {
                connectedDestination = MIDIGetDestination(0)
                connectedDestinationPortIndex = 0
            }
        }

        log("MIDI:setting driver...")
        sendQueue.reset()
        // isConnected first: the driver's didSet only fires cycleListener.onConnected (which draws
        // the current LEDs onto the new device) when it is already true, so a hot-plugged
        // Launchpad stayed dark until an unrelated redraw.
        isConnected = true
        driver = driverEntry.factory()
        midiInputLogCount = 0

        log("Connected: \(driverEntry.name), srcPort=\(connectedSourcePortIndex), dstPort=\(connectedDestinationPortIndex)")
        listener?.onLog("Connected: \(driverEntry.name) (sourcePort=\(connectedSourcePortIndex), destPort=\(connectedDestinationPortIndex))")
        listener?.onConnected()
    }

    func disconnect() {
        sendQueue.reset()
        inputDecoder.reset()
        if connectedSource != 0 {
            MIDIPortDisconnectSource(inputPort, connectedSource)
        }

        driver.sendClearLed()
        driver.cycleListener?.onDisconnected()

        connectedSource = 0
        connectedPriority = .generic
        connectedDestination = 0
        connectedDawDestination = 0
        connectedDeviceEntity = 0
        connectedSourcePortIndex = 0
        _portIndexPtr?.pointee = 0
        connectedDestinationPortIndex = 0
        connectedDeviceName = nil
        isConnected = false
        driver = NotingDriver()

        listener?.onDisconnected()
    }

    func overrideDriver(_ newDriver: MidiDriver) {
        driver = newDriver
    }

    func removeController(_ target: MidiController) {
        if controller === target {
            controller = nil
        }
    }

    // MIDI input handling is now inline in setupCoreMIDI's MIDIInputPortCreateWithProtocol callback

    // MARK: - Driver Listener Setup

    private func setupDriverListeners() {
        let cycleListener = MidiManagerCycleAdapter(manager: self)
        let receiveListener = MidiManagerReceiveAdapter(manager: self)
        let destination = connectedDawDestination != 0 ? connectedDawDestination : connectedDestination
        let sendListener = MidiManagerSendAdapter(output: sendQueue, port: outputPort,
                                                 destination: connectedDestination, sysexDestination: destination) { [weak self] status in
            Task { @MainActor [weak self] in self?.log("MIDISendSysex failed: \(status)") }
        }

        driver.cycleListener = cycleListener
        driver.receiveSignalListener = receiveListener
        driver.sendSignalListener = sendListener

        // Hold strong references via associated storage
        _cycleAdapter = cycleListener
        _receiveAdapter = receiveListener
        _sendAdapter = sendListener
    }

    private var _cycleAdapter: MidiManagerCycleAdapter?
    private var _receiveAdapter: MidiManagerReceiveAdapter?
    private var _sendAdapter: MidiManagerSendAdapter?

    // MARK: - Helpers

    private func getMIDIObjectName(_ obj: MIDIObjectRef) -> String {
        getMIDIObjectStringProperty(obj, kMIDIPropertyName) ?? "Unknown"
    }

    private func getMIDIObjectStringProperty(_ obj: MIDIObjectRef, _ property: CFString) -> String? {
        var name: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(obj, property, &name)
        if status == noErr, let cfName = name?.takeRetainedValue() {
            return cfName as String
        }
        return nil
    }

}

// MARK: - Listener Protocol

protocol MidiManagerListener: AnyObject {
    func onConnected()
    func onDisconnected()
    func onChangeDriver(driver: MidiDriver)
    func onLog(_ message: String)
}

// MARK: - Listener Adapters

private final class MidiManagerCycleAdapter: MidiDriverCycleListener {
    weak var manager: MidiManager?
    init(manager: MidiManager) { self.manager = manager }

    func onConnected() {
        Task { @MainActor in
            manager?.controller?.onAttach()
        }
    }

    func onDisconnected() {
        Task { @MainActor in
            manager?.controller?.onDetach()
        }
    }
}

private final class MidiManagerReceiveAdapter: MidiDriverReceiveSignalListener {
    weak var manager: MidiManager?
    init(manager: MidiManager) { self.manager = manager }

    func onReceived(cmd: Int, sig: Int, note: Int, velocity: Int) {
        Task { @MainActor in
            manager?.controller?.onUnknownEvent(cmd: cmd, sig: sig, note: note, velocity: velocity)
        }
    }

    func onUnknownReceived(cmd: Int, sig: Int, note: Int, velocity: Int) {
        Task { @MainActor in
            manager?.controller?.onUnknownEvent(cmd: cmd, sig: sig, note: note, velocity: velocity)
        }
    }

    func onPadTouch(x: Int, y: Int, upDown: Bool, velocity: Int) {
        Task { @MainActor in
            manager?.controller?.onPadTouch(x: x, y: y, upDown: upDown, velocity: velocity)
        }
    }

    func onChainTouch(c: Int, upDown: Bool) {
        Task { @MainActor in
            manager?.controller?.onChainTouch(c: c, upDown: upDown)
        }
    }

    func onFunctionKeyTouch(f: Int, upDown: Bool) {
        Task { @MainActor in
            manager?.controller?.onFunctionKeyTouch(f: f, upDown: upDown)
        }
    }
}

nonisolated final class MidiManagerSendAdapter: MidiDriverSendSignalListener {
    let output: MidiOutputQueue
    let port: MIDIPortRef
    let destination: MIDIEndpointRef
    let sysexDestination: MIDIEndpointRef
    let onFailure: @Sendable (OSStatus) -> Void

    init(output: MidiOutputQueue, port: MIDIPortRef, destination: MIDIEndpointRef,
         sysexDestination: MIDIEndpointRef, onFailure: @escaping @Sendable (OSStatus) -> Void) {
        self.output = output
        self.port = port
        self.destination = destination
        self.sysexDestination = sysexDestination
        self.onFailure = onFailure
    }

    func onSend(cmd: UInt8, sig: UInt8, note: UInt8, velocity: UInt8) {
        output.send([sig, note, velocity], port: port, destination: destination)
    }

    func onSendRaw(messages: [[UInt8]], cableNumber: Int) {
        // Endpoints were selected when the driver was installed. Snapshot them so
        // queued messages cannot be redirected to a newly connected device.
        output.sendSysEx(messages, destination: sysexDestination, onFailure: onFailure)
    }
}
