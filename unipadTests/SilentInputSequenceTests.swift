#if canImport(UIKit)
import AVFoundation
import Testing
@testable import unipad

@MainActor
struct SilentInputSequenceTests {
    @Test(arguments: [false, true])
    func silentInputStillAdvancesTheSequenceAndChain(_ interrupted: Bool) async throws {
        let file = try SoundEngineTestSupport.writeSilentSound()
        defer { try? FileManager.default.removeItem(at: file) }
        let pack = OnePadPack(chains: [[Sound(file: file, loop: 0, wormhole: 1), Sound(file: file, loop: 0)], []])
        let chain = ChainObserver()
        let listener = TestSoundLoadListener()
        let engine = SoundEngine(unipack: pack, chain: chain, loadingListener: listener)
        defer { engine.destroy() }
        engine.wormholeDelay = { await Task.yield() }
        if interrupted {
            try await PlayUsageScenario.waitWhile(timeout: 20) { !listener.finished }
            try #require(listener.finished && listener.failure == nil)
            engine.handleInterruption(Notification(name: AVAudioSession.interruptionNotification,
                userInfo: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue]))
        }
        engine.soundOn(x: 0, y: 0)
        #expect(engine.playsStarted == 0)
        #expect(pack.soundGet(c: 0, x: 0, y: 0)?.num == 1)
        try await PlayUsageScenario.waitWhile(timeout: 1) { chain.value == 0 }
        #expect(chain.value == 1)
        engine.destroy()
        engine.soundOn(x: 0, y: 0)
        #expect(pack.soundGet(c: 0, x: 0, y: 0)?.num == 1, "a destroyed engine must consume no input")
    }
}
#endif
