import Foundation
@testable import unipad

/// A Launchpad LED as LedRunner addresses it: a pad, or a round LED (index `y`; 32 is the logo) when `x` is -1.
nonisolated struct LedTarget: Hashable, CustomStringConvertible {
    let x: Int
    let y: Int
    var description: String { x == -1 ? "round \(y)" : "pad \(x),\(y)" }
}

/// `code` for `target`, `ms` after autoplay starts.
nonisolated struct LedCommand {
    let ms: Double
    let target: LedTarget
    let code: Int
}

nonisolated struct IntendedLedTimeline {
    /// The LED commands the pack asks for, in the order it asks for them.
    let commands: [LedCommand]
    /// When autoplay presses each pad, in order.
    let pressTimes: [Int64]
    /// The last autoplay element's time.
    let autoPlayLengthMs: Int64
    /// Endless animations with no delay in a pass. LedRunner plays one pass per tick, which no timeline
    /// can state, so after the first pass this one plays nothing more of them but keeps the LEDs they
    /// lit theirs until a press or release ends them.
    let delaylessEndlessAnimations: Int

    var lastT0: Double { commands.last?.ms ?? 0 }

    /// The most commands intended within any 1000 ms.
    var peakPerSecond: Int {
        var peak = 0
        var from = 0
        for to in commands.indices {
            while commands[to].ms - commands[from].ms >= 1000 { from += 1 }
            peak = max(peak, to - from + 1)
        }
        return peak
    }

    var averagePerSecond: Double { lastT0 == 0 ? 0 : Double(commands.count) * 1000 / lastT0 }

    /// The sum of the autoplay's delays: when its last element plays.
    static func autoPlayLength(of pack: UniPack) -> Int64 {
        (pack.autoPlayTable?.elements ?? []).reduce(0) { sum, element in
            if case .delay(let delay) = element { return sum + Int64(delay) }
            return sum
        }
    }

    /// The LED commands a pack asks for when autoplay plays it with no lag: each autoplay element at the
    /// sum of the delays before it, and each keyLED event at its press time plus the delays before it in
    /// the animation. Animations follow LedRunner's rules: an LED belongs to the pad and chain whose
    /// animation lit it last, and only that owner's off turns it off; a press ends the running animation
    /// of the same pad and chain and turns off every LED it owns; a release ends only endless (loop 0)
    /// animations. LedRunner plays these on 4 ms ticks; here nothing waits for a tick, and events due in
    /// the same millisecond play animations in press order, then autoplay. A keyLED chain event (`c`)
    /// moves the chain later presses and the final release use, as the play screen applies it.
    ///
    /// `pack` must be loaded for this alone: its multi-mapping queues rotate as the play screen's do.
    /// `releaseAllAtMs` releases every pad on the last chain, as PlayViewModel.padInit does. Nothing at or after
    /// `giveUpAtMs` is played, as LedPathRun stops recording then: an endless animation no release
    /// reaches would otherwise run forever.
    static func of(_ pack: UniPack, releaseAllAtMs: Int64? = nil, giveUpAtMs: Int64 = .max) -> IntendedLedTimeline {
        TimelineSimulation(pack: pack).run(releaseAllAtMs: releaseAllAtMs, giveUpAtMs: giveUpAtMs)
    }
}

nonisolated private final class TimelineSimulation {
    private struct Owner: Equatable {
        let x: Int
        let y: Int
        let chain: Int
    }

    private final class Animation {
        let owner: Owner
        let led: LedAnimation
        var due: Int64
        var index = 0
        var loopProgress = 0
        var playing = true

        init(owner: Owner, led: LedAnimation, due: Int64) {
            self.owner = owner
            self.led = led
            self.due = due
        }
    }

    private let pack: UniPack
    private var pads: [[Owner?]]
    private var rounds: [Owner?] = Array(repeating: nil, count: LedRunner.circularLedCount)
    private var running: [Animation] = []
    private var out: [LedCommand] = []
    private var presses: [Int64] = []
    private var delayless = 0
    private var chain = 0

    init(pack: UniPack) {
        self.pack = pack
        pads = Array(repeating: Array(repeating: nil, count: pack.buttonY), count: pack.buttonX)
    }

    func run(releaseAllAtMs: Int64?, giveUpAtMs: Int64) -> IntendedLedTimeline {
        let elements = pack.autoPlayTable?.elements ?? []
        var next = 0
        var autoPlayTime: Int64 = 0
        var released = releaseAllAtMs == nil
        while true {
            while next < elements.count, case .delay(let delay) = elements[next] {
                autoPlayTime += Int64(delay)
                next += 1
            }
            let autoPlayDue: Int64
            if next < elements.count {
                autoPlayDue = autoPlayTime
            } else if !released, let releaseAllAtMs {
                autoPlayDue = max(releaseAllAtMs, autoPlayTime)
            } else {
                autoPlayDue = .max
            }
            let animationDue = running.map(\.due).min() ?? .max
            let t = min(autoPlayDue, animationDue)
            if t == .max || t >= giveUpAtMs { break }

            for animation in running where animation.due <= t { play(animation, at: t) }
            running.removeAll { !$0.playing }

            if autoPlayDue == t {
                if next < elements.count {
                    while next < elements.count {
                        if case .delay = elements[next] { break }
                        apply(elements[next], at: t)
                        next += 1
                    }
                } else {
                    for x in 0..<pack.buttonX {
                        for y in 0..<pack.buttonY { release(x: x, y: y, chain: chain, at: t) }
                    }
                    released = true
                }
            }
        }
        return IntendedLedTimeline(commands: out, pressTimes: presses, autoPlayLengthMs: autoPlayTime, delaylessEndlessAnimations: delayless)
    }

    /// The chain range ChainObserver clamps every chain change to.
    private func clamped(_ c: Int) -> Int { min(max(c, 0), max(pack.chain - 1, 0)) }

    private func apply(_ element: AutoPlay.Element, at t: Int64) {
        switch element {
        case .on(let x, let y, let currChain, let num):
            chain = clamped(currChain)
            pack.ledPush(c: chain, x: x, y: y, num: num)
            presses.append(t)
            press(x: x, y: y, at: t)
        case .off(let x, let y, let currChain):
            chain = clamped(currChain)
            release(x: x, y: y, chain: chain, at: t)
        case .chain(let c):
            chain = clamped(c)
        case .delay:
            break
        }
    }

    private func press(x: Int, y: Int, at t: Int64) {
        let owner = Owner(x: x, y: y, chain: chain)
        end(at: t) { $0.owner == owner }
        let led = pack.ledGet(c: chain, x: x, y: y)
        pack.ledPush(c: chain, x: x, y: y)
        if let led { running.append(Animation(owner: owner, led: led, due: t)) }
    }

    private func release(x: Int, y: Int, chain: Int, at t: Int64) {
        let owner = Owner(x: x, y: y, chain: chain)
        end(at: t) { $0.owner == owner && $0.led.loop == 0 }
    }

    private func end(at t: Int64, _ which: (Animation) -> Bool) {
        let ended = running.filter(which)
        for animation in ended {
            for x in pads.indices {
                for y in pads[x].indices where pads[x][y] == animation.owner {
                    out.append(LedCommand(ms: Double(t), target: LedTarget(x: x, y: y), code: 0))
                    pads[x][y] = nil
                }
            }
            for y in rounds.indices where rounds[y] == animation.owner {
                out.append(LedCommand(ms: Double(t), target: LedTarget(x: -1, y: y), code: 0))
                rounds[y] = nil
            }
        }
        running.removeAll { animation in ended.contains { $0 === animation } }
    }

    /// One animation's events due by `t`, as LedRunner.loop plays one state.
    private func play(_ animation: Animation, at t: Int64) {
        let events = animation.led.ledEvents
        guard !events.isEmpty else {
            animation.playing = false
            return
        }
        var played = 0
        while true {
            if animation.index >= events.count {
                animation.loopProgress += 1
                animation.index = 0
            }
            if animation.led.loop != 0 && animation.led.loop <= animation.loopProgress {
                animation.playing = false
                return
            }
            if animation.due > t { return }
            // Only an endless animation whose pass has no delay gets here, LedRunner's cap for it.
            played += 1
            if played > events.count * max(1, animation.led.loop) + 1 {
                delayless += 1
                animation.due = .max
                return
            }
            switch events[animation.index] {
            case .on(let x, let y, _, let velocity): light(x: x, y: y, code: velocity, owner: animation.owner, at: t)
            case .off(let x, let y): dim(x: x, y: y, owner: animation.owner, at: t)
            case .delay(let delay): animation.due += Int64(delay)
            case .chain(let c): chain = clamped(c)
            }
            animation.index += 1
        }
    }

    private func light(x: Int, y: Int, code: Int, owner: Owner, at t: Int64) {
        if x == -1 {
            guard rounds.indices.contains(y) else { return }
            rounds[y] = owner
        } else {
            guard pads.indices.contains(x), pads[x].indices.contains(y) else { return }
            pads[x][y] = owner
        }
        out.append(LedCommand(ms: Double(t), target: LedTarget(x: x, y: y), code: code))
    }

    private func dim(x: Int, y: Int, owner: Owner, at t: Int64) {
        if x == -1 {
            guard rounds.indices.contains(y), rounds[y] == owner else { return }
            rounds[y] = nil
        } else {
            guard pads.indices.contains(x), pads[x].indices.contains(y), pads[x][y] == owner else { return }
            pads[x][y] = nil
        }
        out.append(LedCommand(ms: Double(t), target: LedTarget(x: x, y: y), code: 0))
    }
}
