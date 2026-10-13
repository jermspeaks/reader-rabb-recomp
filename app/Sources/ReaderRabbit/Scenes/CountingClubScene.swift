import Foundation

/// Counting Club (RRPW32.EXE enter FUN_0042c38c, tick FUN_0042965d, mouse
/// FUN_0042b085, key FUN_0042b90c, exit FUN_0042bfd2; docs/game-logic.md §4.1).
///
/// Animals hide in four tree hollows; the cat host names a number on the big sign.
/// - Level 0: open the tree whose sign shows that number; its animals come out
///   and are counted, then the child tells the host (click or Enter).
/// - Level 1: no tree numbers; each click on a tree brings ONE animal out.
/// - Level 2: each click brings a tree's whole group out (add groups up to the target).
/// - Level 3: the number is hidden and the signs show pictures; any number of
///   animals is accepted and counted.
/// The bush (levels 1–3, Tab) sends the last animal (level 2: last group) back.
/// A round without mistakes advances the meter; progress 4 shows a dance, and
/// progress 8 earns the level's key.
final class CountingClubScene: Scene {
    private static let act = Activity.countingClub.rawValue

    // MARK: Data read from the user's RRPW32.EXE

    /// 114 rows of (target, four tree counts) (table 0x4442fc).
    private var content: [[Int]] = []
    /// Clearing positions (table 0x443f26): level 0 uses n(n−1)/2…, levels 1–3 use 55….
    private var spots: [(x: Int, y: Int)] = []
    /// Dancer lists for the progress shows (pointer table 0x4442b8).
    private var rewards: [[(x: Int, y: Int, aseq: Int)]] = []
    /// (step, wave) sounds for a clicked animal, by animal code (pointer table 0x444c6c).
    private var frameSounds: [[(step: Int, wave: Int)]] = []
    private var greetScript: [Int] = []          // 0x444794
    private var introScripts: [[Int]] = []       // 0x444848
    private var promptScripts: [[Int]] = []      // 0x4449c4
    private var doneScripts: [[Int]] = []        // 0x444a70
    private var wrongScripts: [[Int]] = []       // 0x444ac4

    // MARK: Layout and ids (RRPW32.EXE tables 0x443de0–0x444d52)

    private static let doorLayout = [(91, 177, 11051), (534, 197, 11052), (139, 140, 11053), (481, 149, 11054)]
    private static let eyeLayout = [(93, 234), (544, 222), (141, 156), (483, 173)]   // ASEQ 11001
    private static let signLayout = [(125, 211, 11005), (482, 212, 11005), (167, 145, 11007), (444, 145, 11007)]
    /// Number speech 0…10 (0x443e52; also the ids whose LIPS are preloaded).
    private static let numbers = [23188, 23182, 23187, 23186, 23180, 23179, 23184, 23183, 23178, 23181, 23185]
    /// Animal types 0 snake, 1 turtle, 2 frog, 3 bear: ASEQ base and offset (0x443e10 / 0x443e00 / 0x443e08).
    private static let animalAseq = [11300, 11400, 11200, 11100]
    private static let animalDX = [0, 10, 9, -10]
    private static let animalDY = [0, -8, 37, -27]
    /// Singular, then plural animal names (0x443e18).
    private static let animalNames = [23121, 23123, 23104, 23102, 23122, 23124, 23105, 23102]
    private static let kindA = [23100, 23100, 23135, 23137, 23139]   // 0x443e28
    private static let kindB = [23101, 23101, 23136, 23138, 23140]   // 0x443e32
    /// "N animals" phrases: base per type (0x444d3c) + alphabetical index of N (0x443e3c).
    private static let countBase = [16522, 16533, 16511, 16500]
    private static let countIndex = [10, 4, 9, 8, 2, 1, 6, 5, 0, 3, 7]
    private static let fidgets = [11010, 11011, 11012, 11016, 11017, 11013]   // 0x443e90
    private static let moveSounds = [16546, 16549, 16547, 16548]             // 0x444770
    private static let exitSpeech = [21116, 21121, 21122, 21124, 21125, 21046, 21066]   // 0x444778
    /// Kinds offered per level (0x444d52, 5 per level).
    private static let kinds = [0, 2, 3, 0, 2, 0, 2, 3, 4, 0, 0, 1, 2, 3, 4, 0, 1, 2, 3, 4]
    /// Level-3 sign picture group per type (0x444d44; the bear reads past it into 0x444d4a[0] = 0).
    private static let signGroup = [2, 3, 1, 0]
    private static let rowStart = [0, 30, 60, 84]     // 0x444d34
    private static let rowCount = [30, 30, 24, 30]    // 0x444d2c
    private static let promptRange = [0, 5, 9, 12, 15]   // 0x444a40
    private static let hintTicks = 259     // 30 s at the 116 ms tick
    private static let fidgetTicks = 86    // 10 s

    // Session state the original keeps in globals across visits.
    private static var greeted = false      // DAT_0044811a
    private static var lastType = -1        // DAT_00448110
    private static var lastKind = -1        // DAT_0044810e
    private static var lastPrompt = 0       // DAT_0044811e
    private static var lastWrong = -1       // DAT_00448120
    private static var introToggle = 0      // DAT_00448118
    private static var lastGroup = -1       // DAT_00448214[1]
    private static var hintCycle = 0        // DAT_0044811c

    // MARK: Actors

    private final class Tree {
        var count = 0                 // DAT_00448012 (−1 = sign blanked)
        var codes: [Int] = []         // DAT_00448054: type × 10 + kind per animal
        var door: Actor?
        var eyes: Actor?
        var sign: Actor?
        var doorState = 1             // DAT_0044800a: 1 closed, 2 opening, 3 open, 0 idle (reward)
        var signText: String?
    }

    private final class Animal {
        let actor: Actor
        let code: Int
        let tree: Int
        var anim = 0                  // DAT_00447fdc: 0 still, 1 play, 2 clicked loop, 9 play once and hold, −1 sent back
        var visible: Bool
        init(_ actor: Actor, code: Int, tree: Int, visible: Bool) {
            self.actor = actor
            self.code = code
            self.tree = tree
            self.visible = visible
        }
    }

    private var trees: [Tree] = []
    private var animals: [Animal] = []
    private var bigSign: Actor?
    private var bigText: String?
    private var head: Actor?
    private var body: Actor?
    private var bush: Actor?
    private var bushMode = 0          // DAT_00447fda: −1 peeking, 1 taking an animal back
    private var bushFirst = true      // DAT_00448132
    private var bushTree = -1         // DAT_00448022
    private var bushGroup = 0         // DAT_00448024
    private var finale: Actor?        // level-3 level-complete actor (0x44891e)
    private var finaleEnded = false
    private var exitSign: Actor?
    private var meter: Actor?
    private var smallFont: BitmapFont?
    private var signFont: BitmapFont?
    private var bigFont: BitmapFont?

    // MARK: Round state

    private var level = 0
    private var group = 0
    private var target = 0            // DAT_0044810c (negative = hidden at level 3)
    private var type = 0
    private var kind = 0
    private var open = -1             // DAT_00448008
    private var cursor = -1           // DAT_00448130
    private var counted = 0           // DAT_00448108
    private var wrong = -1            // DAT_00448114: the mistaken count, −1 = none yet
    private var buzz = 0              // DAT_00448104
    private var playOnce = false      // DAT_00448122
    private var clicked = -1          // DAT_00448112
    private var numberToggle = false  // DAT_0044810a
    private var keyPicked = 0         // DAT_00448136
    private var explained = false     // DAT_00448138
    private var introPlayed = false   // DAT_0044813a
    private var introIndex = 0        // DAT_00448116
    private var meterToggle = false   // DAT_00448134
    private var busy = true           // DAT_00447fd6
    private var levelDone = false     // DAT_00447fb8

    private enum Phase {
        case waitCut, script, idle, countOut, explain, countAloud, celebrate, countDown, record, levelDone, leaving
    }
    private enum ScriptKind { case greeting, intro, prompt, number, explain, wrong, reward, song, levelDone }
    private var phase = Phase.waitCut
    private var scriptKind = ScriptKind.greeting
    private var script: [Int] = []
    private var scriptDelay = 0
    private var afterScript: (() -> Void)?
    private var waitingLips = false
    /// Host animation (DAT_00447fd8): 0 none, 2 play once then idle, 3 loop.
    private var hostAnim = 0
    private var idleTicks = 0
    private var fidgetTicks = 0

    init() {}

    // MARK: Enter / exit (FUN_0042c38c / FUN_0042bfd2)

    func enter(_ game: Game) {
        if game.player.progress[Self.act] > 7 { game.player.completeLevel(Self.act) }
        level = min(3, game.player.level[Self.act])
        loadTables(game)
        game.setBackground(11000)
        smallFont = game.res.font(1014)
        signFont = game.res.font(1018)
        bigFont = game.res.font(1036)
        exitSign = make(game, 212, 550, 406)
        meter = make(game, 501, 30, 401)
        pickRound(game)
        createSprites(game)
        explained = false
        bushFirst = true
        introPlayed = false
        phase = .waitCut
    }

    func exit(_ game: Game) { game.savePlayer() }

    private func loadTables(_ game: Game) {
        guard let exe = game.exe else {
            // No EXE: a generated stand-in so the scene still runs.
            content = (0..<114).map { _ in [3, 1, 2, 3, 4] }
            spots = (0..<65).map { (200 + ($0 % 5) * 50, 200 + ($0 % 3) * 60) }
            return
        }
        content = (0..<114).map { exe.shorts(at: 0x4442FC + 10 * $0, count: 5) }
        spots = (0..<65).map { i in
            let p = exe.shorts(at: 0x443F26 + 4 * i, count: 2)
            return p.count == 2 ? (p[0], p[1]) : (300, 260)
        }
        rewards = (0..<17).map { i in
            guard let p = exe.u32(at: 0x4442B8 + 4 * i) else { return [] }
            var list: [(x: Int, y: Int, aseq: Int)] = []
            for k in 0..<10 {
                let t = exe.shorts(at: p + 6 * k, count: 3)
                guard t.count == 3, t[2] != 0 else { break }
                list.append((t[0], t[1], t[2]))
            }
            return list
        }
        frameSounds = exe.scripts(at: 0x444C6C, count: 36).map { s in
            stride(from: 0, to: s.count - 1, by: 2).map { (s[$0], s[$0 + 1]) }
        }
        greetScript = exe.scripts(at: 0x444794, count: 1).first ?? []
        introScripts = exe.scripts(at: 0x444848, count: 17)
        promptScripts = exe.scripts(at: 0x4449C4, count: 31)
        doneScripts = exe.scripts(at: 0x444A70, count: 4)
        wrongScripts = exe.scripts(at: 0x444AC4, count: 9)
    }

    private func make(_ game: Game, _ id: Int, _ x: Int, _ y: Int, step: Int = 1) -> Actor? {
        game.res.aseq(id).map { Actor($0, x: x, y: y, step: step) }
    }

    // MARK: Rounds (FUN_00428252 pick, FUN_0042c0d8 fill, FUN_00428f7d sprites, FUN_00428486 next)

    private func pickRound(_ game: Game) {
        level = min(3, game.player.level[Self.act])
        // The first three credited rounds of a level use only the five easiest groups.
        var n = Self.rowCount[level]
        if game.player.usedContent[Self.act].count < 3 { n = 15 }
        group = pickUnused(game, n / 3)
        let idx = group * 3 + game.random(3)
        let row = content.indices.contains(Self.rowStart[level] + idx) ? content[Self.rowStart[level] + idx] : [3, 1, 2, 3, 4]
        target = level == 3 ? -row[0] : row[0]
        var t: Int
        repeat { t = game.random(3) } while t == Self.lastType
        Self.lastType = t
        if target == 1, game.random(7) != 0 { Self.lastType = 3 }
        type = Self.lastType
        var counts = Array(row[1...4])
        for k in 0..<4 { counts.swapAt(k, game.random(4)) }
        trees = counts.map { let t = Tree(); t.count = $0; return t }
        fillTrees(game)
        animals = []
        open = -1
        cursor = -1
        counted = 0
        hostAnim = 0
        bushMode = 0
        Self.introToggle = Self.introToggle == 0 ? 1 : 0
        introIndex = level != 0 && Self.introToggle != 0 ? level + 7 : level + 4
        playOnce = false
        numberToggle = false
        wrong = -1
        buzz = 0
        keyPicked = 0
        levelDone = false
    }

    /// FUN_00431279: random unused entry (not the last one); all used → clear and reuse.
    private func pickUnused(_ game: Game, _ n: Int) -> Int {
        let used = Set(game.player.usedContent[Self.act])
        var r = game.random(n)
        for _ in 0..<(n + 2) {
            if r != Self.lastGroup, !used.contains(r) { Self.lastGroup = r; return r }
            Self.lastGroup = -1
            r = (r + 1) % n
        }
        game.player.usedContent[Self.act] = []
        Self.lastGroup = r
        return r
    }

    private func fillTrees(_ game: Game) {
        var k: Int
        repeat { k = Self.kinds[level * 5 + game.random(5)] } while k == Self.lastKind
        Self.lastKind = k
        kind = k
        var bear = false
        var t = type
        for tree in trees {
            // Level 1: a random type per tree; levels 2–3: a random kind per tree.
            if level == 1 {
                t = game.random(3)
                if !bear, tree.count == 1, game.random(7) != 0 { t = 3; bear = true }
            }
            var treeKind = kind
            if level > 1 { treeKind = game.random(6) }
            tree.codes = (0..<max(0, tree.count)).map { _ in
                if level == 1 { treeKind = Self.kinds[level * 5 + game.random(5)] }
                if level == 2 {
                    t = game.random(3)
                    if !bear, tree.count == 1, game.random(7) != 0 { t = 3; bear = true }
                }
                return t * 10 + treeKind
            }
        }
    }

    private func createSprites(_ game: Game) {
        bigSign = make(game, 11006, 232, 89)
        bigText = nil
        for (k, tree) in trees.enumerated() {
            let s = Self.signLayout[k]
            var step = 1
            if level == 3 {
                let c = tree.codes.first ?? -1
                step = c % 10 + Self.signGroup[min(3, max(0, c / 10))] * 6 + 2
            }
            tree.sign = make(game, s.2, s.0, s.1, step: step)
            let d = Self.doorLayout[k]
            tree.door = make(game, d.2, d.0, d.1)
            let e = Self.eyeLayout[k]
            tree.eyes = make(game, 11001, e.0, e.1, step: k * 2 + 10)
            tree.doorState = 1
            tree.signText = nil
        }
        hostIdle(game)
        bush = level != 0 ? make(game, 11002, 494, 296) : nil
        finale = nil
        busy = true
    }

    private func nextRound(_ game: Game) {
        pickRound(game)
        createSprites(game)
        if !introPlayed {
            introPlayed = true
            var i = 2 + game.random(2)
            if level != 0, i == 2 { i = 15 }
            if level != 3 {
                run(introScripts[at: i], .intro) { [unowned self] in prompt(game) }
                return
            }
        }
        prompt(game)
    }

    // MARK: Signs (FUN_00428550 / FUN_00428730)

    private func redrawBig() {
        bigText = target < 1 ? nil : target < 11 ? "\(target)" : nil
    }

    private func redrawSign(_ k: Int) {
        let t = trees[k]
        t.signText = level != 3 && level != 1 && target >= 0 && t.count >= 0 ? "\(t.count)" : nil
    }

    private func redrawAll() {
        redrawBig()
        for k in 0..<4 { redrawSign(k) }
    }

    // MARK: Host (FUN_00429289 / FUN_004291b4)

    /// Talking poses: 12 talk, 14 point and talk, 15 idle.
    private func hostPose(_ game: Game, _ slot: Int) {
        let r = game.res
        body = make(game, slot == 14 ? 11023 : 11021, 315, 128)
        if let a = r.aseq(slot == 15 ? 11022 : 11020) {
            if let head { head.set(a, step: 1, x: 316, y: 98) } else { head = Actor(a, x: 316, y: 98) }
        }
        hostAnim = 0
    }

    private func hostIdle(_ game: Game) { hostPose(game, 15) }

    /// Whole-body animation in the head slot (the body is hidden meanwhile).
    private func hostPlay(_ game: Game, _ id: Int, loop: Bool) {
        guard let a = game.res.aseq(id) else { return }
        body = nil
        if let head { head.set(a, step: 1, x: 315, y: 98) } else { head = Actor(a, x: 315, y: 98) }
        hostAnim = loop ? 3 : 2
    }

    // MARK: Scripts (FUN_0042934c)

    /// Entries: >0 speech (lip-synced), <0 delay, 1–3 host pose, 98/99 show the
    /// tree/big numbers, 100 target number, 102/104 kind words, 103 animal name,
    /// 105 the mistaken number, 110 bush peek (ends the script), 0 end.
    private func run(_ s: [Int], _ kind: ScriptKind, then: @escaping () -> Void) {
        script = s
        scriptDelay = 0
        scriptKind = kind
        afterScript = then
        phase = .script
    }

    private func stepScript(_ game: Game) {
        guard game.mouth == nil, !game.speechPlaying else { return }
        if scriptDelay > 0 { scriptDelay -= 1; return }
        guard !script.isEmpty else { finishScript(game); return }
        let v = script.removeFirst()
        if v < 0 { scriptDelay = -v; return }
        switch v {
        case 98: for k in 0..<4 { redrawSign(k) }
        case 99: redrawBig()
        case 110:
            bushPeek(game, 11004)
            finishScript(game)
        case 1...3: hostPose(game, [0, 12, 15, 14][v])
        default:
            var id = v
            switch v {
            case 100: id = Self.numbers[safe: target] ?? 0
            case 102: id = Self.kindA[safe: kind] ?? 0
            case 103: id = Self.animalNames[type + (target > 1 ? 4 : 0)]
            case 104: id = Self.kindB[safe: kind] ?? 0
            case 105: id = Self.numbers[safe: wrong] ?? 0
            default: break
            }
            if id > 0 { game.sayWithLips(id) }
        }
    }

    private func finishScript(_ game: Game) {
        script = []
        hostIdle(game)
        let next = afterScript
        afterScript = nil
        next?()
    }

    private func speak(_ game: Game, _ id: Int, then: @escaping () -> Void) {
        run([1, id], .number, then: then)
    }

    private func sayCount(_ game: Game, _ n: Int) {
        guard let i = Self.countIndex[safe: n] else { return }
        game.say(Self.countBase[type] + i)
        clicked = -1
    }

    // MARK: Tick (FUN_0042965d)

    func tick(_ game: Game) {
        if phase == .waitCut {
            guard !game.speechPlaying else { return }
            if Self.greeted {
                run(introScripts[at: introIndex], .intro) { [unowned self] in prompt(game) }
            } else {
                run(greetScript, .greeting) { [unowned self] in Self.greeted = true; prompt(game) }
            }
        }
        animateHost(game)
        animateTrees(game)
        // Drop animals the bush took back.
        while let last = animals.last, last.anim == -1 { animals.removeLast(); counted -= 1 }
        animateAnimals(game)
        animateBush(game)
        if buzz == 1, !game.speechPlaying {
            clicked = -1
            game.say(16550 + game.random(10))
            buzz = 2
        }
        if phase != .idle { idleTicks = 0; fidgetTicks = 0 }
        switch phase {
        case .script: stepScript(game)
        case .idle:
            busy = false
            idleTimers(game)
        case .countOut, .countAloud: stepCounting(game)
        case .explain:
            if animals.allSatisfy({ $0.anim == 0 }) {
                explained = true
                playOnce = false
                phase = .idle
            }
        case .celebrate:
            if hostAnim == 2 {
                if head?.step == 7 { game.say(23228 + game.random(6)) }
            } else if !game.speechPlaying {
                if level == 0 {
                    counted = animals.count
                    hostPlay(game, Self.fidgets[kind], loop: true)
                    phase = .countDown
                } else {
                    phase = .record
                }
            }
        case .countDown:
            // FUN 0x20: the animals leave one by one, counting down to zero.
            guard !game.speechPlaying else { break }
            if counted < animals.count {
                animals[counted].anim = 0
                animals[counted].visible = false
            }
            let n = counted
            counted -= 1
            if counted < 0 {
                if hostAnim != 0 { hostAnim = 2 }
                phase = .record
            }
            sayCount(game, n)
        case .record:
            if !game.speechPlaying, hostAnim == 0 { record(game) }
        case .levelDone:
            if levelAnimDone(game) { finishLevel(game) }
        case .waitCut, .leaving:
            break
        }
        if phase == .script, scriptKind == .levelDone { _ = levelAnimDone(game) }
    }

    private func animateHost(_ game: Game) {
        if let body {
            if (body.aseq.step(body.step + 1)?.frame ?? -1) < 0 {
                if let a = game.res.aseq(11021) { body.set(a, step: 1) }
            } else {
                body.step += 1
            }
        }
        guard let head else { return }
        if hostAnim != 0 || head.aseq.id == 11022 {
            if (head.aseq.step(head.step + 1)?.frame ?? -1) < 0 {
                head.step = 1
                if hostAnim == 2 { hostIdle(game) }
            } else {
                head.step += 1
            }
        } else if head.aseq.id == 11020 {
            head.step = (game.mouth ?? 0) + 1
        }
    }

    private func animateTrees(_ game: Game) {
        for (k, t) in trees.enumerated() {
            if t.doorState == 2, let door = t.door {
                if (door.aseq.step(door.step + 1)?.frame ?? -1) < 0 {
                    if phase == .script && (scriptKind == .levelDone || scriptKind == .song) || phase == .levelDone {
                        t.doorState = 0
                    } else {
                        t.doorState = 3
                        if !busy { doorOpened(game, k) }
                    }
                } else {
                    door.step += 1
                }
            }
            if t.doorState > 1, let eyes = t.eyes {
                let next = eyes.step + 1
                eyes.step = (eyes.aseq.step(next)?.frame ?? -1) < 0 ? 1 : next
            }
        }
    }

    private func eyesVisible(_ k: Int) -> Bool {
        let c = trees[k].count
        return c >= 1 && !(level == 0 && c != target && phase != .countOut)
    }

    private func animateAnimals(_ game: Game) {
        for (i, a) in animals.enumerated() where a.anim > 0 {
            let next = a.actor.step + 1
            let ended = (a.actor.aseq.step(next)?.frame ?? -1) < 0
            if a.anim == 2, i == clicked, game.mouth == nil, !ended,
               let s = frameSounds[safe: a.code]?.first(where: { $0.step == next }) {
                game.say(s.wave)
            }
            if ended {
                if a.anim == 9 { continue }
                a.actor.step = 1
                if playOnce { a.anim = 0 }
            } else {
                a.actor.step = next
            }
        }
    }

    private func animateBush(_ game: Game) {
        guard let bush, bushMode != 0 else { return }
        let next = bush.step + 1
        if bushMode < 0 {
            if next == 2 {
                clicked = -1
                if bushFirst { game.say(16567); bushFirst = false } else { game.say(game.random(2) == 0 ? 16567 : 16562) }
            }
        } else {
            if next == 2, game.random(6) != 0 { clicked = -1; game.say(16560) }
            if next == 11 {
                bushTree = -1
                if let last = animals.last {
                    bushTree = last.tree
                    if level == 2 {
                        bushGroup = 0
                        for a in animals.reversed() {
                            guard a.tree == bushTree else { break }
                            a.visible = false
                            a.anim = -1
                            bushGroup += 1
                        }
                    } else {
                        last.visible = false
                        last.anim = -1
                    }
                }
                if !game.speechPlaying { clicked = -1; game.say(16544 + game.random(2)) }
            }
        }
        if (bush.aseq.step(next)?.frame ?? -1) < 0 {
            if bushMode > 0, bushTree >= 0 {
                let t = trees[bushTree]
                t.count = level == 2 ? bushGroup : max(0, t.count) + 1
                redrawSign(bushTree)
            }
            bushMode = 0
            if let a = game.res.aseq(11002) { bush.set(a, step: 1) }
        } else {
            bush.step = next
        }
    }

    private func bushPeek(_ game: Game, _ id: Int) {
        guard let bush, let a = game.res.aseq(id) else { return }
        bush.set(a, step: 1)
        bushMode = -1
    }

    /// FUN_00429544: a hint after 30 s, a host fidget every 10 s.
    private func idleTimers(_ game: Game) {
        guard hostAnim == 0, bushMode == 0 else { fidgetTicks = 0; return }
        idleTicks += 1
        fidgetTicks += 1
        if idleTicks > Self.hintTicks {
            var i = 0x1A
            if animals.isEmpty {
                if level == 3 { i = 0x19 }
            } else {
                Self.hintCycle = Self.hintCycle % 2 + 1
                i = Self.hintCycle + 0x1A
                if level == 0 || level == 3 { i = Self.hintCycle == 2 ? 0x1E : Self.hintCycle + 0x1B }
            }
            Self.lastPrompt = i < 0x1B ? i : 0
            run(promptScripts[at: i], .prompt) { [unowned self] in phase = .idle }
        } else if fidgetTicks > Self.fidgetTicks {
            fidgetTicks = 0
            game.stopSpeech()
            hostPlay(game, Self.fidgets[game.random(Self.fidgets.count)], loop: false)
        }
    }

    // MARK: Round flow

    /// State 6: show the numbers and ask (prompt table 0x4449c4, ranges 0x444a40).
    private func prompt(_ game: Game) {
        redrawAll()
        let lo = Self.promptRange[level], hi = Self.promptRange[level + 1]
        var i: Int
        repeat {
            i = lo + game.random(hi - lo)
            if i == 2, target == 1 { i = Self.lastPrompt }
        } while i == Self.lastPrompt
        Self.lastPrompt = i
        run(promptScripts[at: i], .prompt) { [unowned self] in phase = .idle }
    }

    private func doorOpened(_ game: Game, _ k: Int) {
        if level == 0 { checkOpenTree(game) } else { takeOne(game) }
    }

    /// State 0xe (level 0): the opened tree holds the target → bring them out.
    private func checkOpenTree(_ game: Game) {
        busy = false
        guard open >= 0 else { phase = .idle; return }
        let c = trees[open].count
        if c == target {
            if keyPicked < 1 { keyPicked = keyPicked == 0 ? 1 : 0 }
            takeOutAll(game)
        } else if c >= 0, let id = Self.numbers[safe: c] {
            speak(game, id) { [unowned self] in phase = .idle }
        } else {
            phase = .idle
        }
    }

    /// State 0x11 (level 0).
    private func takeOutAll(_ game: Game) {
        busy = true
        let c = trees[open].count
        if c == target {
            if animals.count == target {
                sayCount(game, c)
                phase = .idle
            } else {
                counted = 0
                spawn(game, from: open, all: true)
                playOnce = true
                phase = .countOut
            }
        } else {
            if c != 0 { sayCount(game, c) }
            phase = .idle
        }
    }

    /// State 0xc (levels 1, 3: one animal) / 0xd (level 2: the whole group).
    private func takeOne(_ game: Game) {
        busy = true
        guard open >= 0, trees[open].count > 0 else { phase = .idle; return }
        if level == 2 {
            counted = animals.count
            spawn(game, from: open, all: true)
            playOnce = true
            phase = .countOut
            return
        }
        spawn(game, from: open, all: false)
        clicked = -1
        if let a = animals.last { game.say(Self.moveSounds[min(3, a.code / 10)]) }
        redrawSign(open)
        counted += 1
        phase = .idle
    }

    /// FUN_00428ca6: animals leave tree `k` for the clearing (hidden until counted when `all`).
    private func spawn(_ game: Game, from k: Int, all: Bool) {
        let t = trees[k]
        guard t.count > 0 else { return }
        if all {
            var spot = level == 0 ? (t.count * (t.count + 1)) / 2 - t.count : animals.count + 55
            for i in 0..<t.count {
                addAnimal(game, code: t.codes[safe: i] ?? type * 10, tree: k, spot: spot, visible: false)
                spot += 1
            }
        } else {
            t.count -= 1
            addAnimal(game, code: t.codes[safe: t.count] ?? type * 10, tree: k, spot: animals.count + 55, visible: true)
        }
    }

    private func addAnimal(_ game: Game, code: Int, tree: Int, spot: Int, visible: Bool) {
        let ty = min(3, max(0, code / 10))
        let p = spots[safe: spot] ?? (300, 260)
        guard let a = game.res.aseq(Self.animalAseq[ty] + code % 10) else { return }
        let actor = Actor(a, x: Self.animalDX[ty] + p.x, y: Self.animalDY[ty] + p.y, step: 1)
        animals.append(Animal(actor, code: code, tree: tree, visible: visible))
    }

    /// States 0x12/0x13 (bring out and count) and 0x1b/0x1c (count what is out).
    private func stepCounting(_ game: Game) {
        if waitingLips {
            guard game.mouth == nil, !game.speechPlaying else { return }
            waitingLips = false
            if counted < animals.count { return }
            hostIdle(game)
            if phase == .countOut { afterCountOut(game) } else { celebrate(game) }
            return
        }
        guard counted < animals.count else {
            if phase == .countOut { afterCountOut(game) } else { celebrate(game) }
            return
        }
        if phase == .countOut {
            if open >= 0 { trees[open].count -= 1 }
            animals[counted].anim = 1
            animals[counted].visible = true
            counted += 1
            if level == 3 { target = counted; redrawBig() }
        } else {
            counted += 1
            playOnce = true
            for a in animals.prefix(counted) { a.anim = 1 }
        }
        hostPose(game, 12)
        game.sayWithLips(Self.numbers[safe: counted] ?? Self.numbers[10])
        waitingLips = true
    }

    /// State 0x14: level 0 closes the trees and explains once; level 2 waits for more.
    private func afterCountOut(_ game: Game) {
        if level == 0 {
            for k in 0..<4 { trees[k].count = -1; redrawSign(k) }
            if open >= 0 { resetDoor(game, open) }
            open = -1
        }
        guard level < 2 else { phase = .idle; return }
        if explained {
            phase = .explain
        } else {
            run(introScripts[at: 1], .explain) { [unowned self] in phase = .explain }
        }
    }

    private func resetDoor(_ game: Game, _ k: Int) {
        let d = Self.doorLayout[k]
        trees[k].door = make(game, d.2, d.0, d.1)
        trees[k].doorState = 1
    }

    /// State 0x17: the child says "done".
    private func check(_ game: Game) {
        busy = true
        if level == 3 { target = animals.count; redrawBig() }
        guard animals.count == target else { wrongAnswer(game); return }
        counted = 0
        for k in 0..<4 {
            resetDoor(game, k)
            trees[k].count = -1
            redrawSign(k)
        }
        open = -1
        if level == 1 || level == 3 { phase = .countAloud } else { celebrate(game) }
    }

    /// State 0x18: explain the mistake (scripts 0x444ac4).
    private func wrongAnswer(_ game: Game) {
        var i: Int
        repeat { i = game.random(2) + level * 3 } while i == Self.lastWrong
        Self.lastWrong = i
        if level != 0 {
            wrong = animals.count
            i = animals.count < target ? 6 + game.random(2) : 3
        }
        run(wrongScripts[at: i], .wrong) { [unowned self] in phase = .idle }
    }

    /// State 0x1e: everyone dances, the host cheers (ASEQ 11014, SPEECH 23228+).
    private func celebrate(_ game: Game) {
        for a in animals { a.anim = 1 }
        playOnce = true
        hostPlay(game, 11014, loop: false)
        phase = .celebrate
    }

    /// States 0x21/0x23 (FUN_00428188 / FUN_00428049): only mistake-free rounds count.
    private func record(_ game: Game) {
        var p = game.player.progress[Self.act]
        let credited = wrong < 0 && p < 8
        if wrong < 0 { markUsed(game) }
        if credited {
            p += 1
            game.player.progress[Self.act] = p
            if p > 0, p < 9 { clicked = -1; game.say(25000 + (p + 1) / 2) }
            game.savePlayer()
            levelDone = p > 7
        }
        guard credited, p == 4 || p >= 8 else { nextRound(game); return }
        if level != 0 { for a in animals { a.anim = 0; a.visible = false } }
        startReward(game, progress: p)
    }

    /// Marks the round's group. The original then counts bits group×3…+2 of the
    /// same mask and sets all three when two are set (mixed index scales, kept as is).
    private func markUsed(_ game: Game) {
        var used = game.player.usedContent[Self.act]
        if !used.contains(group) { used.append(group) }
        let base = group * 3
        if (0..<3).filter({ used.contains(base + $0) }).count > 1 {
            for k in 0..<3 where !used.contains(base + k) { used.append(base + k) }
        }
        game.player.usedContent[Self.act] = used
    }

    // MARK: Rewards (states 0x24–0x2a, FUN_0042c03f / FUN_00428be0)

    private func startReward(_ game: Game, progress p: Int) {
        let idx: Int
        if level == 0 {
            idx = p < 8 ? min(3, (animals.first?.code ?? type * 10) / 10) : 4
        } else {
            idx = level * 4 + (p + 1) / 2
        }
        let line = game.random(4) < 2 ? 23192 : 23194
        run([1, line], .reward) { [unowned self] in
            playOnce = false
            target = 99
            redrawBig()
            animals = (rewards[safe: idx] ?? []).compactMap { r in
                guard let a = game.res.aseq(r.aseq) else { return nil }
                let an = Animal(Actor(a, x: r.x, y: r.y, step: 1), code: -1, tree: -1, visible: true)
                an.anim = 9
                return an
            }
            run([1, 30209], .song) { [unowned self] in rewardDone(game) }
        }
    }

    private func rewardDone(_ game: Game) {
        guard levelDone else { nextRound(game); return }
        switch level {
        case 0:
            if let a = game.res.aseq(11602), let d = trees[0].door { d.set(a, step: 1, x: 91, y: 177); trees[0].doorState = 2 }
        case 1:
            if let a = game.res.aseq(11603), let d = trees[1].door { d.set(a, step: 1, x: 534, y: 197); trees[1].doorState = 2 }
        case 2:
            if let a = game.res.aseq(11601) { bush?.set(a, step: 1) }
        default:
            finale = make(game, 11604, 0, 0)
        }
        finaleEnded = false
        run(doneScripts[at: level], .levelDone) { [unowned self] in phase = .levelDone }
    }

    /// The level-complete animation has reached its rest point.
    private func levelAnimDone(_ game: Game) -> Bool {
        switch level {
        case 0, 1: return trees[level].doorState != 2
        default:
            guard !finaleEnded, let a = level == 2 ? bush : finale else { return true }
            if a.advance() != .moved { finaleEnded = true }
            return finaleEnded
        }
    }

    private func finishLevel(_ game: Game) {
        phase = .leaving
        game.player.completeLevel(Self.act)
        game.savePlayer()
        game.change(to: MainMenuScene(greet: false),
                    sound: Self.exitSpeech[game.random(Self.exitSpeech.count)])
    }

    private func leave(_ game: Game) {
        phase = .leaving
        script = []
        game.change(to: ExteriorScene(.countingClub))
        game.playMusic(32007 + game.random(3), loop: false)
    }

    // MARK: Input (FUN_0042aed3 gate, FUN_0042b085 mouse, FUN_0042b90c keys)

    private func canAccept(_ game: Game) -> Bool {
        if phase == .script, scriptKind == .song || scriptKind == .levelDone {
            game.stopSpeech()   // skip the current line
            return false
        }
        if trees.contains(where: { $0.doorState == 2 }) || bushMode > 0 { return false }
        if phase == .waitCut { return false }
        if phase == .script {
            switch scriptKind {
            case .greeting:
                game.stopSpeech()
                return false
            case .intro:
                game.stopSpeech()
                script = []
                afterScript = nil
                hostIdle(game)
                prompt(game)
                return false
            case .prompt:
                game.stopSpeech()
                script = []
                afterScript = nil
                hostIdle(game)
                redrawAll()
                phase = .idle
                busy = false
            case .explain:
                game.stopSpeech()
                script = []
                afterScript = nil
                hostIdle(game)
                phase = .idle
                busy = false
            default: break
            }
        }
        return !busy
    }

    private func resetTimers() {
        idleTicks = 0
        fidgetTicks = 0
    }

    func click(_ game: Game, x: Int, y: Int) {
        if exitSign?.rect.contains(x, y) == true { leave(game); return }
        guard phase != .leaving else { return }
        guard canAccept(game) else { return }
        // Animals in the clearing: start or stop their own little act.
        for i in animals.indices.reversed() where animals[i].visible && animals[i].actor.rect.contains(x, y) {
            let a = animals[i]
            if a.anim != 0 { a.anim = 0; return }
            clicked = i
            a.anim = 2
            playOnce = false
            return
        }
        for (k, t) in trees.enumerated() {
            var r = union(t.door?.rect, t.sign?.rect)
            if t.doorState >= 2 { r = union(r, t.eyes?.rect) }
            guard r?.contains(x, y) == true else { continue }
            resetTimers()
            if t.doorState < 2 { clickClosedTree(game, k) } else { clickOpenTree(game, k) }
            return
        }
        if hostRect?.contains(x, y) == true { tellHost(game); return }
        if bigSign?.rect.contains(x, y) == true {
            if !numberToggle || !animals.isEmpty {
                numberToggle = true
                if target > 0, target < 11 { speak(game, Self.numbers[target]) { [unowned self] in phase = .idle } }
            } else {
                numberToggle = false
                if openHoldsTarget { checkOpenTree(game) } else { prompt(game) }
            }
            return
        }
        if let bush, bushMode == 0, hostAnim == 0, bush.rect.contains(x, y) {
            resetTimers()
            useBush(game)
            return
        }
        if meter?.rect.contains(x, y) == true {
            resetTimers()
            clicked = -1
            meterToggle.toggle()
            if game.player.keys[Self.act][level] { meterToggle = false }
            game.say((meterToggle ? 21117 : 21111) + level)
            return
        }
        if phase == .idle, animals.isEmpty {
            if openHoldsTarget {
                checkOpenTree(game)
            } else {
                Self.lastPrompt = 0x1A - (level == 3 ? 1 : 0)
                run(promptScripts[at: Self.lastPrompt], .prompt) { [unowned self] in phase = .idle }
            }
        }
    }

    private var openHoldsTarget: Bool { open >= 0 && level == 0 && trees[open].count == target }

    private var hostRect: Rect? { union(head?.rect, body?.rect) }

    private func union(_ a: Rect?, _ b: Rect?) -> Rect? {
        guard let a, a.w > 0 else { return b }
        guard let b, b.w > 0 else { return a }
        let x0 = min(a.x, b.x), y0 = min(a.y, b.y)
        return Rect(x: x0, y: y0, w: max(a.x + a.w, b.x + b.w) - x0, h: max(a.y + a.h, b.y + b.h) - y0)
    }

    private func clickClosedTree(_ game: Game, _ k: Int) {
        cursor = k
        let t = trees[k]
        if level == 0 {
            if open >= 0 {
                if keyPicked > 0, trees[open].count == target { checkOpenTree(game); return }
                resetDoor(game, open)
                open = -1
            }
            guard t.count == target else {
                // A wrong tree only says how many it holds, buzzes, and counts as a mistake.
                guard t.count >= 0 else { return }
                sayCount(game, t.count)
                buzz = 1
                wrong = t.count
                return
            }
            sayCount(game, t.count)
            for j in 0..<4 where j != k { trees[j].count = -1; redrawSign(j) }
        }
        openDoor(k)
    }

    private func openDoor(_ k: Int) {
        trees[k].doorState = 2
        buzz = 0
        open = k
        if target < 0 { target = 0; redrawAll() }   // level 3: the first tree reveals 0
    }

    private func clickOpenTree(_ game: Game, _ k: Int) {
        let t = trees[k]
        if level == 0, t.count != target {
            if open >= 0 { resetDoor(game, open); open = -1 }
            clicked = -1
            game.say(16550 + game.random(10))
            return
        }
        if t.count > 0 {
            open = k
            busy = true
            if level == 0 { takeOutAll(game) } else { takeOne(game) }
            return
        }
        resetDoor(game, k)
        open = -1
        if level != 0 { clicked = -1; game.say(16550 + game.random(10)) }
    }

    /// Host click / Enter: check the animals in the clearing, or re-prompt.
    private func tellHost(_ game: Game) {
        resetTimers()
        for a in animals { a.anim = 0; a.actor.step = 1 }
        if !animals.isEmpty { check(game); return }
        if open >= 0, level == 0 {
            if trees[open].count == target { checkOpenTree(game); return }
            buzz = 2
            wrong = trees[open].count
        }
        if buzz == 2 { wrongAnswer(game) } else { prompt(game) }
    }

    private func useBush(_ game: Game) {
        if animals.isEmpty { bushPeek(game, 11003 + game.random(2)) } else { bushMode = 1 }
    }

    func key(_ game: Game, _ key: Key) {
        switch key {
        case .escape: leave(game)
        case .enter:
            if phase != .leaving, canAccept(game) { tellHost(game) }
        case .tab:
            guard phase != .leaving, canAccept(game), level != 0, bushMode == 0, hostAnim == 0 else { return }
            useBush(game)
        case .space:
            guard phase != .leaving, canAccept(game), open >= 0 else { return }
            let t = trees[open]
            if t.count < 1 {
                resetDoor(game, open)
                if level == 0 {
                    if t.count >= 0 { sayCount(game, t.count) }
                    buzz = 1
                    wrong = t.count
                } else {
                    clicked = -1
                    game.say(16550 + game.random(10))
                }
                open = -1
                return
            }
            if level == 0 {
                guard t.doorState == 3 else { return }
                if t.count != target {
                    sayCount(game, t.count)
                    buzz = 1
                    wrong = t.count
                    return
                }
                takeOutAll(game)
            } else {
                takeOne(game)
            }
        case .left, .right, .up, .down:
            guard phase != .leaving, canAccept(game), level != 0 || animals.isEmpty else { return }
            if open >= 0 {
                if trees[open].doorState == 2 { return }
                if level == 0, keyPicked != 0 { checkOpenTree(game); return }
                resetDoor(game, open)
                open = -1
            }
            if key == .left || key == .right {
                cursor = cursor < 2 ? (cursor == 0 ? 1 : 0) : (cursor == 2 ? 3 : 2)
            } else {
                cursor = cursor == 0 || cursor == 2 ? (cursor == 0 ? 2 : 0) : (cursor == 1 ? 3 : 1)
            }
            guard trees[cursor].count >= 0 else { return }
            if level == 0, trees[cursor].count == target {
                sayCount(game, trees[cursor].count)
                keyPicked = -1
            }
            openDoor(cursor)
        case .char("1"):
            guard phase != .leaving, canAccept(game) else { return }
            if numberToggle, animals.isEmpty {
                numberToggle = false
                if open >= 0, level == 0 { checkOpenTree(game) } else { prompt(game) }
            } else if animals.count == target {
                prompt(game)
            } else {
                numberToggle = true
                if target > 0, target < 11 { speak(game, Self.numbers[target]) { [unowned self] in phase = .idle } }
            }
        default: break
        }
    }

    // MARK: Development checks

    fileprivate var debugReady: Bool {
        phase == .idle && !busy && !trees.contains { $0.doorState == 2 } && bushMode == 0
    }

    fileprivate func debugTreePoint(_ k: Int) -> (Int, Int)? {
        guard let r = trees[safe: k]?.door?.rect else { return nil }
        return (r.midX, r.midY)
    }

    fileprivate var debugHostPoint: (Int, Int)? { hostRect.map { ($0.midX, $0.midY) } }

    /// Trees to click for this round: the answer when `correct`, else a mistake.
    fileprivate func debugPlan(correct: Bool) -> [Int] {
        let counts = trees.map { max(0, $0.count) }
        switch level {
        case 0:
            if correct { return trees.indices.first { trees[$0].count == target }.map { [$0] } ?? [] }
            return trees.indices.first { trees[$0].count >= 0 && trees[$0].count != target }.map { [$0] } ?? []
        case 2:
            let goal = target - animals.count
            for mask in 1..<16 {
                let pick = (0..<4).filter { mask & (1 << $0) != 0 }
                let sum = pick.reduce(0) { $0 + counts[$1] }
                if (sum == goal) == correct, pick.allSatisfy({ counts[$0] > 0 }) { return pick }
            }
            return []
        default:
            // One click per animal; a miss takes one too few (or one too many).
            var need = level == 3 ? max(0, 1 - animals.count) : target - animals.count
            if !correct { need += need > 1 ? -1 : 1 }
            var plan: [Int] = [], left = counts
            for k in 0..<4 { while need > 0, left[k] > 0 { plan.append(k); left[k] -= 1; need -= 1 } }
            return plan
        }
    }

    fileprivate var debugLevel: Int { level }

    fileprivate var debugExcess: Bool {
        (level == 1 && animals.count > target) || (level == 2 && !animals.isEmpty)
    }
}

extension CountingClubScene: DebugDrivable {
    /// `solve` answers the current round correctly; `miss` makes a mistake
    /// (level 0: a wrong tree; levels 1–2: a wrong total, then tells the host).
    func debugCommand(_ game: Game, _ args: [String]) -> Bool {
        guard args.first == "solve" || args.first == "miss" else { return false }
        let correct = args[0] == "solve"
        func waitReady() -> Bool {
            for _ in 0..<3000 {
                if game.scene !== self { return false }
                if debugReady { return true }
                game.tick()
            }
            return false
        }
        guard waitReady() else { return true }
        // Too many out (levels 1–2): let the bush take them back first.
        for _ in 0..<20 where correct && debugExcess {
            game.keyDown(.tab)
            game.tick()
            guard waitReady() else { return true }
        }
        let plan = debugPlan(correct: correct)
        for k in plan {
            guard let p = debugTreePoint(k) else { continue }
            game.mouseDown(x: p.0, y: p.1)
            game.tick()
            guard waitReady() else { return true }
        }
        if debugLevel == 0 && !correct { return true }
        if let h = debugHostPoint { game.mouseDown(x: h.0, y: h.1) }
        game.tick()
        return true
    }
}

extension CountingClubScene {
    // MARK: Drawing

    func draw(_ game: Game, _ fb: Framebuffer) {
        if let s = bigSign {
            s.draw(fb)
            drawCentered(fb, bigText, font: bigFont, rect: s.rect, dy: 0x22)
        }
        for (k, t) in trees.enumerated() where level != 1 {
            guard let s = t.sign else { continue }
            s.draw(fb)
            drawCentered(fb, t.signText, font: signFont, rect: s.rect, dy: 0x13 + (k < 2 ? 3 : 0))
        }
        exitSign?.draw(fb)
        let earned = game.player.keys[Self.act][level]
        meter?.step = (earned ? 8 : min(8, game.player.progress[Self.act])) + 1
        meter?.draw(fb)
        if let smallFont {
            fb.drawText("Level \(level + 1)".macRoman, font: smallFont, x: 0x1E, y: 0x1A1, color: 0x84)
        }
        head?.draw(fb)
        body?.draw(fb)
        for (k, t) in trees.enumerated() {
            if eyesVisible(k) { t.eyes?.draw(fb) }
            t.door?.draw(fb)
        }
        for a in animals where a.visible { a.actor.draw(fb) }
        bush?.draw(fb)
        finale?.draw(fb)
    }

    private func drawCentered(_ fb: Framebuffer, _ text: String?, font: BitmapFont?, rect r: Rect, dy: Int) {
        guard let text, let font else { return }
        let b = text.macRoman
        fb.drawText(b, font: font, x: r.x + (r.w - font.width(of: b)) / 2, y: r.y + dy, color: 6)
    }
}

private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

private extension Array where Element == [Int] {
    subscript(at i: Int) -> [Int] { indices.contains(i) ? self[i] : [] }
}

/// Little-endian shorts and 0-terminated script tables from the EXE's DATA section.
private extension ExeTables {
    func s16(at va: Int) -> Int? { u32(at: va).map { Int(Int16(truncatingIfNeeded: $0 & 0xFFFF)) } }

    func shorts(at va: Int, count: Int) -> [Int] { (0..<count).compactMap { s16(at: va + 2 * $0) } }

    func script(at va: Int) -> [Int] {
        var out: [Int] = [], a = va
        while out.count < 64, let v = s16(at: a), v != 0 { out.append(v); a += 2 }
        return out
    }

    func scripts(at table: Int, count: Int) -> [[Int]] {
        (0..<count).map { i in u32(at: table + 4 * i).map { script(at: $0) } ?? [] }
    }
}
