import AVFoundation
import XCTest
@testable import unipad

/// Several fingers on the play screen's pad view, wired to the production screen model and
/// SoundEngine as PlayView wires them. Fingers enter through the view's finger handlers, which
/// `touchesBegan/Moved/Ended/Cancelled` call once per `UITouch`; several fingers inside one
/// `input` block arrive together, as one touch event delivers them. Every pad loops its silent
/// sample forever, so a sound still playing after its finger lifted is a repeat that never stops.
/// Synthetic input only: no physical finger, and no claim that the samples were heard.
/// Chain changes under a held finger (case H) are covered by ChainReleaseTests.
@MainActor
final class MultiTouchPlayTests: XCTestCase {
    nonisolated struct Pad: Hashable, Comparable, CustomStringConvertible {
        let row: Int
        let col: Int
        init(_ row: Int, _ col: Int) { self.row = row; self.col = col }
        static func < (a: Pad, b: Pad) -> Bool { (a.row, a.col) < (b.row, b.col) }
        var description: String { "(\(row + 1),\(col + 1))" }
    }

    nonisolated private final class StartsPack: UniPackFolder {
        private let lock = NSLock()
        private var starts: [Pad] = []
        var started: [Pad] { lock.withLock { starts } }
        override func soundPush(c: Int, x: Int, y: Int) {
            if super.soundGet(c: c, x: x, y: y) != nil { lock.withLock { starts.append(Pad(x, y)) } }
            super.soundPush(c: c, x: x, y: y)
        }
    }

    /// The pad view and what the screen model made of its input.
    @MainActor
    private final class PlayScreen {
        static let cell: CGFloat = 40
        let vm: PlayViewModel
        let engine: SoundEngine
        private let pack: StartsPack
        let pads = MultiTouchUIView()
        private var padOfPlay: [Int: Pad] = [:]

        init(vm: PlayViewModel, engine: SoundEngine, pack: StartsPack) {
            self.vm = vm
            self.engine = engine
            self.pack = pack
            pads.frame = CGRect(x: 0, y: 0, width: Self.cell * 8, height: Self.cell * 8)
            pads.isMultipleTouchEnabled = true
            pads.cellWidth = Self.cell
            pads.cellHeight = Self.cell
            pads.rows = 8
            pads.columns = 8
            pads.onPadTouch = vm.screenPadTouch
        }

        static func center(_ pad: Pad) -> CGPoint {
            CGPoint(x: (CGFloat(pad.col) + 0.5) * cell, y: (CGFloat(pad.row) + 0.5) * cell)
        }

        /// Runs one touch event and returns the pads whose sound it started, in start order.
        @discardableResult
        func input(_ touches: () -> Void, file: StaticString = #filePath, line: UInt = #line) -> [Pad] {
            let before = engine.activePlayIDs
            let startsBefore = pack.started.count
            touches()
            let started = Array(pack.started[startsBefore...])
            let newPlays = engine.activePlayIDs.subtracting(before).sorted()
            XCTAssertEqual(newPlays.count, started.count, "a sound started by this touch is not playing", file: file, line: line)
            for (play, pad) in zip(newPlays, started) { padOfPlay[play] = pad }
            return started
        }

        var sounding: [Pad] { engine.activePlayIDs.compactMap { padOfPlay[$0] }.sorted() }

        var lit: [Pad] {
            vm.padItems.indices.flatMap { row in
                vm.padItems[row].indices.compactMap { col in
                    vm.padItems[row][col]?.channel == .pressed ? Pad(row, col) : nil
                }
            }
        }
    }

    private struct WaitFailed: LocalizedError { let errorDescription: String? }

    /// An 8x8 pack in which every pad loops one 10 ms silent sample forever.
    private func loopingPack() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MultiTouch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("sounds"), withIntermediateDirectories: true)
        try "title=Multi Touch\nproducerName=Test\nbuttonX=8\nbuttonY=8\nchain=1\n".write(to: root.appendingPathComponent("info"), atomically: true, encoding: .utf8)
        let keySound = (1...8).flatMap { x in (1...8).map { y in "1 \(x) \(y) a.wav 0\n" } }.joined()
        try keySound.write(to: root.appendingPathComponent("keySound"), atomically: true, encoding: .utf8)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let file = try AVAudioFile(forWriting: root.appendingPathComponent("sounds/a.wav"), settings: format.settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        try file.write(from: buffer)
        return root
    }

    /// Objects are created and released inside the async test body: releasing app classes from a
    /// synchronous test crashes the XCTest host on iOS 26.0–26.3 simulators (not the app).
    private func withScreen(_ body: (PlayScreen) async throws -> Void) async throws {
        let root = try loopingPack()
        defer { try? FileManager.default.removeItem(at: root) }
        let pack = StartsPack(rootFolder: root)
        let vm = PlayViewModel()
        vm.makePack = { _ in pack }
        try await vm.loadUnipack(path: root.path)
        defer { vm.cleanup() }
        let deadline = Date().addingTimeInterval(120)
        while !vm.startReady {
            if let error = vm.unipackLoadError { throw WaitFailed(errorDescription: "sound loading failed: \(error)") }
            if vm.quitRequested { throw WaitFailed(errorDescription: "the screen asked to quit: \(vm.toastMessage ?? "")") }
            guard Date() < deadline else { throw WaitFailed(errorDescription: "sound loading reported nothing within 120 s") }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(vm.scbFeedbackLight.checked, "a pack without LEDs lights pressed pads")
        let screen = PlayScreen(vm: vm, engine: try XCTUnwrap(vm.soundEngine), pack: pack)
        try await body(screen)
    }

    // A
    func testTwoPadsPressedTogetherBothSoundAndLight() async throws {
        try await withScreen { screen in
            let a = Pad(0, 0), b = Pad(5, 6)
            let started = screen.input {
                screen.pads.fingerDown(1, at: PlayScreen.center(a))
                screen.pads.fingerDown(2, at: PlayScreen.center(b))
            }
            XCTAssertEqual(started, [a, b])
            XCTAssertEqual(screen.sounding, [a, b])
            XCTAssertEqual(screen.lit, [a, b])
            screen.input {
                screen.pads.fingerUp(1)
                screen.pads.fingerUp(2)
            }
            XCTAssertEqual(screen.sounding, [])
            XCTAssertEqual(screen.lit, [])
        }
    }

    // B
    func testFourAndFivePadsPressedTogetherAllSoundAndLight() async throws {
        for count in [4, 5] {
            try await withScreen { screen in
                let held = [Pad(0, 0), Pad(1, 7), Pad(3, 3), Pad(6, 2), Pad(7, 7)].prefix(count)
                let started = screen.input {
                    for (finger, pad) in held.enumerated() { screen.pads.fingerDown(finger, at: PlayScreen.center(pad)) }
                }
                XCTAssertEqual(started.sorted(), held.sorted(), "\(count) fingers")
                XCTAssertEqual(screen.sounding, held.sorted(), "\(count) fingers")
                XCTAssertEqual(screen.lit, held.sorted(), "\(count) fingers")
                screen.input {
                    for finger in held.indices { screen.pads.fingerUp(finger) }
                }
                XCTAssertEqual(screen.sounding, [], "\(count) fingers")
                XCTAssertEqual(screen.lit, [], "\(count) fingers")
            }
        }
    }

    // C
    func testHeldPadStaysWhileAnotherPadIsTappedRepeatedly() async throws {
        try await withScreen { screen in
            let held = Pad(2, 2), tapped = Pad(2, 3)
            screen.input { screen.pads.fingerDown(1, at: PlayScreen.center(held)) }
            for round in 1...5 {
                let started = screen.input { screen.pads.fingerDown(2, at: PlayScreen.center(tapped)) }
                XCTAssertEqual(started, [tapped], "tap \(round)")
                XCTAssertEqual(screen.lit, [held, tapped], "tap \(round)")
                screen.input { screen.pads.fingerUp(2) }
                XCTAssertEqual(screen.sounding, [held], "tap \(round)")
                XCTAssertEqual(screen.lit, [held], "tap \(round)")
            }
            screen.input { screen.pads.fingerUp(1) }
            XCTAssertEqual(screen.sounding, [])
            XCTAssertEqual(screen.lit, [])
        }
    }

    // D
    func testDraggingOntoTheNextPadMovesSoundAndLight() async throws {
        try await withScreen { screen in
            let from = Pad(4, 4), to = Pad(4, 5)
            screen.input { screen.pads.fingerDown(1, at: PlayScreen.center(from)) }
            var nearEdge = PlayScreen.center(from)
            nearEdge.x += PlayScreen.cell * 0.4
            XCTAssertEqual(screen.input { screen.pads.fingerMoved(1, to: nearEdge) }, [], "moving inside the pad")
            XCTAssertEqual(screen.lit, [from])
            let started = screen.input { screen.pads.fingerMoved(1, to: PlayScreen.center(to)) }
            XCTAssertEqual(started, [to])
            XCTAssertEqual(screen.sounding, [to])
            XCTAssertEqual(screen.lit, [to])
            screen.input { screen.pads.fingerUp(1) }
            XCTAssertEqual(screen.sounding, [])
            XCTAssertEqual(screen.lit, [])
        }
    }

    // E
    func testTwoFingersDraggedTogetherEachFollowTheirOwnPad() async throws {
        try await withScreen { screen in
            let first = [Pad(1, 1), Pad(1, 2), Pad(1, 3)]
            let second = [Pad(6, 6), Pad(5, 6), Pad(4, 6)]
            screen.input {
                screen.pads.fingerDown(1, at: PlayScreen.center(first[0]))
                screen.pads.fingerDown(2, at: PlayScreen.center(second[0]))
            }
            for step in 1..<first.count {
                let started = screen.input {
                    screen.pads.fingerMoved(1, to: PlayScreen.center(first[step]))
                    screen.pads.fingerMoved(2, to: PlayScreen.center(second[step]))
                }
                XCTAssertEqual(started, [first[step], second[step]], "step \(step)")
                XCTAssertEqual(screen.sounding, [first[step], second[step]].sorted(), "step \(step)")
                XCTAssertEqual(screen.lit, [first[step], second[step]].sorted(), "step \(step)")
            }
            screen.input {
                screen.pads.fingerUp(1)
                screen.pads.fingerUp(2)
            }
            XCTAssertEqual(screen.sounding, [])
            XCTAssertEqual(screen.lit, [])
        }
    }

    // F
    func testLiftingOneOfTwoHeldPadsKeepsTheOther() async throws {
        try await withScreen { screen in
            let kept = Pad(0, 3), lifted = Pad(7, 3)
            screen.input {
                screen.pads.fingerDown(1, at: PlayScreen.center(kept))
                screen.pads.fingerDown(2, at: PlayScreen.center(lifted))
            }
            screen.input { screen.pads.fingerUp(2) }
            XCTAssertEqual(screen.sounding, [kept])
            XCTAssertEqual(screen.lit, [kept])
            screen.input { screen.pads.fingerUp(1) }
            XCTAssertEqual(screen.sounding, [])
            XCTAssertEqual(screen.lit, [])
        }
    }

    // G, in part: `touchesCancelled` releases each cancelled touch through `fingerUp`, so a cancel
    // reaches the screen model as all held fingers lifting in one event; pausing and resuming the
    // screen model must not then bring a repeat or a light back. Not covered: that the system
    // cancels held touches when an alert, Notification Center or the app switcher takes the
    // screen. `UITouch` cannot be made in a test, and XCUITest cannot hold a finger while the
    // app leaves the foreground.
    func testReleasedCancelledFingersStayStoppedAfterPauseAndResume() async throws {
        try await withScreen { screen in
            let held = [Pad(2, 5), Pad(6, 1)]
            screen.input {
                screen.pads.fingerDown(1, at: PlayScreen.center(held[0]))
                screen.pads.fingerDown(2, at: PlayScreen.center(held[1]))
            }
            XCTAssertEqual(screen.sounding, held.sorted())
            screen.input {
                screen.pads.fingerUp(1)
                screen.pads.fingerUp(2)
            }
            XCTAssertEqual(screen.sounding, [], "a repeat kept playing after its touch was cancelled")
            XCTAssertEqual(screen.lit, [], "a pad stayed lit after its touch was cancelled")
            screen.vm.onPause()
            screen.vm.onResume()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertEqual(screen.sounding, [], "returning to the app restarted a repeat")
            XCTAssertEqual(screen.lit, [], "returning to the app relit a pad")
            let started = screen.input { screen.pads.fingerDown(3, at: PlayScreen.center(held[0])) }
            XCTAssertEqual(started, [held[0]], "pads answer after returning")
            screen.input { screen.pads.fingerUp(3) }
        }
    }

    // D, off the grid: a finger dragged past the right or bottom edge releases its pad.
    func testDraggingOffTheGridReleasesThePad() async throws {
        try await withScreen { screen in
            let grid = PlayScreen.cell * 8
            let exits = [(Pad(3, 7), CGPoint(x: grid + 4, y: PlayScreen.center(Pad(3, 7)).y)),
                         (Pad(7, 2), CGPoint(x: PlayScreen.center(Pad(7, 2)).x, y: grid + 4))]
            for (pad, outside) in exits {
                screen.input { screen.pads.fingerDown(1, at: PlayScreen.center(pad)) }
                XCTAssertEqual(screen.lit, [pad])
                XCTAssertEqual(screen.input { screen.pads.fingerMoved(1, to: outside) }, [], "leaving \(pad)")
                XCTAssertEqual(screen.sounding, [], "leaving \(pad)")
                XCTAssertEqual(screen.lit, [], "leaving \(pad)")
                screen.input { screen.pads.fingerUp(1) }
            }
        }
    }

    // D, off the grid: a finger dragged less than one pad past the left or top edge releases its
    // pad too. The view keeps reporting a held finger's position outside its bounds, as UIKit does.
    func testDraggingSlightlyPastTheLeftOrTopEdgeReleasesThePad() async throws {
        try await withScreen { screen in
            let nudge = PlayScreen.cell * 0.3
            let exits = [(Pad(3, 0), CGPoint(x: -nudge, y: PlayScreen.center(Pad(3, 0)).y)),
                         (Pad(0, 5), CGPoint(x: PlayScreen.center(Pad(0, 5)).x, y: -nudge)),
                         (Pad(0, 0), CGPoint(x: -nudge, y: -nudge))]
            for (pad, outside) in exits {
                screen.input { screen.pads.fingerDown(1, at: PlayScreen.center(pad)) }
                XCTAssertEqual(screen.lit, [pad])
                XCTAssertEqual(screen.input { screen.pads.fingerMoved(1, to: outside) }, [], "leaving \(pad)")
                XCTAssertEqual(screen.sounding, [], "leaving \(pad)")
                XCTAssertEqual(screen.lit, [], "leaving \(pad)")
                screen.input { screen.pads.fingerUp(1) }
            }
        }
    }

    // The screen turns 180° or resizes under held fingers: each finger now rests over another pad
    // without having moved. The pads they held are released, and those fingers start nothing until
    // lifted. Noticing the turn itself needs a rotating window scene, which a unit test does not have.
    func testScreenTurningUnderHeldFingersReleasesThemAndStartsNothing() async throws {
        try await withScreen { screen in
            let held = Pad(2, 2), mirrored = Pad(5, 5), beside = CGPoint(x: PlayScreen.cell * 8 + 4, y: 10)
            screen.input {
                screen.pads.fingerDown(1, at: PlayScreen.center(held))
                screen.pads.fingerDown(2, at: beside)
            }
            XCTAssertEqual(screen.lit, [held])
            screen.input { screen.pads.screenChanged() }
            XCTAssertEqual(screen.sounding, [], "a held pad kept playing after the screen turned")
            XCTAssertEqual(screen.lit, [], "a held pad stayed lit after the screen turned")
            let moved = screen.input {
                screen.pads.fingerMoved(1, to: PlayScreen.center(mirrored))
                screen.pads.fingerMoved(2, to: PlayScreen.center(Pad(0, 7)))
            }
            XCTAssertEqual(moved, [], "a finger from before the turn started the pad now under it")
            XCTAssertEqual(screen.lit, [])
            let pressed = Pad(4, 6)
            XCTAssertEqual(screen.input { screen.pads.fingerDown(3, at: PlayScreen.center(pressed)) }, [pressed],
                           "a new finger plays while older ones rest")
            screen.input {
                screen.pads.fingerUp(1)
                screen.pads.fingerUp(2)
            }
            XCTAssertEqual(screen.sounding, [pressed], "lifting a finger from before the turn stopped another pad")
            screen.input { screen.pads.fingerUp(3) }
            XCTAssertEqual(screen.input { screen.pads.fingerDown(1, at: PlayScreen.center(mirrored)) }, [mirrored],
                           "a finger pressed again after the turn plays")
            screen.input { screen.pads.fingerUp(1) }
            XCTAssertEqual(screen.sounding, [])
            XCTAssertEqual(screen.lit, [])
        }
    }

    // An iPad window that only narrows re-centres the pad view without resizing it. A finger resting
    // on a pad then reports a previous position that is not where the view last saw it.
    func testPadsMovingUnderAStillFingerReleaseItAndStartNothing() async throws {
        try await withScreen { screen in
            let held = Pad(2, 2), other = Pad(3, 3)
            screen.input {
                screen.pads.fingerDown(1, at: PlayScreen.center(held))
                screen.pads.fingerDown(2, at: PlayScreen.center(other))
            }
            let still = screen.input {
                screen.pads.fingerMoved(1, to: PlayScreen.center(held), from: PlayScreen.center(held))
            }
            XCTAssertEqual(still, [])
            XCTAssertEqual(screen.lit, [held, other], "a finger that stayed put was taken as the pads moving")
            let dragged = Pad(2, 3)
            XCTAssertEqual(screen.input {
                screen.pads.fingerMoved(1, to: PlayScreen.center(dragged), from: PlayScreen.center(held))
            }, [dragged], "dragging a finger across the pads stopped playing")

            let shift = PlayScreen.cell * 1.5
            let shiftedFrom = CGPoint(x: PlayScreen.center(dragged).x - shift, y: PlayScreen.center(dragged).y)
            let moved = screen.input {
                screen.pads.fingerMoved(1, to: CGPoint(x: shiftedFrom.x + 1, y: shiftedFrom.y), from: shiftedFrom)
            }
            XCTAssertEqual(moved, [], "a finger resting while the pads moved started the pad now under it")
            XCTAssertEqual(screen.sounding, [], "a held pad kept playing after the pads moved")
            XCTAssertEqual(screen.lit, [])
            XCTAssertEqual(screen.input { screen.pads.fingerMoved(2, to: PlayScreen.center(Pad(0, 0))) }, [],
                           "another finger from before the pads moved started a pad")

            screen.input {
                screen.pads.fingerUp(1)
                screen.pads.fingerUp(2)
            }
            let pressed = Pad(4, 6)
            XCTAssertEqual(screen.input { screen.pads.fingerDown(1, at: PlayScreen.center(pressed)) }, [pressed],
                           "a finger pressed after the pads moved plays")
            screen.input { screen.pads.fingerUp(1) }
            XCTAssertEqual(screen.sounding, [])
            XCTAssertEqual(screen.lit, [])
        }
    }

    // A finger resting since the screen changed never stays perfectly still, and its first move
    // reports a previous position from before the change. That is not the pads moving again: a
    // pad pressed since then keeps playing.
    func testRestingFingerTremblingKeepsANewerPadPlaying() async throws {
        try await withScreen { screen in
            let held = Pad(2, 2), mirrored = Pad(5, 5), pressed = Pad(4, 6)
            screen.input { screen.pads.fingerDown(1, at: PlayScreen.center(held)) }
            screen.input { screen.pads.screenChanged() }
            XCTAssertEqual(screen.input { screen.pads.fingerDown(2, at: PlayScreen.center(pressed)) }, [pressed])
            let rest = PlayScreen.center(mirrored)
            let trembled = screen.input {
                screen.pads.fingerMoved(1, to: rest, from: rest)
                screen.pads.fingerMoved(1, to: CGPoint(x: rest.x + 0.5, y: rest.y), from: rest)
                screen.pads.fingerMoved(1, to: rest, from: CGPoint(x: rest.x + 0.5, y: rest.y))
            }
            XCTAssertEqual(trembled, [], "a resting finger started the pad under it")
            XCTAssertEqual(screen.sounding, [pressed], "a resting finger's tremble stopped a newer pad")
            XCTAssertEqual(screen.lit, [pressed], "a resting finger's tremble darkened a newer pad")
            let dragged = Pad(4, 7)
            XCTAssertEqual(screen.input {
                screen.pads.fingerMoved(2, to: PlayScreen.center(dragged), from: PlayScreen.center(pressed))
            }, [dragged], "the newer finger no longer drags across the pads")
            screen.input {
                screen.pads.fingerUp(1)
                screen.pads.fingerUp(2)
            }
            XCTAssertEqual(screen.sounding, [])
            XCTAssertEqual(screen.lit, [])
        }
    }

    // I: the pad view also receives a finger that rests beside the pads.
    func testFingerOffThePadsIsSilentAndDoesNotDisturbPlaying() async throws {
        try await withScreen { screen in
            let grid = PlayScreen.cell * 8
            let edges = [
                CGPoint(x: grid + 4, y: grid / 2),
                CGPoint(x: grid / 2, y: grid + 4),
                CGPoint(x: grid + 4, y: grid + 4),
                CGPoint(x: -4, y: grid / 2),
                CGPoint(x: grid / 2, y: -4)
            ]
            for (index, edge) in edges.enumerated() {
                let finger = 100 + index
                XCTAssertEqual(screen.input { screen.pads.fingerDown(finger, at: edge) }, [], "edge \(edge)")
                XCTAssertEqual(screen.lit, [], "edge \(edge)")
                let pad = Pad(index, index)
                XCTAssertEqual(screen.input { screen.pads.fingerDown(1, at: PlayScreen.center(pad)) }, [pad], "edge \(edge)")
                XCTAssertEqual(screen.lit, [pad], "edge \(edge)")
                XCTAssertEqual(screen.input { screen.pads.fingerMoved(finger, to: CGPoint(x: edge.x + 2, y: edge.y + 2)) }, [], "edge \(edge)")
                screen.input { screen.pads.fingerUp(finger) }
                XCTAssertEqual(screen.sounding, [pad], "lifting the edge finger stopped another pad")
                XCTAssertEqual(screen.lit, [pad], "lifting the edge finger cleared another pad")
                screen.input { screen.pads.fingerUp(1) }
                XCTAssertEqual(screen.sounding, [], "edge \(edge)")
                XCTAssertEqual(screen.lit, [], "edge \(edge)")
            }
        }
    }
}
