import Foundation
import os
import Testing
@testable import unipad

/// The option panel's auto mapping stops the auto play runner, rewrites the pack's autoPlay and
/// then has to finish: the progress row goes away and auto play is available again.
extension PlayUsageRecordTests {
    @MainActor
    struct AutoMappingTests {
        @Test func autoMappingFinishesAndRestoresAutoPlay() async throws {
            try await PlayUsageScenario.run { s in
                try await s.loadReady()
                try #require(s.vm.autoPlayRunner != nil, "the fixture pack has no auto play")

                s.vm.autoMapping()
                #expect(s.vm.autoMappingActive)

                try await s.waitWhile { s.vm.autoMappingActive }
                #expect(!s.vm.autoMappingActive, "auto mapping never finished")
                #expect(s.vm.autoPlayRunner != nil, "auto play was not restored after auto mapping")
            }
        }

        @Test func failedAutoMappingStillRestoresAutoPlay() async throws {
            try await PlayUsageScenario.run { s in
                try await s.loadReady()
                // Without the file the mapper has nothing to back up and fails before writing.
                try s.removePackFile("autoPlay")

                s.vm.autoMapping()
                try await s.waitWhile { s.vm.autoMappingActive }
                #expect(!s.vm.autoMappingActive, "auto mapping never finished")
                #expect(s.vm.toastMessage == String(localized: "remapFail"))
                #expect(s.vm.autoPlayRunner != nil, "auto play was not restored after a failed auto mapping")
            }
        }

        @Test func autoMappingDuringAutoPlayResetsPlayState() async throws {
            try await PlayUsageScenario.run { s in
                try await s.loadReady()
                s.vm.switchPlayMode(.autoPlay)
                try #require(s.vm.isAutoPlayPlaying)

                s.vm.autoMapping()
                #expect(s.vm.playMode == .none)
                #expect(!s.vm.isAutoPlayPlaying, "auto play still shows as playing after its runner was stopped")
                try await s.waitWhile { s.vm.autoMappingActive }
                #expect(!s.vm.autoMappingActive, "auto mapping never finished")
            }
        }

        @Test func autoMappingWritesTheSoundLengths() async throws {
            let pack = try MapperPack()
            defer { pack.remove() }
            let listener = RecordingListener()
            let wroteOnMain = OSAllocatedUnfairLock<Bool?>(initialState: nil)
            let replacer = AutoPlayFileReplacer(write: { content, url in
                wroteOnMain.withLock { $0 = Thread.isMainThread }
                try content.write(to: url, atomically: true, encoding: .utf8)
            })

            await UniPackAutoMapper(unipack: pack.unipack, listener: listener, replacer: replacer).start().value

            #expect(listener.events == ["start", "size 3", "progress 1", "progress 2", "progress 3", "done"])
            #expect(try pack.autoPlay() == "d 1000\nt 1 1\nd 60\nt 1 2\nd 60\nt 1 3\n")
            #expect(pack.backups().count == 1)
            #expect(wroteOnMain.withLock { $0 } == false, "the mapping ran on the main thread")
        }

        /// A header claiming 0 Hz gave an infinite length that trapped; 20 Hz a wait thousands of
        /// times too long. Such a sound gets no length, like one that cannot be opened, and the pack's
        /// own wait stays.
        @Test(arguments: [UInt32(0), 1, 20])
        func aSoundWithAnImplausibleSampleRateGetsNoLength(sampleRate: UInt32) async throws {
            let broken = try SoundEngineTestSupport.writeWav(sampleRate: sampleRate, frames: 4_410)
            defer { try? FileManager.default.removeItem(at: broken) }
            let pack = try MapperPack(keySound: "1 1 1 a.wav\n1 1 2 broken.wav\n1 1 3 a.wav\n", sounds: ["broken.wav": broken])
            defer { pack.remove() }
            let listener = RecordingListener()

            await UniPackAutoMapper(unipack: pack.unipack, listener: listener).start().value

            #expect(listener.events.last == "done")
            #expect(try pack.autoPlay() == "d 1000\nt 1 1\nd 60\nt 1 2\nd 400\nt 1 3\n")
        }

        /// `AVAudioFile` cannot open Ogg Vorbis, which playback decodes itself: the 0.5 s tone
        /// sets the wait after it like a WAV does.
        @Test func anOggVorbisSoundGetsItsLength() async throws {
            let tone = try #require(Bundle(for: OnePadPack.self).url(forResource: "vorbis-tone", withExtension: "ogg"))
            let pack = try MapperPack(keySound: "1 1 1 a.wav\n1 1 2 tone.ogg\n1 1 3 a.wav\n", sounds: ["tone.ogg": tone])
            defer { pack.remove() }
            let listener = RecordingListener()

            await UniPackAutoMapper(unipack: pack.unipack, listener: listener).start().value

            #expect(listener.events.last == "done")
            #expect(try pack.autoPlay() == "d 1000\nt 1 1\nd 60\nt 1 2\nd 500\nt 1 3\n")
        }

        /// Opus trimming gives the same half-second wait that playback actually renders.
        @Test func anOggOpusSoundGetsItsLength() async throws {
            let tone = try #require(Bundle(for: OnePadPack.self).url(forResource: "opus-tone", withExtension: "ogg"))
            let pack = try MapperPack(keySound: "1 1 1 a.wav\n1 1 2 tone.ogg\n1 1 3 a.wav\n", sounds: ["tone.ogg": tone])
            defer { pack.remove() }
            let listener = RecordingListener()

            await UniPackAutoMapper(unipack: pack.unipack, listener: listener).start().value

            #expect(listener.events.last == "done")
            #expect(try pack.autoPlay() == "d 1000\nt 1 1\nd 60\nt 1 2\nd 500\nt 1 3\n")
        }

        /// Playback refuses these Ogg Vorbis sounds, so the pack's wait stays: one declaring 601 s, and
        /// one whose declared length at 192 kHz exceeds the buffer budget.
        @Test(arguments: ["vorbis-overlong", "vorbis-over-budget"])
        func anOggVorbisSoundPlaybackRefusesGetsNoLength(fixture: String) async throws {
            let refused = try #require(Bundle(for: OnePadPack.self).url(forResource: fixture, withExtension: "ogg"))
            let pack = try MapperPack(keySound: "1 1 1 a.wav\n1 1 2 refused.ogg\n1 1 3 a.wav\n", sounds: ["refused.ogg": refused])
            defer { pack.remove() }
            let listener = RecordingListener()

            await UniPackAutoMapper(unipack: pack.unipack, listener: listener).start().value

            #expect(listener.events.last == "done")
            #expect(try pack.autoPlay() == "d 1000\nt 1 1\nd 60\nt 1 2\nd 400\nt 1 3\n")
        }

        @Test func aSoundOverTenMinutesGetsNoLength() async throws {
            let long = try SoundEngineTestSupport.writeWav(sampleRate: 8_000, frames: 8_000 * 601)
            defer { try? FileManager.default.removeItem(at: long) }
            let pack = try MapperPack(keySound: "1 1 1 a.wav\n1 1 2 long.wav\n1 1 3 a.wav\n", sounds: ["long.wav": long])
            defer { pack.remove() }
            let listener = RecordingListener()

            await UniPackAutoMapper(unipack: pack.unipack, listener: listener).start().value

            #expect(listener.events.last == "done")
            #expect(try pack.autoPlay() == "d 1000\nt 1 1\nd 60\nt 1 2\nd 400\nt 1 3\n")
        }

        @Test func aSoundExceedingTheBufferBudgetGetsNoLength() async throws {
            let frames = UInt32(SoundFileLimits.maximumBufferBytes / (2 * 4)) + 1
            let oversized = try SoundEngineTestSupport.writeWav(sampleRate: 384_000, frames: frames, channels: 2)
            defer { try? FileManager.default.removeItem(at: oversized) }
            let pack = try MapperPack(keySound: "1 1 1 a.wav\n1 1 2 oversized.wav\n1 1 3 a.wav\n", sounds: ["oversized.wav": oversized])
            defer { pack.remove() }
            let listener = RecordingListener()

            await UniPackAutoMapper(unipack: pack.unipack, listener: listener).start().value

            #expect(listener.events.last == "done")
            #expect(try pack.autoPlay() == "d 1000\nt 1 1\nd 60\nt 1 2\nd 400\nt 1 3\n")
        }

        /// Waits that stay and add up past Int32.max are written as several lines the pack reader
        /// accepts, so the pack reloads with the whole wait.
        @Test func aWaitLongerThanTheReaderTakesIsSplit() async throws {
            let pack = try MapperPack(keySound: "1 1 3 a.wav\n", autoPlay: "on 1 1\nd 2147483647\nd 2147483647\nd 5\non 1 2\n")
            defer { pack.remove() }
            let totalDelay = { pack.unipack.autoPlayTable?.elements.reduce(0) { sum, element in
                if case .delay(let d) = element { sum + d } else { sum }
            } }
            let before = try #require(totalDelay())
            let errorsBefore = pack.unipack.errorDetail
            let listener = RecordingListener()

            await UniPackAutoMapper(unipack: pack.unipack, listener: listener).start().value

            #expect(listener.events.last == "done")
            #expect(try pack.autoPlay() == "d 1000\nt 1 1\nd 2147483647\nd 2147483647\nd 5\nt 1 2\n")
            #expect(pack.unipack.errorDetail == errorsBefore, "the pack reader refused the mapped autoPlay")
            #expect(totalDelay() == before + 1000)
        }

        /// The worked example of the mapping rule: pads pressed together stay together, the wait
        /// before the first press is one second and nothing waits after the last press.
        @Test func aWorkedExampleKeepsSimultaneousPresses() async throws {
            let sound = try SoundEngineTestSupport.writeWav(sampleRate: 10_000, frames: 4_000)
            defer { try? FileManager.default.removeItem(at: sound) }
            let pack = try MapperPack(
                keySound: "1 1 1 s.wav\n1 2 1 s.wav\n1 3 1 s.wav\n",
                autoPlay: "d 20\non 1 1\non 2 1\nd 50\non 3 1\nd 99\n",
                sounds: ["s.wav": sound])
            defer { pack.remove() }

            await UniPackAutoMapper(unipack: pack.unipack, listener: RecordingListener()).start().value

            #expect(try pack.autoPlay() == "d 1000\nt 1 1\nt 2 1\nd 400\nt 3 1\n")
        }

        /// The public reference's mapper inputs, with real files of those lengths instead of its
        /// explicit durations (`AutoMapProductTests` runs those). A nil length is an unreadable file.
        @Test(arguments: [
            MappedExample(autoPlay: "d 80\non 1 1\non 2 1\nd 20\nd 30\non 1 1\nd 999", a: 4_004, b: 4_005,
                          mapped: "d 1000\nt 1 1\nt 2 1\nd 401\nt 1 1\n"),
            MappedExample(autoPlay: "on 1 1\nd 30\nd 40\non 2 1\nd 999", a: nil, b: 9_000,
                          mapped: "d 1000\nt 1 1\nd 70\nt 2 1\n"),
            MappedExample(autoPlay: "on 1 1\nd 80\non 2 1", a: 4_004, b: 9_000,
                          mapped: "d 1000\nt 1 1\nd 400\nt 2 1\n"),
            MappedExample(autoPlay: "on 1 1\nd 80\non 2 1", a: 4_005, b: 9_000,
                          mapped: "d 1000\nt 1 1\nd 401\nt 2 1\n"),
            MappedExample(autoPlay: "on 1 1\nd 50\nc 2\non 1 1\nd 50\non 1 1", a: 3_000, b: 5_000,
                          mapped: "d 1000\nt 1 1\nd 300\nc 2\nt 1 1\nd 500\nt 1 1\n"),
        ])
        func sharedExampleMapsAsTheReferenceSays(example: MappedExample) async throws {
            let unreadable = FileManager.default.temporaryDirectory.appending(path: "AutoMapping-\(UUID().uuidString).wav")
            try Data("not a sound".utf8).write(to: unreadable)
            defer { try? FileManager.default.removeItem(at: unreadable) }
            var sounds: [String: URL] = [:]
            for (name, frames) in [("a.wav", example.a), ("b.wav", example.b)] {
                sounds[name] = try frames.map { try SoundEngineTestSupport.writeWav(sampleRate: 10_000, frames: $0) } ?? unreadable
            }
            defer { for url in sounds.values where url != unreadable { try? FileManager.default.removeItem(at: url) } }
            let pack = try MapperPack(
                keySound: "1 1 1 a.wav\n1 2 1 b.wav\n2 1 1 b.wav", autoPlay: example.autoPlay, sounds: sounds,
                grid: PlayUsageScenario.PackGrid(chain: 2))
            defer { pack.remove() }

            await UniPackAutoMapper(unipack: pack.unipack, listener: RecordingListener()).start().value

            #expect(try pack.autoPlay() == example.mapped)
        }

        /// A press that moves to another chain through its sound is followed by that move when the
        /// pack is read again, so writing it as well would add a chain change the pack never had.
        @Test func aSoundsChainMoveIsNotWrittenTwice() async throws {
            let pack = try MapperPack(
                keySound: "1 1 1 a.wav 0 2\n2 1 1 a.wav\n", autoPlay: "on 1 1\nd 80\non 1 1\n",
                grid: PlayUsageScenario.PackGrid(chain: 2))
            defer { pack.remove() }

            await UniPackAutoMapper(unipack: pack.unipack, listener: RecordingListener()).start().value

            #expect(try pack.autoPlay() == "d 1000\nt 1 1\nd 60\nt 1 1\n")
        }

        /// Chain changes keep their place around the wait that replaces the ones before a press.
        @Test func aChainChangeKeepsItsPlaceAroundTheWait() async throws {
            let pack = try MapperPack(
                keySound: "1 1 1 a.wav\n2 1 1 a.wav\n", autoPlay: "c 2\nd 5\nc 1\non 1 1\nc 2\nd 80\nc 1\nd 80\non 1 1\nd 7\nc 2\nd 7\n",
                grid: PlayUsageScenario.PackGrid(chain: 2))
            defer { pack.remove() }

            await UniPackAutoMapper(unipack: pack.unipack, listener: RecordingListener()).start().value

            #expect(try pack.autoPlay() == "c 2\nc 1\nd 1000\nt 1 1\nc 2\nd 60\nc 1\nt 1 1\nc 2\n")
        }

        @Test func aWaitAfterAnUnknownLengthStaysOnItsSideOfAChainChange() async throws {
            let pack = try MapperPack(
                keySound: "2 1 1 a.wav\n", autoPlay: "on 1 1\nd 20\nd 10\nc 2\nd 40\non 1 1\n",
                grid: PlayUsageScenario.PackGrid(chain: 2))
            defer { pack.remove() }

            await UniPackAutoMapper(unipack: pack.unipack, listener: RecordingListener()).start().value

            #expect(try pack.autoPlay() == "d 1000\nt 1 1\nd 30\nc 2\nd 40\nt 1 1\n")
        }

        /// The backup is the file as it was, not a rendering of it: comments of a sort the reader
        /// skips and old text encodings come back as they were.
        @Test func theBackupKeepsTheOriginalBytes() async throws {
            let original = Data("on 1 1\r\ndelay 400\r\n# kept\r\non 1 2\r\n".utf8) + Data([0xC7, 0xD1, 0x0A])
            let pack = try MapperPack()
            defer { pack.remove() }
            try original.write(to: pack.autoPlayFile)
            pack.unipack.reloadAutoPlay()

            await UniPackAutoMapper(unipack: pack.unipack, listener: RecordingListener()).start().value

            #expect(pack.backups() == ["autoPlay_previous"])
            #expect(try Data(contentsOf: pack.backupFile) == original)
        }

        /// Mapping again makes what was playing the new backup, so backups do not pile up.
        @Test func mappingAgainKeepsOneBackupOfTheStateBefore() async throws {
            let pack = try MapperPack()
            defer { pack.remove() }
            await UniPackAutoMapper(unipack: pack.unipack, listener: RecordingListener()).start().value
            let firstResult = try pack.autoPlay()
            try "on 1 3\nd 5\non 1 2\n".write(to: pack.autoPlayFile, atomically: true, encoding: .utf8)
            pack.unipack.reloadAutoPlay()
            let secondOriginal = try pack.autoPlay()

            let listener = RecordingListener()
            await UniPackAutoMapper(unipack: pack.unipack, listener: listener).start().value

            #expect(listener.events.last == "done")
            #expect(pack.backups() == ["autoPlay_previous"])
            #expect(try String(contentsOf: pack.backupFile, encoding: .utf8) == secondOriginal)
            #expect(try pack.autoPlay() != firstResult)
        }

        @Test func aMappedAutoPlayIsWhatTheNextReadSees() async throws {
            let pack = try MapperPack()
            defer { pack.remove() }

            await UniPackAutoMapper(unipack: pack.unipack, listener: RecordingListener()).start().value

            let reopened = pack.reopened()
            #expect(reopened.autoPlayTable?.elements.first.map { "\($0)" } == "delay(delay: 1000)")
            #expect(try pack.autoPlay().hasPrefix("d 1000\nt 1 1\n"))
        }

        @Test func autoMappingCancelledBeforeWritingLeavesThePack() async throws {
            let pack = try MapperPack()
            defer { pack.remove() }
            let original = try pack.autoPlay()
            let listener = RecordingListener()
            let mapper = UniPackAutoMapper(unipack: pack.unipack, listener: listener)
            // The screen is left while the last press is being mapped: nothing is left to loop
            // over, so only the check before writing can stop it.
            listener.onLastProgress = { mapper.cancel() }

            await mapper.start().value

            #expect(listener.events == ["start", "size 3", "progress 1", "progress 2", "progress 3"])
            #expect(try pack.autoPlay() == original)
            #expect(pack.backups().isEmpty)
        }

        @Test func failedWriteLeavesThePackAsItWas() async throws {
            let pack = try MapperPack()
            defer { pack.remove() }
            let original = try pack.autoPlay()
            let listener = RecordingListener()
            let replacer = AutoPlayFileReplacer(write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })

            await UniPackAutoMapper(unipack: pack.unipack, listener: listener, replacer: replacer).start().value

            #expect(listener.events.last == "error \(CocoaError(.fileWriteOutOfSpace).localizedDescription)")
            #expect(try pack.autoPlay() == original)
            #expect(pack.backups().isEmpty, "the backup of a failed write was left in the pack")
            #expect(try pack.files() == ["autoPlay", "info", "keySound", "sounds"])
        }

        @Test func aPartlyWrittenResultNeverReachesThePack() async throws {
            let pack = try MapperPack()
            defer { pack.remove() }
            let original = try pack.autoPlay()
            let listener = RecordingListener()
            let replacer = AutoPlayFileReplacer(write: { content, url in
                try content.prefix(3).write(to: url, atomically: false, encoding: .utf8)
                throw CocoaError(.fileWriteOutOfSpace)
            })

            await UniPackAutoMapper(unipack: pack.unipack, listener: listener, replacer: replacer).start().value

            #expect(listener.events.last?.hasPrefix("error") == true)
            #expect(try pack.autoPlay() == original)
            #expect(try pack.files() == ["autoPlay", "info", "keySound", "sounds"])
        }

        /// The step that swaps the two files fails after the new version took the backup's place.
        /// `calls` are the swaps of a mapping when a backup already exists: into the backup's
        /// place, then with the autoPlay.
        @Test func aFailedSwapKeepsTheAutoPlayAndItsBackup() async throws {
            let pack = try MapperPack()
            defer { pack.remove() }
            await UniPackAutoMapper(unipack: pack.unipack, listener: RecordingListener()).start().value
            let current = try pack.autoPlay()
            let backup = try Data(contentsOf: pack.backupFile)
            let calls = OSAllocatedUnfairLock(initialState: 0)
            let replacer = AutoPlayFileReplacer(exchange: { first, second in
                let call = calls.withLock { $0 += 1; return $0 }
                if call == 2 { throw POSIXError(.EIO) }
                try AutoPlayFileReplacer.swapNames(first, second)
            })
            let listener = RecordingListener()

            await UniPackAutoMapper(unipack: pack.unipack, listener: listener, replacer: replacer).start().value

            #expect(listener.events.last?.hasPrefix("error") == true)
            #expect(try pack.autoPlay() == current)
            #expect(try Data(contentsOf: pack.backupFile) == backup)
            #expect(try pack.files() == ["autoPlay", "autoPlay_previous", "info", "keySound", "sounds"])
        }

        @Test func aFailedFirstSwapLeavesNoBackupBehind() async throws {
            let pack = try MapperPack()
            defer { pack.remove() }
            let original = try pack.autoPlay()
            let replacer = AutoPlayFileReplacer(exchange: { _, _ in throw POSIXError(.ENOTSUP) })

            await UniPackAutoMapper(unipack: pack.unipack, listener: RecordingListener(), replacer: replacer).start().value

            #expect(try pack.autoPlay() == original)
            #expect(try pack.files() == ["autoPlay", "info", "keySound", "sounds"])
        }

        /// What an app killed mid-save leaves behind is overwritten, not read.
        @Test func aResultLeftByAKilledAppIsNotUsed() async throws {
            let pack = try MapperPack()
            defer { pack.remove() }
            let staged = pack.folder.appending(path: ".autoPlay.next")
            try "half a resu".write(to: staged, atomically: true, encoding: .utf8)

            await UniPackAutoMapper(unipack: pack.unipack, listener: RecordingListener()).start().value

            #expect(try pack.autoPlay() == "d 1000\nt 1 1\nd 60\nt 1 2\nd 60\nt 1 3\n")
            #expect(try pack.files() == ["autoPlay", "autoPlay_previous", "info", "keySound", "sounds"])
        }

        @Test func restoringSwapsTheTwoVersionsAndCanBeRepeated() async throws {
            let pack = try MapperPack()
            defer { pack.remove() }
            let original = try pack.autoPlay()
            await UniPackAutoMapper(unipack: pack.unipack, listener: RecordingListener()).start().value
            let mapped = try pack.autoPlay()
            let replacer = AutoPlayFileReplacer()

            try replacer.restore(pack.autoPlayFile)
            #expect(try pack.autoPlay() == original)
            #expect(try String(contentsOf: pack.backupFile, encoding: .utf8) == mapped)
            #expect(pack.reopened().autoPlayTable?.elements.first.map { "\($0)" } == "on(x: 0, y: 0, currChain: 0, num: 0)")

            try replacer.restore(pack.autoPlayFile)
            #expect(try pack.autoPlay() == mapped)
            #expect(try String(contentsOf: pack.backupFile, encoding: .utf8) == original)
        }

        @Test func aFailedRestoreKeepsBothVersions() async throws {
            let pack = try MapperPack()
            defer { pack.remove() }
            await UniPackAutoMapper(unipack: pack.unipack, listener: RecordingListener()).start().value
            let mapped = try pack.autoPlay()
            let backup = try String(contentsOf: pack.backupFile, encoding: .utf8)
            let replacer = AutoPlayFileReplacer(exchange: { _, _ in throw POSIXError(.EIO) })

            #expect(throws: POSIXError.self) { try replacer.restore(pack.autoPlayFile) }

            #expect(try pack.autoPlay() == mapped)
            #expect(try String(contentsOf: pack.backupFile, encoding: .utf8) == backup)
        }

        @Test func aPackWithoutABackupHasNothingToRestore() async throws {
            let pack = try MapperPack()
            defer { pack.remove() }

            #expect(!AutoPlayFileReplacer.hasBackup(of: pack.autoPlayFile))
            #expect(throws: (any Error).self) { try AutoPlayFileReplacer().restore(pack.autoPlayFile) }
        }

        @Test func aFinishedMappingSaysSoAndOffersTheRestore() async throws {
            try await PlayUsageScenario.run { s in
                try await s.loadReady()
                #expect(!s.vm.canRestoreAutoPlay, "a pack never mapped has no backup")

                s.vm.autoMapping()
                #expect(!s.vm.canRestoreAutoPlay, "a restore must wait for the running mapping")
                try await s.waitWhile { s.vm.autoMappingActive }

                #expect(s.vm.toastMessage == String(localized: "autoMappingSaved"))
                #expect(s.vm.canRestoreAutoPlay)
                #expect(try String(contentsOf: s.packFile("autoPlay"), encoding: .utf8).hasPrefix("d 1000\n"))
            }
        }

        @Test func aMappingThatCouldNotSaveSaysSoAndPlaysTheOldAutoPlay() async throws {
            try await PlayUsageScenario.run { s in
                try await s.loadReady()
                let original = try String(contentsOf: s.packFile("autoPlay"), encoding: .utf8)
                let elements = s.vm.autoPlayProgressMax
                s.vm.autoPlayReplacer = AutoPlayFileReplacer(write: { _, _ in throw CocoaError(.fileWriteOutOfSpace) })

                s.vm.autoMapping()
                try await s.waitWhile { s.vm.autoMappingActive }

                #expect(s.vm.toastMessage == String(localized: "autoMappingFailed"))
                #expect(!s.vm.canRestoreAutoPlay)
                #expect(s.vm.autoPlayRunner != nil)
                #expect(s.vm.autoPlayProgressMax == elements)
                #expect(try String(contentsOf: s.packFile("autoPlay"), encoding: .utf8) == original)
            }
        }

        @Test func restoringStopsThePlaybackAndSwapsWhatIsPlayed() async throws {
            try await PlayUsageScenario.run { s in
                try await s.loadReady()
                s.vm.autoMapping()
                try await s.waitWhile { s.vm.autoMappingActive }
                let mappedElements = s.vm.autoPlayProgressMax
                s.vm.switchPlayMode(.autoPlay)
                try #require(s.vm.isAutoPlayPlaying)

                s.vm.restoreAutoPlay()

                #expect(s.vm.playMode == .none)
                #expect(!s.vm.isAutoPlayPlaying)
                #expect(s.vm.toastMessage == String(localized: "autoPlayRestored"))
                #expect(s.vm.autoPlayRunner != nil)
                #expect(s.vm.autoPlayProgressMax != mappedElements, "the runner still has the mapped autoPlay")
                #expect(s.vm.canRestoreAutoPlay, "the replaced version stays one restore away")
                #expect(try String(contentsOf: s.packFile("autoPlay"), encoding: .utf8) == PlayUsageScenario.defaultAutoPlay)
            }
        }

        @Test func aRestoreThatFailedSaysSoAndKeepsTheRestoreOnOffer() async throws {
            try await PlayUsageScenario.run { s in
                try await s.loadReady()
                s.vm.autoMapping()
                try await s.waitWhile { s.vm.autoMappingActive }
                let mapped = try String(contentsOf: s.packFile("autoPlay"), encoding: .utf8)
                s.vm.autoPlayReplacer = AutoPlayFileReplacer(exchange: { _, _ in throw POSIXError(.EIO) })

                s.vm.restoreAutoPlay()

                #expect(s.vm.toastMessage == String(localized: "autoPlayRestoreFailed"))
                #expect(s.vm.autoPlayRunner != nil)
                #expect(s.vm.canRestoreAutoPlay)
                #expect(try String(contentsOf: s.packFile("autoPlay"), encoding: .utf8) == mapped)
            }
        }

        /// The app's next launch finds the backup the last run left.
        @Test func aBackupFromAnEarlierRunIsOfferedOnLoad() async throws {
            try await PlayUsageScenario.run { s in
                try FileManager.default.copyItem(at: s.packFile("autoPlay"), to: s.packFile("autoPlay_previous"))
                try await s.loadReady()
                #expect(s.vm.canRestoreAutoPlay)
            }
        }
    }
}

struct MappedExample: Sendable {
    let autoPlay: String
    /// Frames of each sound at 10 kHz; nil is a file that cannot be read.
    let a: UInt32?
    let b: UInt32?
    let mapped: String
}

@MainActor
private final class RecordingListener: UniPackAutoMapperListener {
    private(set) var events: [String] = []
    private var size = 0
    var onLastProgress: () -> Void = {}

    func onStart() { events.append("start") }
    func onGetWorkSize(_ size: Int) { self.size = size; events.append("size \(size)") }
    func onProgress(_ progress: Int) {
        events.append("progress \(progress)")
        if progress == size { onLastProgress() }
    }
    func onDone() { events.append("done") }
    func onException(_ error: Error) { events.append("error \(error.localizedDescription)") }
}

/// The scenario's pack, loaded for the mapper alone.
@MainActor
private struct MapperPack {
    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("AutoMapping-\(UUID().uuidString)")
    let unipack: UniPackFolder

    init(
        keySound: String = PlayUsageScenario.defaultKeySound,
        autoPlay: String = PlayUsageScenario.defaultAutoPlay,
        sounds: [String: URL] = [:],
        grid: PlayUsageScenario.PackGrid = PlayUsageScenario.PackGrid()
    ) throws {
        try PlayUsageScenario.writePack(to: folder, keySound: keySound, autoPlay: autoPlay, grid: grid)
        for (name, source) in sounds {
            let target = folder.appending(path: "sounds/\(name)")
            try? FileManager.default.removeItem(at: target)
            try FileManager.default.copyItem(at: source, to: target)
        }
        unipack = UniPackFolder(rootFolder: folder)
        unipack.load()
        unipack.loadDetail()
    }

    var autoPlayFile: URL { folder.appending(path: "autoPlay") }
    var backupFile: URL { folder.appending(path: "autoPlay_previous") }
    func autoPlay() throws -> String { try String(contentsOf: autoPlayFile, encoding: .utf8) }
    /// The pack as a new launch reads it from disk.
    func reopened() -> UniPackFolder {
        let pack = UniPackFolder(rootFolder: folder)
        pack.load()
        pack.loadDetail()
        return pack
    }
    func files() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() }
    func backups() -> [String] { ((try? files()) ?? []).filter { $0.hasPrefix("autoPlay_") } }
    func remove() { try? FileManager.default.removeItem(at: folder) }
}
