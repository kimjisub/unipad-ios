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
    private var connectedDeviceEntity: MIDIEntityRef = 0

    @Published private(set) var isConnected = false
    @Published private(set) var connectedDeviceName: String?

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

    // MARK: - Device Registry

    private struct DriverEntry {
        let name: String
        let factory: () -> MidiDriver
    }

    private struct DriverRange {
        let pidStart: Int
        let pidEnd: Int
        let entry: DriverEntry
    }

    private let driverRegistryRanges: [DriverRange] = [
        DriverRange(pidStart: 0x0020, pidEnd: 0x002F,
                    entry: DriverEntry(name: "Launchpad S") { LaunchpadSDriver() }),
        DriverRange(pidStart: 0x0036, pidEnd: 0x0036,
                    entry: DriverEntry(name: "Launchpad Mini") { LaunchpadSDriver() }),
        DriverRange(pidStart: 0x0051, pidEnd: 0x0060,
                    entry: DriverEntry(name: "Launchpad Pro") { LaunchpadProDriver() }),
        DriverRange(pidStart: 0x0069, pidEnd: 0x0078,
                    entry: DriverEntry(name: "Launchpad MK2") { LaunchpadMK2Driver() }),
        DriverRange(pidStart: 0x0103, pidEnd: 0x0112,
                    entry: DriverEntry(name: "Launchpad X") { LaunchpadXDriver() }),
        DriverRange(pidStart: 0x0113, pidEnd: 0x0122,
                    entry: DriverEntry(name: "Launchpad Mini MK3") { LaunchpadMiniMK3Driver() }),
        DriverRange(pidStart: 0x0123, pidEnd: 0x0132,
                    entry: DriverEntry(name: "Launchpad Pro MK3") { LaunchpadProMK3Driver() }),
    ]

    // MARK: - Initialization

    private init() {}

    func start() {
        setupCoreMIDI()
        scanForDevices()
    }

    func stop() {
        disconnect()
        if midiClient != 0 {
            MIDIClientDispose(midiClient)
            midiClient = 0
        }
    }

    // MARK: - CoreMIDI Setup

    private func setupCoreMIDI() {
        let clientName = "UniPad" as CFString

        let status = MIDIClientCreateWithBlock(clientName, &midiClient) { [weak self] notification in
            Task { @MainActor in
                self?.handleMIDINotification(notification)
            }
        }

        guard status == noErr else {
            logger.error("Failed to create MIDI client: \(status)")
            return
        }

        let inputName = "UniPad Input" as CFString
        var inPort: MIDIPortRef = 0
        let inputOSStatus = MIDIInputPortCreateWithProtocol(
            midiClient,
            inputName,
            ._1_0,
            &inPort
        ) { [weak self] eventList, srcConnRefCon in
            self?.handleMIDIInput(eventList: eventList)
        }
        if inputOSStatus == noErr {
            inputPort = inPort
        } else {
            logger.error("Failed to create MIDI input port: \(inputOSStatus)")
        }

        var outPort: MIDIPortRef = 0
        let outputStatus = MIDIOutputPortCreate(midiClient, "UniPad Output" as CFString, &outPort)
        if outputStatus == noErr {
            outputPort = outPort
        } else {
            logger.error("Failed to create MIDI output port: \(outputStatus)")
        }
    }

    private func handleMIDINotification(_ notification: UnsafePointer<MIDINotification>) {
        switch notification.pointee.messageID {
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

        logger.info("MIDI scan: \(sourceCount) sources, \(destCount) destinations")

        if connectedSource != 0 { return }

        for i in 0..<sourceCount {
            let source = MIDIGetSource(i)
            let name = getMIDIObjectName(source)
            logger.info("MIDI Source[\(i)]: \(name)")

            if let matchedDriver = findDriverForDevice(name: name) {
                connectToDevice(sourceIndex: i, driverEntry: matchedDriver)
                return
            }
        }

        // Fallback: connect to first available source with generic driver
        if sourceCount > 0 {
            let entry = DriverEntry(name: "Generic") { GenericDriver() }
            connectToDevice(sourceIndex: 0, driverEntry: entry)
        }
    }

    private func findDriverForDevice(name: String) -> DriverEntry? {
        let lowered = name.lowercased()

        if lowered.contains("launchpad mini mk3") {
            return DriverEntry(name: "Launchpad Mini MK3") { LaunchpadMiniMK3Driver() }
        }
        if lowered.contains("launchpad x") {
            return DriverEntry(name: "Launchpad X") { LaunchpadXDriver() }
        }
        if lowered.contains("launchpad pro mk3") || lowered.contains("launchpad pro 3") {
            return DriverEntry(name: "Launchpad Pro MK3") { LaunchpadProMK3Driver() }
        }
        if lowered.contains("launchpad pro") {
            return DriverEntry(name: "Launchpad Pro") { LaunchpadProDriver() }
        }
        if lowered.contains("launchpad mk2") || lowered.contains("launchpad mk 2") {
            return DriverEntry(name: "Launchpad MK2") { LaunchpadMK2Driver() }
        }
        if lowered.contains("launchpad s") {
            return DriverEntry(name: "Launchpad S") { LaunchpadSDriver() }
        }
        if lowered.contains("launchpad") {
            return DriverEntry(name: "Launchpad (Generic)") { LaunchpadMK2Driver() }
        }
        if lowered.contains("midi fighter") {
            return DriverEntry(name: "Midi Fighter") { MidiFighterDriver() }
        }
        if lowered.contains("matrix") {
            return DriverEntry(name: "Matrix") { MatrixDriver() }
        }
        if lowered.contains("keyboard") || lowered.contains("piano") {
            return DriverEntry(name: "Master Keyboard") { MasterKeyboardDriver() }
        }

        return nil
    }

    // MARK: - Connection

    private func connectToDevice(sourceIndex: Int, driverEntry: DriverEntry) {
        let source = MIDIGetSource(sourceIndex)

        let status = MIDIPortConnectSource(inputPort, source, nil)
        guard status == noErr else {
            logger.error("Failed to connect to MIDI source: \(status)")
            return
        }

        connectedSource = source
        connectedDeviceName = driverEntry.name

        // Find matching destination from the same entity as the source
        var entity: MIDIEntityRef = 0
        MIDIEndpointGetEntity(source, &entity)
        connectedDeviceEntity = entity

        if entity != 0 {
            let destCount = MIDIEntityGetNumberOfDestinations(entity)
            if destCount > 0 {
                connectedDestination = MIDIEntityGetDestination(entity, 0)
                logger.info("Found \(destCount) destination(s) on same entity")
            }
        }

        // Fallback to first available destination if entity match failed
        if connectedDestination == 0 {
            let globalDestCount = MIDIGetNumberOfDestinations()
            if globalDestCount > 0 {
                connectedDestination = MIDIGetDestination(0)
            }
        }

        driver = driverEntry.factory()
        isConnected = true

        logger.info("Connected to MIDI device: \(driverEntry.name)")
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
        connectedDeviceEntity = 0
        connectedDeviceName = nil
        isConnected = false
        driver = NotingDriver()

        listener?.onDisconnected()
    }

    func removeController(_ target: MidiController) {
        if controller === target {
            controller = nil
        }
    }

    // MARK: - MIDI Input Handling

    private nonisolated func handleMIDIInput(eventList: UnsafePointer<MIDIEventList>) {
        let list = eventList.pointee
        var packet = list.packet

        for _ in 0..<list.numPackets {
            let wordCount = Int(packet.wordCount)
            if wordCount >= 1 {
                withUnsafePointer(to: &packet.words) { wordsPtr in
                    wordsPtr.withMemoryRebound(to: UInt32.self, capacity: wordCount) { words in
                        for w in 0..<wordCount {
                            let word = words[w]
                            let byte0 = Int((word >> 16) & 0xFF)
                            let byte1 = Int((word >> 8) & 0xFF)
                            let byte2 = Int(word & 0xFF)

                            // Skip MIDI Clock (0xF8)
                            if byte0 == 0xF8 { continue }

                            let cmd = Int((word >> 24) & 0xFF)
                            let sig = Int(Int8(truncatingIfNeeded: byte0))
                            let note = byte1
                            let velocity = byte2

                            Task { @MainActor [weak self] in
                                self?.driver.getSignal(cmd: cmd, sig: sig, note: note, velocity: velocity)
                            }
                        }
                    }
                }
            }

            packet = MIDIEventPacketNext(&packet).pointee
        }
    }

    // MARK: - MIDI Output

    func sendMIDIMessage(cmd: UInt8, sig: UInt8, note: UInt8, velocity: UInt8) {
        guard connectedDestination != 0 else { return }

        sendQueue.async { [weak self] in
            guard let self, self.connectedDestination != 0 else { return }

            var packetList = MIDIPacketList()
            var packet = MIDIPacketListInit(&packetList)
            let data: [UInt8] = [sig, note, velocity]
            packet = MIDIPacketListAdd(&packetList, Int(MemoryLayout<MIDIPacketList>.size), packet, 0, data.count, data)

            MIDISend(self.outputPort, self.connectedDestination, &packetList)
        }
    }

    func sendSysEx(messages: [[UInt8]], cableNumber: Int = 0) {
        guard connectedDestination != 0 else { return }

        sendQueue.async { [weak self] in
            guard let self, self.connectedDestination != 0 else { return }

            // For multi-port devices, select the destination matching the cable number
            let destination: MIDIEndpointRef
            if cableNumber > 0, self.connectedDeviceEntity != 0 {
                let destCount = MIDIEntityGetNumberOfDestinations(self.connectedDeviceEntity)
                if cableNumber < destCount {
                    destination = MIDIEntityGetDestination(self.connectedDeviceEntity, cableNumber)
                } else {
                    destination = self.connectedDestination
                }
            } else {
                destination = self.connectedDestination
            }

            for (index, message) in messages.enumerated() {
                var request = MIDISysexSendRequest(
                    destination: destination,
                    data: UnsafePointer(message),
                    bytesToSend: UInt32(message.count),
                    complete: false,
                    reserved: (0, 0, 0),
                    completionProc: { _ in },
                    completionRefCon: nil
                )
                MIDISendSysex(&request)

                // Delay between SysEx messages for device mode transitions
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

