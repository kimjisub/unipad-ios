import Foundation
import Testing
@testable import unipad

/// Opening a pack reads its files (folder listing, info, keySound, keyLed, autoPlay); that has to
/// happen off the main actor so the screen keeps drawing while a large pack or a slow disk is read.
/// The hold below stands in for a slow disk; it is a test condition, not a measurement of a user.
@MainActor
struct PlayViewModelLoadTests {
    /// A pack whose reads note the thread they run on and can be held until the test lets go.
    final class ProbePack: UniPack {
        private let lock = NSLock()
        private var mainSteps: [String] = []
        private var started = false
        private var holdTimedOut = false
        private let hold: DispatchSemaphore?
        private let holdTimeout: TimeInterval
        private let failsInfo: Bool

        override var id: String { "probe-pack" }

        init(holdInfo: Bool = false, holdTimeout: TimeInterval = 2, failsInfo: Bool = false) {
            self.hold = holdInfo ? DispatchSemaphore(value: 0) : nil
            self.holdTimeout = holdTimeout
            self.failsInfo = failsInfo
            super.init()
        }

        var stepsOnMain: [String] { lock.withLock { mainSteps } }
        var readStarted: Bool { lock.withLock { started } }
        var holdExpired: Bool { lock.withLock { holdTimedOut } }

        func release() { hold?.signal() }

        private func note(_ step: String) {
            lock.withLock {
                if Thread.isMainThread { mainSteps.append(step) }
            }
        }

        override func lastModified() -> TimeInterval { 0 }
        override func checkFile() { note("checkFile") }
        override func delete() {}
        override func getPathString() -> String { "/probe" }
        override func getByteSize() -> Int64 { 0 }

        override func loadInfo() -> UniPack {
            note("loadInfo")
            lock.withLock { started = true }
            if let hold, hold.wait(timeout: .now() + holdTimeout) == .timedOut {
                lock.withLock { holdTimedOut = true }
            }
            if failsInfo {
                addErr("info doesn't exist")
                criticalError = true
                return self
            }
            title = "Probe"
            buttonX = 8
            buttonY = 8
            chain = 1
            return self
        }

        override func loadDetailWithProgress(onPhase: (String, Int, Int) -> Void) -> UniPack {
            note("loadDetail")
            onPhase("keySound", 0, 3)
            onPhase("keyLed", 1, 3)
            onPhase("autoPlay", 2, 3)
            soundTable = [Array(repeating: Array(repeating: nil, count: 8), count: 8)]
            detailLoaded = true
            return self
        }
    }

    private func makeViewModel(_ pack: UniPack) -> PlayViewModel {
        let vm = PlayViewModel()
        vm.makePack = { _ in pack }
        return vm
    }

    @Test func packFilesAreReadOffTheMainThread() async throws {
        let pack = ProbePack()
        let vm = makeViewModel(pack)

        try await vm.loadUnipack(path: "/probe")
        vm.cleanup()

        #expect(pack.stepsOnMain.isEmpty, "read on the main thread: \(pack.stepsOnMain)")
    }

    @Test func mainActorKeepsRunningWhileTheReadIsHeld() async throws {
        let pack = ProbePack(holdInfo: true)
        let vm = makeViewModel(pack)
        let loading = Task { try await vm.loadUnipack(path: "/probe") }
        while !pack.readStarted { try await Task.sleep(nanoseconds: 5_000_000) }

        // Queued once the read is under way, so it runs only if the main actor is free.
        Task { @MainActor in pack.release() }
        try await loading.value
        vm.cleanup()

        #expect(!pack.holdExpired, "the held read kept the main actor from running other work")
    }

    @Test func leavingWhileTheReadIsRunningStartsNothing() async throws {
        let pack = ProbePack(holdInfo: true)
        let vm = makeViewModel(pack)
        let loading = Task { try await vm.loadUnipack(path: "/probe") }
        while !pack.readStarted { try await Task.sleep(nanoseconds: 5_000_000) }

        loading.cancel()
        vm.cleanup()
        pack.release()
        try await loading.value

        #expect(vm.unipack == nil)
        #expect(vm.soundEngine == nil)
        #expect(vm.unipackLoadError == nil)
    }

    @Test func aPackThatCannotBeReadReportsTheErrorAndStops() async throws {
        let pack = ProbePack(failsInfo: true)
        let vm = makeViewModel(pack)

        try await vm.loadUnipack(path: "/probe")

        #expect(vm.unipackLoadError == "info doesn't exist")
        #expect(vm.unipack == nil)
        #expect(!vm.unipackLoading)
    }

    @Test func aFolderPackLoadsWithItsDataIntact() async throws {
        let folder = FileManager.default.temporaryDirectory
            .appending(path: "PlayViewModelLoadTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder.appending(path: "sounds"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try "title=Folder Pack\nproducerName=Tester\nbuttonX=8\nbuttonY=8\nchain=1\n"
            .write(to: folder.appending(path: "info"), atomically: true, encoding: .utf8)
        try "1 1 1 a.wav\n".write(to: folder.appending(path: "keySound"), atomically: true, encoding: .utf8)
        try Data().write(to: folder.appending(path: "sounds/a.wav"))
        let vm = PlayViewModel()

        try await vm.loadUnipack(path: folder.path)
        vm.cleanup()

        let pack = try #require(vm.unipack)
        #expect(pack.title == "Folder Pack")
        #expect(pack.detailLoaded)
        #expect(pack.soundCount == 1)
        #expect(vm.loadingPhaseIndex == vm.loadingPhaseTotal - 1)
        #expect(!vm.unipackLoading)
        #expect(vm.unipackLoadError == nil)
    }
}
