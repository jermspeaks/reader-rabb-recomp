import Foundation

/// A scene built from a COMB layout: the main menu and the four activity
/// exteriors. Re-implements the shared actor engine of RRPW32.EXE
/// (setup FUN_0041d5ea / FUN_00419555, per-tick update FUN_0041df18 /
/// FUN_004184fa): idle actors wait at their REST pose and play once when
/// clicked or triggered; looping actors run continuously; speech cues fire
/// when an actor reaches a given step.
class LayoutScene: Scene {
    /// Actor states (DAT_00447be2 / DAT_00447206).
    enum State: Int {
        case hidden = -1, idle = 0, playing = 1, looping = 2, continuous = 3, breakLoop = 4
    }

    final class Item {
        let entry: SceneLayout.Entry
        let actor: Actor?
        var state: State
        /// Sound last started by this actor's cue (for the IFSPEECH step code).
        var speech = 0

        init(entry: SceneLayout.Entry, actor: Actor?, state: State) {
            self.entry = entry
            self.actor = actor
            self.state = state
        }

        var id: Int { entry.id }

        var rect: Rect {
            if let a = actor { return a.rect }
            let x2 = abs(entry.x2)
            return Rect(x: entry.x1, y: entry.y1, w: x2 - entry.x1, h: entry.y2 - entry.y1)
        }
    }

    let combId: Int
    private(set) var layout: SceneLayout?
    private(set) var items: [Item] = []
    /// Host head (ASEQ 205) and body actors; the head is lip-synced.
    var headItem: Item?
    var bodyItem: Item?
    var bodyId = 206
    /// Ids drawn into the background once instead of being animated.
    var staticIds: Set<Int> = []
    var cuesEnabled = true

    private var blinkTimer = 0
    private var script: [Int] = []
    private var scriptPos = 0
    private var scriptDelay = 0
    var speaking: Bool { !script.isEmpty }

    init(comb: Int) {
        combId = comb
    }

    // MARK: Setup

    func enter(_ game: Game) {
        layout = game.res.comb(combId)
        guard let layout else { return }
        game.setBackground(layout.sceneId)
        items = layout.entries.map { e in
            guard e.id > 0, let a = game.res.aseq(e.id) else {
                return Item(entry: e, actor: nil, state: .idle)
            }
            let startsIdle = (a.step(0)?.frame ?? 0) < 0
            let actor = Actor(a, x: e.x1, y: e.y1, step: startsIdle ? 1 : 0)
            actor.tag = e.id
            return Item(entry: e, actor: actor, state: startsIdle ? .idle : .continuous)
        }
        headItem = items.last { $0.id == 205 }
        bodyItem = items.last { $0.id == bodyId }
        for item in items where staticIds.contains(item.id) {
            if let a = item.actor, let s = a.sprite {
                let r = a.rect
                game.fb.stamp(s, x: r.x, y: r.y)
            }
        }
        configure(game)
    }

    /// Per-scene initial actor setup (after the layout is loaded).
    func configure(_ game: Game) {}

    // MARK: Speech scripts

    /// Run a list of lip-synced speech ids; negative entries are delays in ticks
    /// (FUN_0041d980 / FUN_0041809a).
    func runScript(_ ids: [Int]) {
        script = ids
        scriptPos = 0
        scriptDelay = 0
    }

    func stopScript(_ game: Game) {
        if !script.isEmpty { game.stopSpeech() }
        script = []
    }

    private func stepScript(_ game: Game) {
        guard !script.isEmpty, game.mouth == nil, !game.speechPlaying else { return }
        if scriptDelay > 0 { scriptDelay -= 1; return }
        guard scriptPos < script.count else { script = []; return }
        let v = script[scriptPos]
        scriptPos += 1
        if v < 0 { scriptDelay = -v } else if v > 0 { game.sayWithLips(v) }
    }

    // MARK: Tick

    func tick(_ game: Game) {
        stepScript(game)
        updateHead(game)
        for (index, item) in items.enumerated() where item.state.rawValue > 0 {
            guard let actor = item.actor else { item.state = .idle; continue }
            advance(item, actor, game)
            if cuesEnabled, item.state != .hidden {
                for cue in item.entry.cues where cue.step == actor.step {
                    cueFired(game, item)
                    game.say(cue.sound)
                    item.speech = cue.sound
                    break
                }
            }
            _ = index
        }
        afterTick(game)
    }

    /// Called when an actor reaches a LOOP step; return true to stop it there.
    func loopReached(_ game: Game, _ item: Item) -> Bool { false }

    /// Hook called after actors have advanced.
    func afterTick(_ game: Game) {}

    /// A cue interrupts the host's speech (FUN_0041d922).
    func cueFired(_ game: Game, _ item: Item) {
        if speaking { stopScript(game) }
    }

    private func advance(_ item: Item, _ actor: Actor, _ game: Game) {
        let steps = actor.aseq.steps
        var s = actor.step + 1
        var guardCount = 0
        while s >= 0, s < steps.count, steps[s].frame < 0, guardCount < 64 {
            guardCount += 1
            let st = steps[s]
            switch st.frame {
            case StepCode.branch:
                if item.state == .breakLoop { s = st.dy; item.state = .playing } else { s = st.dx; item.state = .looping }
            case StepCode.trigger:
                trigger(st.dy)
                s += 1
            case StepCode.ifSpeech:
                if !game.speechPlaying || item.speech != game.currentSpeech {
                    s = st.dy; item.state = .playing
                } else {
                    s = st.dx; item.state = .looping
                }
            case StepCode.rest:
                item.state = .idle
                s += 1
            case StepCode.loop:
                if loopReached(game, item) { return }
                s = 0
            default:
                // END: stay on the last drawn step.
                item.state = .idle
                return
            }
        }
        if s >= 0, s < steps.count { actor.step = s } else { item.state = .idle }
    }

    /// Start the actor whose layout id is `id` (FUN_0041de54).
    func trigger(_ id: Int) {
        guard let item = items.last(where: { $0.actor != nil && $0.id == id }) else { return }
        if item.state == .looping { item.state = .breakLoop }
        if item.state == .idle { item.state = .playing }
    }

    /// Generic click on an actor: play it once, or leave its loop.
    func activate(_ item: Item) {
        item.state = item.state == .looping ? .breakLoop : .playing
    }

    private func updateHead(_ game: Game) {
        guard let head = headItem?.actor else { return }
        if let m = game.mouth {
            head.step = m + 1
        } else if blinkTimer > 0 {
            blinkTimer -= 1
            head.step = 1
        } else if game.random(5) == 0 {
            blinkTimer = 8
            head.step = 9
        } else {
            head.step = 1
        }
    }

    // MARK: Input

    /// Topmost idle or looping item under the point (playing actors are not clickable).
    func hitTest(_ x: Int, _ y: Int) -> Item? {
        for item in items.reversed() where item.state == .idle || item.state == .looping {
            if item === headItem || item === bodyItem {
                guard let h = headItem?.rect, let b = bodyItem?.rect else { continue }
                let r = Rect(x: min(h.x, b.x), y: min(h.y, b.y),
                             w: max(h.x + h.w, b.x + b.w) - min(h.x, b.x),
                             h: max(h.y + h.h, b.y + b.h) - min(h.y, b.y))
                if r.contains(x, y) { return item }
                continue
            }
            if item.rect.contains(x, y) { return item }
        }
        return nil
    }

    func click(_ game: Game, x: Int, y: Int) {}

    func key(_ game: Game, _ key: Key) {}

    func exit(_ game: Game) {}

    // MARK: Drawing

    func draw(_ game: Game, _ fb: Framebuffer) {
        for item in items where item.state != .hidden && !staticIds.contains(item.id) {
            if item === headItem || item === bodyItem { continue }
            item.actor?.draw(fb)
        }
        bodyItem?.actor?.draw(fb)
        headItem?.actor?.draw(fb)
    }
}
