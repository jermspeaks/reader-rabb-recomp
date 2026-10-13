import Foundation

/// Pattern Parade (RRPW32.EXE enter FUN_00427ea7, tick FUN_00425908, mouse
/// FUN_004272a6, key FUN_0042769e, exit FUN_0042787d; docs/game-logic.md §4.3).
///
/// A marching band stands in a line with empty spots (footprints). The child
/// picks band members from the group at the top and places them so the line
/// continues the pattern: same colour or instrument (level 0), alternating
/// colours or instruments (level 1), colour and instrument together (level 2),
/// anything at all (level 3, free play). When the line is full the band plays
/// it back; wrong members are carried off by balloon or UFO and may be placed
/// again. A round solved without a failed check advances the progress meter
/// (the band marches off at 4 and 8), and eight earn the level's key.
///
/// Band members are coded T*10+U (T 1 kangaroo, 2 fox, 3 brown bear, 4 pink
/// bear; U colour 1 blue … 5 yellow); in the content table the high byte
/// flags the blanks a member is valid for (0x80 first, 0x40 second, 0x20 third).
final class PatternParadeScene: Scene {
    private static let act = Activity.patternParade.rawValue

    // MARK: Data read from the user's RRPW32.EXE

    /// 100 rounds of 13 shorts (0x442fd0): type, 6 line cells (-1 unused,
    /// 0 blank), 6 group members (-1 unused).
    private var rows: [[Int]] = []
    /// Speech scripts (FUN_004252d8 format): intro 0x443a34, prompt 0x443b74, help 0x443ca0.
    private var introScripts: [[Int]] = []
    private var promptScripts: [[Int]] = []
    private var helpScripts: [[Int]] = []
    /// Idle-animation step sounds per animal (pointer table 0x443d50; pairs step, WAVE).
    private var idleSounds: [Int: [(step: Int, sound: Int)]] = [:]
    /// Per level: rounds, first row (0x443d94 / 0x443db4) and the used-content
    /// group size / threshold (0x443d6c, stride 12).
    private var roundCount = [44, 24, 16, 16]
    private var rowBase = [0, 44, 68, 84]
    private var usedGroup = [(4, 2), (6, 4), (1, 1), (1, 1)]
    private var exitSpeech = [21116, 21121, 21122, 21124, 21125, 21046, 21066]

    // MARK: Layout (FUN_00425013, tables 0x442ebc / 0x442ee0 / 0x442f3a)

    private static let groupPos: [[(x: Int, y: Int)]] = [
        [(168, 90), (248, 90), (328, 90), (408, 90)],
        [(248, 57), (340, 57), (202, 90), (294, 90), (386, 90)],
        [(217, 57), (309, 57), (401, 57), (168, 90), (260, 90), (352, 90)],
    ]
    private static let lineY = 328
    private static let hostPos = (x: 48, y: 242)
    private static let hostPoses = [5000, 5010, 5011]   // script codes 1–3 (0x443da2)
    /// Carried off after a failed check (0x442f5e level 0, 0x442f76 otherwise),
    /// per animal: offset from the member and the balloon / UFO ASEQ.
    private static let carriers: [[(dx: Int, dy: Int, aseq: Int)]] = [
        [(-133, -268, 6850), (-133, -268, 6850), (-234, -324, 7840), (-234, -324, 7840)],
        [(141, -266, 6340), (-133, -268, 6850), (-187, -305, 7350), (-234, -324, 7840)],
    ]
    /// Level-complete actors (0x442f8e): x, y, ASEQ.
    private static let finale: [(x: Int, y: Int, aseq: Int)] = [
        (596, 235, 5024), (424, 196, 5040), (40, -30, 5043), (40, -30, 5033), (415, 239, 5031), (415, 239, 5032),
    ]
    /// Sparkle / note over one player while the band plays (0x442fb2).
    private static let sparkles: [(dx: Int, dy: Int, aseq: Int)] = [(-10, 50, 5050), (-43, 20, 5051), (1, 30, 5052), (1, 30, 5052)]
    /// Sound offset per animal for member sounds (0x443daa).
    private static let family = [0, 3, 2, 0, 1]

    /// Member ASEQ offsets from 6121 + (T-1)*500 + (U-1).
    private enum Anim: Int {
        case standing = 0, group = 90, selected = 100, demo = 110, idle = 140, play = 200, march = 210, carried = 220
    }

    private final class Member {
        var code: Int
        /// DAT_00447f4e: 1 in the group, 2 selected, 0 placed, -1 gone, -2 dropping back.
        var state = 1
        /// DAT_00447f42: 0 still, 1 play once and hold, 2 play once and reset, 3 idle with sounds.
        var anim = 0
        var x: Int, y: Int
        let actor: Actor
        var special: Aseq?
        init(code: Int, x: Int, y: Int, actor: Actor) {
            self.code = code; self.x = x; self.y = y; self.actor = actor
        }
    }

    private final class Cell {
        var code: Int
        let x: Int
        var playing = false
        let actor: Actor
        init(code: Int, x: Int, actor: Actor) { self.code = code; self.x = x; self.actor = actor }
    }

    // MARK: State (FUN_00425908 DAT_00447ee8)

    private enum State: Int {
        case waitCut = -1, startIntro, intro, demo, prompt, toPlay, startHelp, help, play,
             check, checkAnim, pickCheckSpeech, checkSpeech, replay, replayDone, pickFeedback,
             feedback, evaluate, carryOff, dropStart, dropBack, celebrate, celebrating, roundOver
    }
    private var state = State.waitCut

    /// Short intro index (DAT_00447f68): the long one once, then a random short one.
    private static var introIndex = 0
    /// Last row picked per level band (DAT_00448214).
    private static var lastPick = -1

    private var level = 0
    private var groupQueue: [Int] = []       // level-0 group order (DAT_00447f84)
    private var pick = 0                     // DAT_00447f94
    private var type = 0                     // DAT_00447f12
    private var typeSpeech = 0               // DAT_00447f10 (script code 100)
    private var promptCycle = -1             // DAT_00447f66
    private var promptIndex = 0              // DAT_00447f64
    private var helpBase = 0                 // DAT_00447f6c
    private var helpCycle = -1               // DAT_00447f6e
    private var helpIndex = 0                // DAT_00447f6a
    private var given = 0                    // DAT_00447f16
    private var filled = 0                   // DAT_00447f18
    private var failedChecks = 0             // DAT_00447f72
    private var errors = 0                   // DAT_00447f70
    private var replayIndex = 0              // DAT_00447f14
    private var dropCount = 0                // DAT_00447f5c
    private var selected = -1                // DAT_00447f5a
    private var demoPair = (-1, -1)          // DAT_00447f5e / DAT_00447f60
    private var demoAseq: [Int: Aseq] = [:]
    private var fx = 0                       // DAT_00447ef0: 1 effects, 2 host loops, 3 host once
    private var celebrating = false          // DAT_00447eea
    private var checking = false             // DAT_00447eee
    private var march = false                // DAT_00447ef4
    private var marchLoops = 0               // DAT_00447ef2
    private var levelDone = false            // DAT_00447ed4
    private var marchSoundPlayed = false     // DAT_00447f62
    private var attentionToggle = 0          // DAT_00447e9c
    private var wiggleIndex = 0              // DAT_00447f80
    private var meterToggle = false          // DAT_00447f82

    private var script: [Int] = []
    private var scriptPos = 0
    private var scriptDelay = 0
    private var ticks = 0
    private var attentionTicks = 0
    private var hintTicks = 0

    private var members: [Member] = []
    private var cells: [Cell] = []
    private var effects: [Actor?] = Array(repeating: nil, count: 6)   // actor slots 13–18
    private var sparkle: Actor?                                         // actor slot 19
    private var host: Actor?
    private var meter: Actor?
    private var exitSign: Actor?
    private var font: BitmapFont?

    // ~116 ms ticks: 1 s wiggle, 10 s attention, 30 s hint (FUN_00425790).
    private static let wiggleTicks = 9, attentionLimit = 86, hintLimit = 259

    init() {}

    // MARK: Enter / exit (FUN_00427ea7, FUN_0042787d)

    func enter(_ game: Game) {
        if game.player.progress[Self.act] > 7 { game.player.completeLevel(Self.act) }
        level = min(3, game.player.level[Self.act])
        loadTables(game)
        game.setBackground(24408)
        font = game.res.font(1014)
        if let a = game.res.aseq(212) { exitSign = Actor(a, x: 550, y: 406, step: 1) }
        if let a = game.res.aseq(504) { meter = Actor(a, x: 0x27, y: 0x191, step: 1) }
        // Level-0 group queue: groups 0–7 with one of 0–4 swapped for 8, shuffled,
        // rotated so the first round is not a listening round.
        groupQueue = Array(0..<8)
        groupQueue[game.random(5)] = 8
        for i in 0..<8 { groupQueue.swapAt(i, game.random(8)) }
        while groupQueue[0] > 6 { groupQueue = Array(groupQueue[1...]) + [groupQueue[0]] }
        setupRound(game)
        createSprites(game)
        state = .waitCut
    }

    func exit(_ game: Game) {
        game.stopSpeech()
        game.savePlayer()
        Self.introIndex = game.random(3) + 1
    }

    private func loadTables(_ game: Game) {
        guard let exe = game.exe else { return }
        func s16(_ va: Int) -> Int? { exe.u32(at: va).map { Int(Int16(truncatingIfNeeded: $0)) } }
        func script(_ ptr: Int) -> [Int] {
            var out: [Int] = []
            var va = ptr
            while out.count < 40, let v = s16(va), v != 0 { out.append(v); va += 2 }
            return out
        }
        func scripts(_ table: Int, _ n: Int) -> [[Int]] {
            (0..<n).map { i in exe.u32(at: table + 4 * i).map(script) ?? [] }
        }
        rows = (0..<100).map { r in (0..<13).map { s16(0x442fd0 + 26 * r + 2 * $0) ?? -1 } }
        introScripts = scripts(0x443a34, 4)
        promptScripts = scripts(0x443b74, 22)
        helpScripts = scripts(0x443ca0, 23)
        for t in 1...4 {
            guard let p = exe.u32(at: 0x443d50 + 4 * t), p != 0 else { continue }
            var pairs: [(Int, Int)] = []
            var va = p
            while pairs.count < 16, let s = s16(va), s != 0, let w = s16(va + 2) { pairs.append((s, w)); va += 4 }
            idleSounds[t] = pairs
        }
        for l in 0..<4 {
            if let n = s16(0x443d94 + 2 * l) { roundCount[l] = n }
            if let b = s16(0x443db4 + 2 * l) { rowBase[l] = b }
            if let g = s16(0x443d6c + 12 * l), let t = s16(0x443d6e + 12 * l) { usedGroup[l] = (g, t) }
        }
        let ex = (0..<7).compactMap { s16(0x4439f8 + 2 * $0) }
        if ex.count == 7, ex.allSatisfy({ $0 > 0 }) { exitSpeech = ex }
    }

    // MARK: Rounds (FUN_004249bd, FUN_00431279, FUN_00425013)

    private func setupRound(_ game: Game) {
        if level == 0 {
            pick = game.random(4) + groupQueue[0] * 4
            // The original rotates through DAT_00447f92, which aliases the last
            // queue slot: the head moves to the back and the old tail is dropped.
            groupQueue[7] = groupQueue[0]
            groupQueue = Array(groupQueue[1...]) + [groupQueue[7]]
        } else {
            pick = pickUnused(game, roundCount[level])
        }
        let row = rows.indices.contains(pick + rowBase[level]) ? rows[pick + rowBase[level]]
            : [4, 24, 24, 0, -1, -1, -1, 0x8018, 0x15, 0x19, 0x16, -1, -1]
        type = row[0] & 0xFFFF
        var lineCodes: [Int] = []
        given = 0
        for v in row[1...6] where v != -1 {
            lineCodes.append(v & 0xFFFF)
            if v != 0 { given = lineCodes.count }
        }
        var groupCodes = row[7...12].filter { $0 != -1 }.map { $0 & 0xFFFF }
        for i in groupCodes.indices { groupCodes.swapAt(i, game.random(groupCodes.count)) }
        filled = given
        guard let blank = game.res.aseq(6120) else { members = []; cells = []; return }
        let pos = Self.groupPos[groupCodes.count >= 6 ? 2 : groupCodes.count == 5 ? 1 : 0]
        members = groupCodes.enumerated().map { i, c in
            let p = pos[min(i, pos.count - 1)]
            return Member(code: c, x: p.x, y: p.y, actor: Actor(blank, step: 1))
        }
        let n = lineCodes.count
        let spacing = n < 6 ? 0x5E : 0x54
        let start = n < 6 ? (6 - n) * 0x5E / 2 + 0x5E : 0x86
        cells = lineCodes.enumerated().map { i, c in
            Cell(code: i < given ? c : 0, x: start + i * spacing, actor: Actor(blank, step: 1))
        }
        checking = false
        celebrating = false
        // Prompt and help scripts cycle per level; level 0 depends on the pattern type.
        promptCycle += 1
        if promptCycle > [3, 1, 4, 5][level] { promptCycle = 0 }
        promptIndex = level * 2 + promptCycle + (level > 0 ? 2 : 0) + (level == 3 ? 3 : 0)
        helpCycle = -1
        helpBase = level * 4 + 6
        failedChecks = 0
        levelDone = false
        if level == 0 {
            if type > 0 && type < 6 { typeSpeech = 18099 + type; helpBase = 0 }
            if type == 0x10 { typeSpeech = 18106; helpBase = 8 }
            if type == 0x20 { typeSpeech = 18105; helpBase = 8 }
            if type == 0x40 { typeSpeech = 18107; promptIndex = 17 + game.random(2); helpBase = 2 }
            if type == 0x80 { typeSpeech = 18109; promptIndex = 17 + game.random(2); helpBase = 2 }
            if type & 0x100 != 0 {
                typeSpeech = (type & 7) * 2 + (type & 0x10 != 0 ? 1 : 0) + 8298
                promptIndex = 19 + game.random(3)
                helpBase = 4
            }
        }
        if level == 1 && type & 0x400 != 0 { helpBase += 2 }
    }

    /// FUN_00431279: random row not used yet (and not the last one); clears the
    /// used set once every row has been played.
    private func pickUnused(_ game: Game, _ count: Int) -> Int {
        var used = Set(game.player.usedContent[Self.act])
        var r = game.random(count)
        var tries = 0
        while tries < count + 2 {
            if r != Self.lastPick && !used.contains(r) { Self.lastPick = r; return r }
            Self.lastPick = -1
            r = (r + 1) % count
            tries += 1
        }
        used.removeAll()
        game.player.usedContent[Self.act] = []
        Self.lastPick = r
        return r
    }

    private func createSprites(_ game: Game) {
        for i in members.indices { showMember(game, i) }
        for i in cells.indices { showCell(game, i) }
        if let a = game.res.aseq(Self.hostPoses[0]) { host = Actor(a, x: Self.hostPos.x, y: Self.hostPos.y, step: 1) }
        fx = 0
        selected = -1
        effects = Array(repeating: nil, count: 6)
        sparkle = nil
    }

    // MARK: Sprites (FUN_00424734 / FUN_00427b36 / FUN_00427db7)

    private func memberAseq(_ game: Game, _ code: Int, _ anim: Anim) -> Aseq? {
        let c = code & 0xFF
        let b = (c / 10 - 1) * 500 + (c % 10 - 1)
        var id = 6121 + b + anim.rawValue
        if anim == .carried {
            // FUN_00427db7: cymbal players (and brown bears above level 0) use the second set.
            if c < 30 || (level != 0 && c < 40) { id += 10 }
        }
        // Level 3 swaps in alternate art for the red kangaroo and the blue fox.
        if level == 3, b == 3 || b == 500, let alt = game.res.aseq(id - 1000) { return alt }
        return game.res.aseq(id)
    }

    private func isBear(_ code: Int) -> Bool { code & 0xFF > 29 }

    /// FUN_004267f5: a group member in its current state.
    private func showMember(_ game: Game, _ i: Int) {
        let m = members[i]
        var x = m.x, y = m.y
        let aseq: Aseq?
        let step: Int
        if m.state < 1 {
            aseq = game.res.aseq(6100)      // coloured spot where the member stood
            x += 5; y += 77
            step = (m.code & 0xFF) % 10
        } else {
            aseq = m.state == 2 ? m.special : memberAseq(game, m.code, .group)
            if isBear(m.code) { y += 22 }
            step = m.state
        }
        if let aseq { m.actor.set(aseq, step: step, x: x, y: y) }
        m.actor.hidden = false
    }

    /// FUN_004268d5: a line cell standing still (footprints when empty).
    private func showCell(_ game: Game, _ i: Int) {
        let c = cells[i]
        var x = c.x, y = Self.lineY
        let aseq: Aseq?
        if c.code == 0 {
            aseq = game.res.aseq(6120)
        } else {
            aseq = memberAseq(game, c.code, .standing)
            if isBear(c.code) { x -= 20; y -= 83 } else { x -= 5; y -= 120 }
        }
        if let aseq { c.actor.set(aseq, step: 1, x: x, y: y) }
    }

    /// FUN_0042699b: a line member plays (march while celebrating a milestone).
    private func playCell(_ game: Game, _ i: Int) {
        let c = cells[i]
        if !celebrating { playMemberSound(game, c.code, listening: true) }
        guard celebrating || !c.playing else { return }
        c.playing = true
        let code = c.code & 0xFF
        guard (10..<0x31).contains(code), code != 29,
              let a = memberAseq(game, c.code, celebrating && march ? .march : .play) else { return }
        if isBear(c.code) {
            c.actor.set(a, step: 1, x: c.x - 0x14, y: Self.lineY - 0x53)
        } else {
            c.actor.set(a, step: 1, x: c.x - 0x21, y: Self.lineY - 0x78)
        }
    }

    /// FUN_00425430: a member's sound (instrument by animal and colour).
    private func playMemberSound(_ game: Game, _ code: Int, listening: Bool) {
        let c = code & 0xFF, t = c / 10, u = c % 10
        let fam = Self.family.indices.contains(t) ? Self.family[t] : 0
        var id = u * 4 + fam
        if type == 0x20 || type == 0x10 || type == 0x400 { id = fam }
        id += 9500
        if level == 2 {
            id = c < 30 ? u * 2 + (c < 20 ? 1 : 0) + 9532 : u * 2 + 9523 - (c < 40 ? 1 : 0)
        }
        if listening || level == 3 {
            id = u * 2 + (level == 3 ? 10 : 0) + (c < 30 ? 1 : 0) + 8298
        }
        game.say(id)
    }

    // MARK: Speech scripts (FUN_004252d8)

    private func startScript(_ s: [Int]) {
        script = s
        scriptPos = 0
        scriptDelay = 0
    }

    /// One step of the current script; true once it has finished.
    /// Codes: >3 speech (100 = the round's pattern word), 1–3 host pose, <0 delay.
    private func stepScript(_ game: Game) -> Bool {
        guard game.mouth == nil, !game.speechPlaying else { return false }
        if scriptDelay > 0 { scriptDelay -= 1; return false }
        guard scriptPos < script.count else { return true }
        let v = script[scriptPos]
        scriptPos += 1
        if v < 0 {
            scriptDelay = -v
        } else if v <= 3 {
            setPose(game, v - 1)
            if state == .prompt && v == 3 { startDemo(game) }
        } else {
            game.sayWithLips(v == 100 ? typeSpeech : v)
        }
        return false
    }

    /// FUN_0042528a: the drum major switches pose (lip-synced on the next line).
    private func setPose(_ game: Game, _ n: Int) {
        guard let a = game.res.aseq(Self.hostPoses[n]) else { return }
        host?.set(a, step: 1, x: Self.hostPos.x, y: Self.hostPos.y)
    }

    /// FUN_00425237: the drum major plays a gesture (fixed sprite slot ASEQ).
    private func hostGesture(_ game: Game, _ id: Int) {
        guard let a = game.res.aseq(id), let host else { return }
        host.set(a, step: 1)
    }

    private func startDemo(_ game: Game) {
        for i in [demoPair.1, demoPair.0] where members.indices.contains(i) {
            guard let a = demoAseq[i] else { continue }
            members[i].anim = 2
            members[i].actor.set(a, step: 1)
        }
    }

    // MARK: Tick (FUN_00425908)

    func tick(_ game: Game) {
        if state == .waitCut {
            if game.speechPlaying { return }
            state = .startIntro
        }
        ticks += 1
        if let m = game.mouth, let host { host.step = (m > 4 ? 0 : m) + 1 }
        if fx > 1, let host {
            var next = host.step + 1
            if (host.aseq.step(next)?.frame ?? -1) < 0 {
                next = 1
                if fx > 2 { fx = 0 }
            }
            host.step = next
        }
        // Every second one group member wiggles.
        if ticks % Self.wiggleTicks == 0, !members.isEmpty {
            wiggleIndex = (wiggleIndex + 1) % members.count
            let m = members[wiggleIndex]
            if m.anim == 0 && m.state == 1 { m.anim = 2 }
        }
        animateMembers(game)
        animateCells(game)
        if fx == 1 || celebrating { animateEffects(game) }
        if let s = sparkle {
            if s.hidden { sparkle = nil } else if (s.aseq.step(s.step + 1)?.frame ?? -1) < 0 { s.hidden = true } else { s.step += 1 }
        }
        if state != .play { attentionTicks = 0; hintTicks = 0 }
        runState(game)
    }

    private func animateMembers(_ game: Game) {
        for (i, m) in members.enumerated() where m.anim != 0 {
            let next = m.actor.step + 1
            if m.anim == 3, !game.speechPlaying, let s = idleSounds[(m.code & 0xFF) / 10]?.first(where: { $0.step == next }) {
                game.say(s.sound)
            }
            if (m.actor.aseq.step(next)?.frame ?? -1) < 0 {
                if m.anim > 1 { showMember(game, i) }
                m.anim = 0
            } else {
                m.actor.step = next
            }
        }
    }

    private func animateCells(_ game: Game) {
        var quiet = false
        for (i, c) in cells.enumerated() where c.code != 0 && c.playing {
            var next = c.actor.step + 1
            if (c.actor.aseq.step(next)?.frame ?? -1) < 0 {
                if !celebrating {
                    if game.mouth == nil && (state == .replay || state == .play) { quiet = true }
                    showCell(game, i)
                    c.playing = false
                    continue
                }
                if !march {
                    next = 1
                } else {
                    // March on: restart at step 3 with the origin moved so the walk continues.
                    next = 3
                    let last = i == cells.count - 1
                    let r = c.actor.rect
                    if last && r.x + r.w < 0 { marchLoops = 8 }
                    c.actor.x += (c.actor.aseq.step(c.actor.step)?.dx ?? 0) - (c.actor.aseq.step(2)?.dx ?? 0)
                    if last { marchLoops += 1 }
                }
            }
            c.actor.step = next
        }
        // When every member has finished playing, cut the sound short.
        if quiet && !members.contains(where: { $0.anim == 1 }) && !cells.contains(where: { $0.playing }) {
            game.stopSpeech()
        }
    }

    /// Balloons, UFOs and the level-complete show (actor slots 13–18).
    private func animateEffects(_ game: Game) {
        var done = 0
        for i in effects.indices {
            guard let a = effects[i] else { done += 1; continue }
            var next = a.step + 1
            if march && i == 0 {
                if next > 51 && !marchSoundPlayed && !game.speechPlaying {
                    let id = 16570 + game.random(3)
                    game.say(game.res.wave(id) != nil ? id : 16570)
                    marchSoundPlayed = true
                }
                if next > 91 { next = 81; a.x -= 52 }
            }
            if (a.aseq.step(next)?.frame ?? -1) < 0 {
                if !celebrating { effects[i] = nil; done += 1 }
            } else {
                a.step = next
                a.hidden = false
            }
        }
        if done == effects.count { fx = 0 }
    }

    private func runState(_ game: Game) {
        switch state {
        case .waitCut:
            break
        case .startIntro:
            startScript(introScripts.indices.contains(Self.introIndex) ? introScripts[Self.introIndex] : [])
            state = .intro
        case .intro:
            if stepScript(game) { state = .demo }
        case .demo:
            demoPair = (-1, -1)
            demoAseq = [:]
            if members.count >= 2 {
                let a = game.random(members.count)
                var b = game.random(members.count)
                while b == a { b = game.random(members.count) }
                demoPair = (a, b)
                demoAseq[a] = memberAseq(game, members[a].code, .demo)
                demoAseq[b] = memberAseq(game, members[b].code, .demo)
            }
            fx = 0
            startScript(promptScripts.indices.contains(promptIndex) ? promptScripts[promptIndex] : [])
            state = .prompt
        case .prompt:
            if stepScript(game) { state = .toPlay }
        case .toPlay:
            state = .play
        case .startHelp:
            helpCycle += 1
            if helpCycle > (level > 1 ? 1 : 0) + 1 { helpCycle = 0 }
            helpIndex = helpBase + helpCycle
            startHelp(helpIndex)
        case .help:
            if stepScript(game) { state = .play }
        case .play:
            idle(game)
            checking = false
        case .check:
            checking = true
            replayIndex = 0
            errors = 0
            hostGesture(game, 5002)
            fx = 3
            state = .checkAnim
        case .checkAnim:
            if host?.step == 6 { game.say(9200); state = .pickCheckSpeech }
        case .pickCheckSpeech:
            if !game.speechPlaying {
                fx = 0
                startScript([1, 18133 + game.random(3)])
                state = .checkSpeech
            }
        case .checkSpeech:
            if stepScript(game) { state = .replay }
        case .replay:
            replayStep(game)
        case .replayDone:
            state = .pickFeedback
        case .pickFeedback:
            if !game.speechPlaying {
                var id: Int
                if given == 0 || errors == 0 {
                    id = 18227 + game.random(10)
                } else {
                    let r = game.random(7)
                    id = 18247 + r
                    // 18249 talks about listening; other rounds skip it.
                    if id == 18249 && typeSpeech != 18107 && typeSpeech != 18109 { id = 18248 + r }
                }
                startScript([1, id])
                state = .feedback
            }
        case .feedback:
            if stepScript(game) { state = .evaluate }
        case .evaluate:
            evaluate(game)
        case .carryOff:
            if fx == 0 { state = dropCount == 0 ? .play : .dropStart }
        case .dropStart:
            for m in members where m.state == -2 {
                m.actor.hidden = false
                m.actor.y -= 100
            }
            dropCount = 0
            state = .dropBack
        case .dropBack:
            dropBack(game)
        case .celebrate:
            if !game.speechPlaying { celebrate(game) }
        case .celebrating:
            if !game.speechPlaying && (!march || marchLoops > 7) { state = .roundOver }
        case .roundOver:
            game.stopSpeech()
            if !levelDone {
                setupRound(game)
                createSprites(game)
                state = .demo
            } else {
                game.player.completeLevel(Self.act)
                game.savePlayer()
                state = .waitCut
                game.change(to: MainMenuScene(greet: false), sound: exitSpeech[game.random(exitSpeech.count)])
            }
        }
    }

    private func startHelp(_ index: Int) {
        startScript(helpScripts.indices.contains(index) ? helpScripts[index] : [])
        state = .help
    }

    /// FUN_00425790: 30 s without input repeats the hint; every 10 s the drum
    /// major or a group member does something to draw attention.
    private func idle(_ game: Game) {
        guard fx == 0 else { attentionTicks = 0; return }
        hintTicks += 1
        attentionTicks += 1
        if hintTicks >= Self.hintLimit {
            hintTicks = 0
            helpIndex = 22
            startHelp(22)
        } else if attentionTicks >= Self.attentionLimit {
            game.stopSpeech()
            attentionToggle = (attentionToggle + 1) % 2
            if attentionToggle == 0 {
                hostGesture(game, 5004)
                fx = 3
            } else if !members.isEmpty {
                var k = game.random(members.count)
                for _ in members.indices where members[k].state != 1 { k = (k + 1) % members.count }
                if members[k].state == 1, let a = memberAseq(game, members[k].code, .idle) {
                    members[k].anim = 3
                    members[k].actor.set(a, step: 1)
                    attentionTicks = 0
                }
            }
        }
    }

    /// FUN_00425540: the band plays back left to right; members in a blank
    /// without that blank's flag count as errors.
    private func replayStep(_ game: Game) {
        guard !game.speechPlaying else { return }
        guard replayIndex < cells.count else { state = .replayDone; return }
        let c = cells[replayIndex]
        let listening = type & 0x1C0 != 0
        if !listening && level != 3 {
            c.playing = true
        } else {
            celebrating = true
            playCell(game, replayIndex)
            celebrating = false
        }
        replayIndex += 1
        if given != 0 && given < replayIndex && Self.blankMask(replayIndex - given - 1) & c.code == 0 { errors += 1 }
        playMemberSound(game, c.code, listening: listening)
    }

    /// Valid-blank flag for blank k (table 0x442fc8 + 2).
    private static func blankMask(_ k: Int) -> Int { 0x8000 >> k }

    /// State 0x10: score a correct line, or send the wrong members away.
    private func evaluate(_ game: Game) {
        if given == 0 || errors == 0 {
            march = false
            if credit(game) {
                let p = incrementProgress(game)
                if p == 4 || p > 7 { march = true }
                if p > 7 { levelDone = true }
            }
            state = .celebrate
            return
        }
        effects = Array(repeating: nil, count: 6)
        dropCount = 0
        fx = 0
        var slot = 0
        for i in stride(from: cells.count - 1, through: given, by: -1) where Self.blankMask(i - given) & cells[i].code == 0 {
            carryOff(game, i, slot)
            slot += 2
            returnToGroup(game, i)
            cells[i].playing = false
        }
        game.say(9210)
        failedChecks += 1
        state = .carryOff
    }

    /// FUN_004248c4: a round counts if it had no failed check; marks the row used.
    private func credit(_ game: Game) -> Bool {
        guard failedChecks == 0 else { return false }
        let progress = game.player.progress[Self.act]
        var used = game.player.usedContent[Self.act]
        if !used.contains(pick) { used.append(pick) }
        let (size, threshold) = usedGroup[level]
        if size > 0 {
            let g = pick / size * size
            if used.filter({ $0 >= g && $0 < g + size }).count > threshold {
                used.removeAll { $0 >= g && $0 < g + size }
            }
        }
        game.player.usedContent[Self.act] = used
        return progress < 8
    }

    /// FUN_004247ab: progress + 1 with its chime.
    private func incrementProgress(_ game: Game) -> Int {
        let p = game.player.progress[Self.act] + 1
        game.player.progress[Self.act] = p
        game.savePlayer()
        if p > 0 && p < 9 { game.say(25000 + (p + 1) / 2) }
        return p
    }

    /// FUN_00425619: a balloon or UFO carries a wrong member off.
    private func carryOff(_ game: Game, _ i: Int, _ slot: Int) {
        let c = cells[i]
        let t = max(1, min(4, (c.code & 0xFF) / 10)) - 1
        let carrier = Self.carriers[level == 0 ? 0 : 1][t]
        if let a = game.res.aseq(carrier.aseq) {
            effects[slot] = Actor(a, x: c.actor.x + carrier.dx, y: c.actor.y + carrier.dy, step: 1)
        }
        if let a = memberAseq(game, c.code, .carried) {
            effects[slot + 1] = Actor(a, x: c.actor.x, y: c.actor.y, step: 1)
        }
        fx = 1
    }

    /// FUN_00426e41: the member goes back to the group (or away if it fits nowhere).
    private func returnToGroup(_ game: Game, _ i: Int) {
        guard given < filled else { return }
        let code = cells[i].code
        guard let k = members.indices.reversed().first(where: {
            members[$0].state == 0 && (members[$0].code & 0xFF) % 10 == (code & 0xFF) % 10
        }) else { return }
        filled -= 1
        let m = members[k]
        m.code = code
        cells[i].code = 0
        showCell(game, i)
        if (code >> 8) & 0xE0 == 0 {
            m.state = -1
        } else {
            m.state = 1
            showMember(game, k)
            dropCount += 1
            m.state = -2
        }
        m.actor.hidden = true
    }

    /// States 0x12–0x13: returned members drop back in, then the group hops.
    private func dropBack(_ game: Game) {
        dropCount += 1
        guard dropCount < 8 else {
            for (i, m) in members.enumerated() where m.state == -2 { m.state = 1; showMember(game, i) }
            state = .play
            return
        }
        var dy = 20
        if dropCount == 6 {
            dy = 0
            for (i, m) in members.enumerated() {
                if m.state == -2 { m.state = 1; showMember(game, i) } else if m.state == 1 { m.state = -2; dy = -2 }
            }
            if dy == 0 {
                dy = -2
                for m in members where m.state == 1 { m.state = -2 }
            }
        }
        if dropCount == 7 { dy = 2 }
        for m in members where m.state == -2 { m.actor.y += dy }
    }

    /// FUN_00426abc: the band plays (or marches off) to music.
    private func celebrate(_ game: Game) {
        effects = Array(repeating: nil, count: 6)
        if march {
            marchLoops = 0
            if levelDone {
                var shows: [(x: Int, y: Int, aseq: Int)]
                if level == 3 {
                    shows = [(0, -30, 5045), (0, -30, 5046)]
                } else {
                    let last = 5 - level
                    shows = Array(Self.finale[0..<(last == 3 ? 3 : 2)]) + [Self.finale[last]]
                }
                for (k, s) in shows.enumerated() {
                    guard let a = game.res.aseq(s.aseq) else { continue }
                    let actor = Actor(a, x: s.x, y: s.y, step: 1)
                    actor.hidden = true
                    effects[k] = actor
                }
            }
        }
        let cymbals = cells.filter { (10...28).contains($0.code & 0xFF) }.count
        let drums = cells.count - cymbals
        var music: Int
        if cymbals != 0 && drums != 0 {
            music = march ? [19106, 19107, 19108][game.random(3)] : [19101, 19100, 19104, 19103, 19102][game.random(5)]
        } else if cymbals == 0 {
            music = march ? 19112 : 19113 + game.random(2)
        } else {
            music = march ? 19105 : 19115 + game.random(2)
        }
        hostGesture(game, 5001)
        state = .celebrating
        fx = 2
        celebrating = true
        game.say(music)
        let sparkleAt = !levelDone && level != 3 ? game.random(cells.count) : -1
        for i in cells.indices {
            playCell(game, i)
            if i == sparkleAt {
                let s = Self.sparkles[game.random(2) + (isBear(cells[i].code) ? 2 : 0)]
                if let a = game.res.aseq(s.aseq) {
                    sparkle = Actor(a, x: cells[i].actor.x + s.dx, y: cells[i].actor.y + s.dy, step: 1)
                }
            }
        }
    }

    // MARK: Input (FUN_004272a6, FUN_0042769e)

    func click(_ game: Game, x: Int, y: Int) {
        if state == .waitCut { game.stopSpeech(); return }
        if exitSign?.rect.contains(x, y) == true { leave(game); return }
        if celebrating { state = .roundOver; return }
        if state == .intro {
            game.stopSpeech()
            script = []
            setPose(game, 0)
            state = .demo
            return
        }
        if state.rawValue < State.play.rawValue {
            game.stopSpeech()
            setPose(game, 0)
            state = .play
        }
        attentionTicks = 0
        hintTicks = 0
        guard !checking, state == .play else { return }
        var held = -1
        for i in members.indices.reversed() {
            let m = members[i]
            if m.state < 0 { continue }
            if m.state >= 1 {
                if m.state == 2 { held = i }
                guard m.actor.rect.contains(x, y) else { continue }
                if i != held { select(game, i) } else if filled < cells.count { place(game, held, 0) }
                return
            }
            guard grow(m.actor.rect).contains(x, y) else { continue }
            takeBack(game, i)
            return
        }
        for (i, c) in cells.enumerated() {
            if c.code == 0 {
                guard grow(c.actor.rect).contains(x, y) else { continue }
                if held >= 0 { place(game, held, i) } else { helpIndex = 22; startHelp(22) }
                return
            }
            if c.actor.rect.contains(x, y) { playCell(game, i); return }
        }
        if host?.rect.contains(x, y) == true { state = .startHelp; return }
        if meter?.rect.contains(x, y) == true {
            meterToggle.toggle()
            if game.player.keys[Self.act][level] { meterToggle = false }
            game.say((meterToggle ? 21117 : 21111) + level)
        }
    }

    private func grow(_ r: Rect) -> Rect { Rect(x: r.x - 5, y: r.y - 20, w: r.w + 10, h: r.h + 25) }

    func key(_ game: Game, _ key: Key) {
        if state == .waitCut { game.stopSpeech(); return }
        attentionTicks = 0
        hintTicks = 0
        switch key {
        case .escape:
            leave(game)
        case .enter:
            guard state == .play, let k = members.indices.reversed().first(where: { members[$0].state == 2 }),
                  filled < cells.count else { return }
            place(game, k, 0)
        case .space:
            guard state == .play, members.contains(where: { $0.state >= 1 }) else { return }
            repeat { selected = (selected + 1) % members.count } while members[selected].state < 1
            select(game, selected)
        case .char("1"):
            if state == .play { state = .startHelp }
        default:
            break
        }
    }

    /// FUN_00427146: pick up a group member (it steps forward and plays).
    private func select(_ game: Game, _ k: Int) {
        game.stopSpeech()
        for (i, m) in members.enumerated() where m.anim > 1 { showMember(game, i); m.anim = 0 }
        for (i, m) in members.enumerated() {
            if i == k {
                m.special = memberAseq(game, m.code, .selected)
                m.state = 2
                m.anim = 1
                playMemberSound(game, m.code, listening: true)
                showMember(game, i)
            } else if m.state == 2 {
                m.state = 1
                m.anim = 0
                showMember(game, i)
            }
        }
        selected = k
    }

    /// FUN_00427025: put the selected member on a footprint (the first free one if `cell` is taken).
    private func place(_ game: Game, _ k: Int, _ cell: Int) {
        game.stopSpeech()
        guard filled < cells.count else { return }
        let target = cells[cell].code == 0 ? cell : (given..<cells.count).first { cells[$0].code == 0 }
        guard let target else { return }
        let m = members[k]
        m.state = 0
        m.anim = 0
        cells[target].code = m.code
        showMember(game, k)
        showCell(game, target)
        if given + 1 == cells.count { m.actor.hidden = true }
        filled += 1
        if filled == cells.count { state = .check }
    }

    /// FUN_00426f5b: click a member's empty spot to take it back from the line.
    private func takeBack(_ game: Game, _ k: Int) {
        guard given < filled else { return }
        let m = members[k]
        guard let i = (given..<cells.count).reversed().first(where: {
            cells[$0].code != 0 && (cells[$0].code & 0xFF) % 10 == (m.code & 0xFF) % 10
        }) else { return }
        filled -= 1
        m.state = 1
        m.code = cells[i].code
        cells[i].code = 0
        cells[i].playing = false
        showCell(game, i)
        showMember(game, k)
    }

    /// FUN_0042727c: back to the exterior.
    private func leave(_ game: Game) {
        script = []
        game.change(to: ExteriorScene(.patternParade), sound: 32025 + game.random(2))
    }

    // MARK: Drawing (FUN_00424ea7 and the draw list built in the tick)

    func draw(_ game: Game, _ fb: Framebuffer) {
        exitSign?.draw(fb)
        let earned = game.player.keys[Self.act][level]
        meter?.step = (earned ? 8 : min(8, game.player.progress[Self.act])) + 1
        meter?.draw(fb)
        if let font { fb.drawText("Level \(level + 1)".macRoman, font: font, x: 0x27, y: 0x1A1, color: 10) }
        for m in members { m.actor.draw(fb) }
        host?.draw(fb)
        for c in cells { c.actor.draw(fb) }
        for e in effects { e?.draw(fb) }
        sparkle?.draw(fb)
    }

    // MARK: Development checks

    fileprivate var debugReady: Bool { state == .play && !checking }
    fileprivate var debugRoundOver: Bool { state == .celebrate || state == .celebrating || state == .roundOver }
    fileprivate var debugRejected: Bool { state == .carryOff }

    /// Members to place in each blank, valid (`correct`) or with at least one wrong.
    fileprivate func debugPlan(correct: Bool) -> [(member: Int, cell: Int)]? {
        let blanks = cells.indices.filter { cells[$0].code == 0 }
        let free = members.indices.filter { members[$0].state >= 1 }
        func valid(_ m: Int, _ c: Int) -> Bool { given == 0 || Self.blankMask(c - given) & members[m].code != 0 }
        var plan: [(Int, Int)] = []
        var used = Set<Int>()
        func search(_ b: Int, _ wrongYet: Bool) -> Bool {
            if b == blanks.count { return correct || wrongYet || given == 0 }
            for m in free where !used.contains(m) {
                let ok = valid(m, blanks[b])
                if correct && !ok { continue }
                used.insert(m); plan.append((m, blanks[b]))
                if search(b + 1, wrongYet || !ok) { return true }
                used.remove(m); plan.removeLast()
            }
            return false
        }
        return search(0, false) ? plan.map { (member: $0.0, cell: $0.1) } : nil
    }

    /// A point on member k not covered by a member drawn above it.
    fileprivate func debugMemberPoint(_ k: Int) -> (Int, Int)? {
        let r = members[k].actor.rect
        for y in stride(from: r.y + 4, to: r.y + r.h, by: 4) {
            for x in stride(from: r.x + 4, to: r.x + r.w, by: 4) {
                let covered = members.indices.contains { $0 > k && members[$0].state >= 1 && members[$0].actor.rect.contains(x, y) }
                if !covered { return (x, y) }
            }
        }
        return nil
    }

    fileprivate func debugCellPoint(_ i: Int) -> (Int, Int) {
        let r = cells[i].actor.rect
        return (r.midX, r.midY)
    }
}

extension PatternParadeScene: DebugDrivable {
    /// `solve` fills the line correctly and runs until the band celebrates;
    /// `miss` fills it with at least one wrong member and runs until they are carried off.
    func debugCommand(_ game: Game, _ args: [String]) -> Bool {
        if args.first == "state" {
            let a = Activity.patternParade.rawValue
            print("pattern parade: state=\(state) level=\(level) row=\(pick + rowBase[level]) type=0x\(String(type, radix: 16))",
                  "progress=\(game.player.progress[a]) keys=\(game.player.keys[a])")
            return true
        }
        guard args.first == "solve" || args.first == "miss" else { return false }
        let correct = args[0] == "solve"
        var waited = 0
        while !debugReady && waited < 3000 && game.scene === self { game.tick(); waited += 1 }
        guard debugReady, let plan = debugPlan(correct: correct) else { return true }
        for step in plan {
            guard let p = debugMemberPoint(step.member) else { continue }
            game.mouseDown(x: p.0, y: p.1)
            game.tick()
            let c = debugCellPoint(step.cell)
            game.mouseDown(x: c.0, y: c.1)
            game.tick()
        }
        waited = 0
        while !(correct ? debugRoundOver : debugRejected || debugReady) && waited < 3000 && game.scene === self {
            game.tick()
            waited += 1
        }
        return true
    }
}
