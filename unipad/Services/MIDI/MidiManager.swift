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
    }

    private(set) var driver: MidiDriver = NotingDriver() {
        didSet {
            oldValue.sendClearLed()
            oldValue.cycleListener?.onDisconnected()
            setupDriverListeners()
            driver.initialize()
            if isConnected {
                driver.cycleListener?.onConnected()
            }
            listener?.onChangeDriver(driver: driver)
        }
    }

    weak var controller: MidiController?
    weak var listener: MidiManagerListener?

    // Send queue for batching MIDI output
    private let sendQueue = DispatchQueue(label: "com.kimjisub.unipad.midi.send")

    private var midiInputLogCount: Int = 0

    // Stored as nonisolated(unsafe) so the MIDI callback can reference it without actor hop
    nonisolated(unsafe) private var midiInputCallback: ((_ events: [(cmd: Int, sig: Int, note: Int, velocity: Int)]) -> Void)?

    // MARK: - Device Registry

    private struct DriverEntry {
        let name: String
        let factory: () -> MidiDriver
        let preferredPort: Int
    }

    private struct DriverRange {
        let pidStart: Int
        let pidEnd: Int
        let entry: DriverEntry
    }

    private let driverRegistryRanges: [DriverRange] = [
        DriverRange(pidStart: 0x0020, pidEnd: 0x002F,
                    entry: DriverEntry(name: "Launchpad S", factory: { LaunchpadSDriver() }, preferredPort: 0)),
        DriverRange(pidStart: 0x0036, pidEnd: 0x0036,
                    entry: DriverEntry(name: "Launchpad Mini", factory: { LaunchpadSDriver() }, preferredPort: 0)),
        DriverRange(pidStart: 0x0051, pidEnd: 0x0060,
                    entry: DriverEntry(name: "Launchpad Pro", factory: { LaunchpadProDriver() }, preferredPort: 0)),
        DriverRange(pidStart: 0x0069, pidEnd: 0x0078,
                    entry: DriverEntry(name: "Launchpad MK2", factory: { LaunchpadMK2Driver() }, preferredPort: 0)),
        DriverRange(pidStart: 0x0103, pidEnd: 0x0112,
                    entry: DriverEntry(name: "Launchpad X", factory: { LaunchpadXDriver() }, preferredPort: 1)),
        DriverRange(pidStart: 0x0113, pidEnd: 0x0122,
                    entry: DriverEntry(name: "Launchpad Mini MK3", factory: { LaunchpadMiniMK3Driver() }, preferredPort: 1)),
        DriverRange(pidStart: 0x0123, pidEnd: 0x0132,
                    entry: DriverEntry(name: "Launchpad Pro MK3", factory: { LaunchpadProMK3Driver() }, preferredPort: 1)),
    ]

    // MARK: - Initialization

    private init() {}

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
        midiInputCallback = nil
        _portIndexPtr?.deinitialize(count: 1)
        _portIndexPtr?.deallocate()
        _portIndexPtr = nil
    }

    // MARK: - CoreMIDI Setup

    private func setupCoreMIDI() {
        guard midiClient == 0 else { return }

        // Set up the input callback closure (captured by the MIDI port, no actor hop needed)
        midiInputCallback = { [weak self] events in
            Task { @MainActor [weak self] in
                guard let self else { return }
                if self.midiInputLogCount < 20 {
                    for event in events {
                        self.log("MIDI IN: cmd=\(event.cmd) sig=\(event.sig) note=\(event.note) vel=\(event.velocity)")
                    }
                    self.midiInputLogCount += events.count
                }
                for event in events {
                    self.driver.getSignal(
                        cmd: event.cmd,
                        sig: event.sig,
                        note: event.note,
                        velocity: event.velocity
                    )
                }
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
            let currentPortIndex = portIndex.pointee
            var events = [(cmd: Int, sig: Int, note: Int, velocity: Int)]()

            for packet in eventList.unsafeSequence() {
                let wordCount = Int(packet.pointee.wordCount)
                guard wordCount >= 1 else { continue }
                withUnsafePointer(to: packet.pointee.words) { tuplePtr in
                    tuplePtr.withMemoryRebound(to: UInt32.self, capacity: wordCount) { words in
                        for w in 0..<wordCount {
                            let word = words[w]
                            let midiStatus = Int((word >> 16) & 0xFF)
                            let data1 = Int((word >> 8) & 0xFF)
                            let data2 = Int(word & 0xFF)

                            if midiStatus == 0xF8 { continue }

                            let statusType = midiStatus & 0xF0
                            guard (0x80...0xE0).contains(statusType) else { continue }

                            let group = Int((word >> 24) & 0xF)
                            let cable = group != 0 ? group : currentPortIndex
                            let cmd = (cable << 4) | (statusType >> 4)
                            let sig = Int(Int8(truncatingIfNeeded: midiStatus))
                            events.append((cmd: cmd, sig: sig, note: data1, velocity: data2))
                        }
                    }
                }
            }

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
        listener?.onLog("MIDI scan: \(sourceCount) sources, \(destCount) destinations")

        // If already connected to a known (non-generic) driver, skip
        if connectedSource != 0 && !isGenericConnection {
            log("Already connected to \(connectedDeviceName ?? "?"), skip scan")
            return
        }

        // First pass: look for a known driver match
        for i in 0..<sourceCount {
            let source = MIDIGetSource(i)
            let name = getMIDIObjectName(source)
            log("Source[\(i)]: \(name)")
            listener?.onLog("Source[\(i)]: \(name)")

            if let matchedDriver = findDriverForDevice(name: name) {
                if connectedSource != 0 { disconnect() }
                connectToDevice(sourceIndex: i, driverEntry: matchedDriver)
                return
            }
        }

        // Second pass: generic fallback, skip virtual/network sources
        if connectedSource == 0 {
            for i in 0..<sourceCount {
                let source = MIDIGetSource(i)
                let name = getMIDIObjectName(source)
                if isVirtualSource(name: name) {
                    log("Skipping virtual: \(name)")
                    continue
                }
                let entry = DriverEntry(name: name, factory: { GenericDriver() }, preferredPort: 0)
                connectToDevice(sourceIndex: i, driverEntry: entry)
                return
            }
        }
    }

    private var isGenericConnection: Bool {
        driver is MasterKeyboardDriver
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
        // Launchpad Pro MK3 — sources: "LPProMK3 DAW Out", "LPProMK3 MIDI Out"
        ("lppromk3",  DriverEntry(name: "Launchpad Pro MK3", factory: { LaunchpadProMK3Driver() }, preferredPort: 1)),
        // Launchpad Pro — sources: "Launchpad Pro ..." (full name)
        ("lppro",     DriverEntry(name: "Launchpad Pro", factory: { LaunchpadProDriver() }, preferredPort: 0)),
        // Launchpad MK2 — sources: "Launchpad MK2 ..."
        ("lpmk2",     DriverEntry(name: "Launchpad MK2", factory: { LaunchpadMK2Driver() }, preferredPort: 0)),

        // Full-name fallbacks for older firmware or different OS versions
        ("launchpad mini mk3", DriverEntry(name: "Launchpad Mini MK3", factory: { LaunchpadMiniMK3Driver() }, preferredPort: 1)),
        ("launchpad x",        DriverEntry(name: "Launchpad X", factory: { LaunchpadXDriver() }, preferredPort: 1)),
        ("launchpad pro mk3",  DriverEntry(name: "Launchpad Pro MK3", factory: { LaunchpadProMK3Driver() }, preferredPort: 1)),
        ("launchpad pro",      DriverEntry(name: "Launchpad Pro", factory: { LaunchpadProDriver() }, preferredPort: 0)),
        ("launchpad mk2",      DriverEntry(name: "Launchpad MK2", factory: { LaunchpadMK2Driver() }, preferredPort: 0)),
        ("launchpad s",        DriverEntry(name: "Launchpad S", factory: { LaunchpadSDriver() }, preferredPort: 0)),
        ("launchpad mini",     DriverEntry(name: "Launchpad S", factory: { LaunchpadSDriver() }, preferredPort: 0)),
        ("launchpad",          DriverEntry(name: "Launchpad (Generic)", factory: { LaunchpadMK2Driver() }, preferredPort: 0)),

        // Non-Novation
        ("midi fighter", DriverEntry(name: "Midi Fighter", factory: { MidiFighterDriver() }, preferredPort: 0)),
        ("matrix",       DriverEntry(name: "Matrix", factory: { MatrixDriver() }, preferredPort: 0)),
    ]

    private func findDriverForDevice(name: String) -> DriverEntry? {
        let lowered = name.lowercased()

        for mapping in Self.sourceNameDriverMap {
            if lowered.hasPrefix(mapping.prefix) {
                return mapping.entry
            }
        }

        if lowered.contains("keyboard") || lowered.contains("piano") {
            return DriverEntry(name: "Master Keyboard", factory: { MasterKeyboardDriver() }, preferredPort: 0)
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
        driver = driverEntry.factory()
        isConnected = true
        midiInputLogCount = 0

        log("Connected: \(driverEntry.name), srcPort=\(connectedSourcePortIndex), dstPort=\(connectedDestinationPortIndex)")
        listener?.onLog("Connected: \(driverEntry.name) (sourcePort=\(connectedSourcePortIndex), destPort=\(connectedDestinationPortIndex))")
        listener?.onConnected()
    }

    func disconnect() {
        if connectedSource != 0 {
            MIDIPortDisconnectSource(inputPort, connectedSource)
        }

        driver.sendClearLed()
        driver.cycleListener?.onDisconnected()

        connectedSource = 0
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

    // MARK: - MIDI Output

    func sendMIDIMessage(cmd: UInt8, sig: UInt8, note: UInt8, velocity: UInt8) {
        let dest = connectedDestination
        let port = outputPort
        guard dest != 0, port != 0 else { return }

        sendQueue.async {
            var packetList = MIDIPacketList()
            var packet = MIDIPacketListInit(&packetList)
            let data: [UInt8] = [sig, note, velocity]
            packet = MIDIPacketListAdd(&packetList, Int(MemoryLayout<MIDIPacketList>.size), packet, 0, data.count, data)

            MIDISend(port, dest, &packetList)
        }
    }

    func sendSysEx(messages: [[UInt8]], cableNumber: Int = 0) {
        // SysEx always goes to DAW destination (entity 0), falling back to main destination
        let destination = connectedDawDestination != 0 ? connectedDawDestination : connectedDestination
        guard destination != 0 else { return }

        sendQueue.async {
            for (index, message) in messages.enumerated() {
                let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: message.count)
                buffer.initialize(from: message, count: message.count)

                // MIDISysexSendRequest must remain valid until completion callback fires.
                // CoreMIDI advances `data` and decrements `bytesToSend` during send,
                // so store the original buffer pointer in completionRefCon for deallocation.
                let context = Unmanaged.passRetained(
                    SysExContext(buffer: buffer, count: message.count)
                ).toOpaque()

                let requestPtr = UnsafeMutablePointer<MIDISysexSendRequest>.allocate(capacity: 1)
                requestPtr.initialize(to: MIDISysexSendRequest(
                    destination: destination,
                    data: UnsafePointer(buffer),
                    bytesToSend: UInt32(message.count),
                    complete: false,
                    reserved: (0, 0, 0),
                    completionProc: { completedPtr in
                        if let refCon = completedPtr.pointee.completionRefCon {
                            let ctx = Unmanaged<SysExContext>.fromOpaque(refCon).takeRetainedValue()
                            ctx.buffer.deinitialize(count: ctx.count)
                            ctx.buffer.deallocate()
                        }
                        completedPtr.deinitialize(count: 1)
                        completedPtr.deallocate()
                    },
                    completionRefCon: context
                ))
                MIDISendSysex(requestPtr)

                if index < messages.count - 1 {
                    Thread.sleep(forTimeInterval: 0.05)
                }
            }
        }
    }

    // MARK: - Driver Listener Setup

    private func setupDriverListeners() {
        let cycleListener = MidiManagerCycleAdapter(manager: self)
        let receiveListener = MidiManagerReceiveAdapter(manager: self)
        let sendListener = MidiManagerSendAdapter(manager: self)

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
        var name: Unmanaged<CFString>?
        let status = MIDIObjectGetStringProperty(obj, kMIDIPropertyName, &name)
        if status == noErr, let cfName = name?.takeRetainedValue() {
            return cfName as String
        }
        return "Unknown"
    }

    private func getMIDIObjectIntProperty(_ obj: MIDIObjectRef, _ property: CFString) -> Int32 {
        var value: Int32 = 0
        MIDIObjectGetIntegerProperty(obj, property, &value)
        return value
    }

}

private final class SysExContext {
    let buffer: UnsafeMutablePointer<UInt8>
    let count: Int
    init(buffer: UnsafeMutablePointer<UInt8>, count: Int) {
        self.buffer = buffer
        self.count = count
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

private final class MidiManagerSendAdapter: MidiDriverSendSignalListener {
    weak var manager: MidiManager?
    init(manager: MidiManager) { self.manager = manager }

    func onSend(cmd: UInt8, sig: UInt8, note: UInt8, velocity: UInt8) {
        Task { @MainActor in
            manager?.sendMIDIMessage(cmd: cmd, sig: sig, note: note, velocity: velocity)
        }
    }

    func onSendRaw(messages: [[UInt8]], cableNumber: Int) {
        Task { @MainActor in
            manager?.sendSysEx(messages: messages, cableNumber: cableNumber)
        }
    }
}
