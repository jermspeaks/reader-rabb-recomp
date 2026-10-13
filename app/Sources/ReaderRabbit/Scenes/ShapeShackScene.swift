import Foundation

/// Shape Shack (RRPW32.EXE enter FUN_00424613, tick FUN_00421a6e, mouse
/// FUN_00423891, key FUN_00423cee, exit FUN_004243e3; docs/game-logic.md §4.2).
///
/// A monkey hosts a sorting game with two stacks of three crates. Levels 0–1:
/// the monkey hands over six toys one at a time and the child drops each on
/// the left or right stack (same picture as the sign at level 0, "belongs /
/// doesn't belong" to the sign's category at level 1). Levels 2–3: six toys
/// sit on a tray and the child moves them so each stack shares one property
/// (shape, colour, kind, legs or sound). Every finished round advances the
/// meter; eight earn the level's key.
final class ShapeShackScene: Scene {
    /// FUN_00421a6e calls FUN_004339a4(0x3c): 60 fps, but animation, speech and
    /// the state machine only advance on every 7th tick (DAT_00447e98).
    var fps: Int { 60 }

    // MARK: Data read from the user's RRPW32.EXE

    private var rows: [[Int]] = []           // 0x4424c0: 68 × [category, type, 6 items]
    private var rowCount: [Int] = []         // 0x442e08: rows per level
    private var rowBase: [Int] = []          // 0x442e10: first row per level
    private var itemNames: [Int] = []        // 0x442446: item name speech by object id
    private var itemSounds: [Int] = []       // 0x4423e8: item sound by object id (0 = none)
    private var groupSounds: [Int] = []      // 0x4424a2: sound by sound group (item bits 0xf00)
    private var categoryNames: [Int] = []    // 0x4423a6: category / label name speech
    private var categoryExtra: [Int] = []    // 0x442382: second word for listening categories 13–16
    private var labelPos: [[Int]] = []       // 0x4422b8: sign label (x, y, aseq) by label
    private var handover: [[Int]] = []       // 0x442150: where the monkey holds object id (x, y, –)
    private var groupLabels: [Int] = []      // 0x442900: 4 labels (groups A–D) per level 2–3 row
    private var rowHints: [Int] = []         // 0x4429f0: "stuck" hint per level 2–3 row
    private var masks: [Int] = []            // 0x442e74: group bits A–D
    private var animSlots: [Int] = []        // 0x442e5e: script anim 1–10 → sprite slot
    private var fidgets: [Int] = []          // 0x442e7c: idle fidget ASEQs
    private var orderMoves: [Int] = []       // 0x442e84: level-0 order list shuffle (count, base) pairs
    private var exitSpeech: [Int] = []       // 0x442a2c: level-complete goodbye
    private var exe: ExeTables?

    // MARK: Layout (FUN_004200c4; tables 0x44212c / 0x44213e / 0x442e18)

    private static let crateHome: [(x: Int, y: Int)] = [
        (79, 295), (99, 225), (79, 155), (467, 295), (447, 225), (467, 155),
    ]
    private static let signHome: [(x: Int, y: Int)] = [(88, 50), (436, 57)]
    /// Keyboard highlight frames: tray spots 0–5, left crates 6–8, right crates 9–11.
    private static let highlightSpots: [(x: Int, y: Int, slot: Int)] = [
        (205, 307, 11), (281, 307, 10), (351, 307, 12), (205, 377, 11), (281, 377, 10), (351, 377, 12),
        (97, 300, 13), (117, 230, 13), (97, 160, 13), (467, 300, 13), (447, 230, 13), (467, 160, 13),
    ]
    /// Levels 2–3 tray: spot k is centred at x 248 + 70·(k % 3), bottom 348 + 70·(k / 3).
    private static func trayPoint(_ k: Int) -> (x: Int, y: Int) { (248 + 70 * (k % 3), 348 + 70 * (k / 3)) }
    private static let hintCount = [7, 5, 6, 7]
    private static let hintBase = [0, 7, 12, 18]
    private static let rewardAseqs = [[15042, 15052], [15062, 15061], [15054, 15056, 15057, 15055], [15044, 15045]]

    // MARK: Sprites

    /// Sprite slots (DAT_00449528): 0–27 fixed (table 0x4420f4), 28–31 sign
    /// labels/exemplars, 32+2k / 33+2k item k (drop left / right), then extras.
    private var slots: [Aseq?] = []
    private var extrasStart = 0              // DAT_00447de8
    private var crates: [Actor] = []         // actors 0–5
    private var signs: [Actor?] = [nil, nil] // actors 6–7
    private var boxLid: Actor?               // actor 8
    private var box: Actor?                  // actor 9 (toy box; levels 2–3: show prop)
    private var pieces: [Actor?] = Array(repeating: nil, count: 6) // actors 10–15
    private var labels: [Actor?] = [nil, nil] // actors 16–17
    private var body: Actor?                 // DAT_00447dd8: monkey (talking part)
    private var upper: Actor?                // DAT_00447dd4: monkey arm / rope
    private var held: Actor?                 // DAT_00447ddc: toy the monkey holds (levels 0–1)
    private var bounce: Actor?               // actor 22: wrong toy thrown out
    private var bounceEnding = false
    private var trunks: [Actor] = []         // actors 25–26, redrawn over the bounce
    private var rewardActors: [Actor] = []   // actors 25–27 at the level-2 reward
    private var highlight: Actor?            // actor 24 (keyboard selection, levels 2–3)
    private var exitSign: Actor?
    private var meter: Actor?
    private var font: BitmapFont?

    // MARK: Game state (globals of the original noted alongside)

    private var level = 0                    // DAT_00447dc0
    private var row = 0                      // DAT_00447e6e (row within the level)
    private var round = 0
    /// [left exemplar/category, right exemplar/category, item 0 … item 5] (DAT_00447e3c).
    private var codes = [Int](repeating: 0, count: 8)
    private var cur = 0                      // DAT_00447e4c: item being handed over
    private var misses = 0                   // DAT_00447dea (written, never read: see afterRound)
    private var order: [Int] = []            // DAT_00447e7c: level-0 row order
    private var state = -1                   // DAT_00447de2
    private var savedState = 0x15            // DAT_00447de0
    private var busy = 1                     // DAT_00447de4: input blocked
    private var anim = 0                     // DAT_00447de6: monkey one-shot (2, 3 drop, 4, 5 fidget, 99 hold)
    private var sub = 0                      // DAT_00447e98
    private var frame = 0
    private var idleDeadline = 600           // DAT_00447e90 (in 60 fps ticks)
    private var fidgetOn = false             // DAT_00447da8
    private var fidgetIndex = 0              // DAT_00447e02
    private var blinkWait = 0                // DAT_00447e96
    private var lastSoundStep = -1

    // Speech scripts (FUN_004208e9)
    private var script: [Int] = []
    private var scriptPos = 0                // DAT_00447dce
    private var scriptDelay = 0              // DAT_00447dcc
    private var animNo = 0                   // DAT_00447dca
    private var upperLimit = 0               // DAT_00447dd2
    private var talking = false              // DAT_00447dd0
    private var lips: LipTrack?
    private var lipPos = 0

    // Speech slots patched into scripts
    private var leftLabel = 0                // DAT_00447e74
    private var rightLabel = 0               // DAT_00447e76
    private var leftGroupSound = 0           // DAT_00447e78
    private var rightGroupSound = 0          // DAT_00447e7a
    private var lastLabel = 0                // DAT_00447e70
    private var clickedGroupSound = 0        // DAT_00447e72
    private var sayWords = [0, 0]            // 0x442ba8
    private var oneLiner = 0                 // 0x442bb4
    private var promptWord = 24206           // 0x442ac4
    private var promptCategory = 100         // 0x442ac6
    private var rowHint = 24198              // 0x442c2a

    private var crateIntroDone = false       // DAT_00447dfc
    private var crateScript = 0              // DAT_00447df4
    private var instructionsGiven = false    // DAT_00447df0
    private var instructionScript = 1        // DAT_00447df6
    private var hintIndex = -1               // DAT_00447dfa
    private var progressNow = 0              // DAT_00447dc2
    private var levelDone = false            // DAT_00447dc4
    private var showVariant = 0              // DAT_00447e00 during the mid-level show

    // Levels 0–1 drop
    private var dropTarget = 0               // DAT_00447e0e (crate position)
    private var dropBox = (x1: 0, x2: 0, y2: 0) // DAT_00447e5a / e5e
    private var moveStep = 0                 // DAT_00447e50
    private var moveFrom = (0, 0), moveTo = (0, 0)

    // Levels 2–3 sorting
    private var traySlot = [Int?](repeating: nil, count: 6) // DAT_00447e30
    private var crateSlot = [Int?](repeating: nil, count: 6) // DAT_00447e20
    private var carried: Int?                // DAT_00447e64 > 0
    private var carriedOffset = (x: 0, y: 0)
    private var dragStart = (x: 0, y: 0)
    private var dragMoved = false
    private var selected = -1                // DAT_00447dfe
    private var cursor = -1                  // DAT_00447e00
    private var signAnim = [0, 0]            // DAT_00447e06
    private var signBase = [0, 0]            // DAT_00447e0a
    private var signHomeBottom = [0, 0]
    private var signShift = [0, 0]

    /// Session state reset at sign-in (FUN_00424715).
    private static var welcomeVariant = 0    // DAT_00447df2
    private static var showIndex = Int.random(in: 0..<8) // DAT_00447e04

    private var fallback: PlaceholderActivityScene?

    init() {}

    // MARK: Enter / exit (FUN_00424613 / FUN_004243e3)

    func enter(_ game: Game) {
        resGame = game
        guard let exe = game.exe else {
            fallback = PlaceholderActivityScene(.shapeShack)
            fallback?.enter(game)
            return
        }
        self.exe = exe
        loadTables(exe)
        let act = Activity.shapeShack.rawValue
        if game.player.progress[act] > 7 { game.player.completeLevel(act) }
        game.setBackground(25000)
        font = game.res.font(1014)
        slots = exe.shorts(at: 0x4420F4, count: 28).map { game.res.aseq($0) }
        extrasStart = 0
        if let a = slots[0] { exitSign = Actor(a, x: 550, y: 408) }
        if let a = slots[1] { meter = Actor(a, x: 39, y: 401) }
        // Level-0 order list: 0…19, nine rows moved to the end, then 9…18 shuffled.
        order = Array(0..<20)
        for i in stride(from: 0, to: orderMoves.count - 1, by: 2) {
            moveToEnd(game.random(orderMoves[i]) + orderMoves[i + 1])
        }
        for k in 9..<19 { order.swapAt(k, game.random(10) + 9) }
        setupRound(game)
        instructionsGiven = false
        state = -1
        buildActors()
    }

    func exit(_ game: Game) {
        game.savePlayer()
    }

    private func loadTables(_ exe: ExeTables) {
        rows = (0..<68).map { exe.shorts(at: 0x4424C0 + 16 * $0, count: 8) }
        rowCount = exe.shorts(at: 0x442E08, count: 4)
        rowBase = exe.shorts(at: 0x442E10, count: 4)
        itemNames = exe.shorts(at: 0x442446, count: 47)
        itemSounds = exe.shorts(at: 0x4423E8, count: 47)
        groupSounds = exe.shorts(at: 0x4424A2, count: 16)
        categoryNames = exe.shorts(at: 0x4423A6, count: 33)
        categoryExtra = exe.shorts(at: 0x442382, count: 17)
        labelPos = (0..<33).map { exe.shorts(at: 0x4422B8 + 6 * $0, count: 3) }
        handover = (0..<47).map { exe.shorts(at: 0x442150 + 6 * $0, count: 3) }
        groupLabels = exe.shorts(at: 0x442900, count: 120)
        rowHints = exe.shorts(at: 0x4429F0, count: 30)
        masks = exe.shorts(at: 0x442E74, count: 4).map { $0 & 0xFFFF }
        animSlots = exe.shorts(at: 0x442E5E, count: 11)
        fidgets = exe.shorts(at: 0x442E7C, count: 4)
        orderMoves = exe.shorts(at: 0x442E84, count: 18)
        exitSpeech = exe.shorts(at: 0x442A2C, count: 7)
    }

    /// FUN_0041f7d0(i, 19): the moved entry overwrites the last one first, so
    /// the list loses its old last entry (row 19 never reaches level 0).
    private func moveToEnd(_ i: Int) {
        guard order.indices.contains(i) else { return }
        order[19] = order[i]
        for k in i..<19 { order[k] = order[k + 1] }
    }

    private static func at<T>(_ a: [T], _ i: Int, _ d: T) -> T { a.indices.contains(i) ? a[i] : d }
    private func name(_ code: Int) -> Int { Self.at(itemNames, code & 0xFF, 0) }
    private func sound(_ code: Int) -> Int { Self.at(itemSounds, code & 0xFF, 0) }
    private func groupSound(_ code: Int) -> Int { Self.at(groupSounds, (code & 0xF00) >> 8, 0) }
    private func category(_ c: Int) -> Int { Self.at(categoryNames, c, 0) }
    private var rowKey: Int { row + (level == 3 ? 17 : 0) }

    // MARK: Rounds (FUN_0041f808)

    private func setupRound(_ game: Game) {
        let act = Activity.shapeShack.rawValue
        level = min(3, game.player.level[act])
        round += 1
        let used = Set(game.player.usedContent[act])
        let count = Self.at(rowCount, level, 1)
        if level == 0 {
            var tries = 0
            repeat {
                row = order[0]
                moveToEnd(0)
                tries += 1
            } while tries <= 20 && used.contains(row)
        } else {
            // FUN_00431279: random start, first unused row (all used: start over).
            let start = game.random(count)
            row = (0..<count).map { (start + $0) % count }.first { !used.contains($0) } ?? start
        }
        let r = Self.at(rows, Self.at(rowBase, level, 0) + row, [Int](repeating: 0, count: 8))
        for k in 2..<8 {
            codes[k] = r[k]
            if level < 2 || r[0] == -1 { codes[k] |= k < 5 ? 0x8000 : 0x4000 }
        }
        traySlot = (0..<6).map { $0 }
        crateSlot = Array(repeating: nil, count: 6)
        codes[0] = codes[2]
        codes[1] = codes[5]
        if level != 0 {
            codes[0] = r[0]
            codes[1] = r[0]
            if r[1] == -1 {
                leftLabel = category(r[0])
                rightLabel = leftLabel
            } else {
                leftLabel = groupSound(r[1])
                rightLabel = 24228
            }
        }
        // Two swaps between the halves so the order is mixed.
        let a = game.random(3) + 2
        codes.swapAt(a, game.random(3) + 5)
        var b = game.random(3) + 2
        while b == a { b = game.random(3) + 2 }
        codes.swapAt(b, game.random(3) + 5)
        loadItemSprites()
        cur = 0
        busy = 0
        anim = 0
        progressNow = 0
        levelDone = false
        crateIntroDone = false
        misses = 0
        carried = nil
        hintIndex = -1
        if level == 0 {
            leftLabel = name(codes[0])
            rightLabel = name(codes[1])
        }
        promptWord = Self.welcomeVariant == 0 ? 24206 : 24203 + game.random(4)
        if level < 2 { promptCategory = category(r[0]) }
        rowHint = Self.at(rowHints, rowKey, 24198)
    }

    /// FUN_004244c9: label/exemplar sprites (slots 28–31) and two per item.
    private func loadItemSprites() {
        slots.removeSubrange(min(28, slots.count)...)
        extrasStart = 0
        var labelIndex = rowKey * 4
        for k in 0..<8 {
            let c = codes[k]
            if c == -1 || c == -2 || c == -3 {
                for _ in 0..<2 {
                    let v = Self.at(groupLabels, labelIndex, 0)
                    slots.append(v == 0 ? nil : res?.aseq(16500 + v))
                    labelIndex += 1
                }
            } else if level == 1 && k < 2 {
                slots.append(res?.aseq(16500 + (c & 0xFF)))
                slots.append(res?.aseq(16500 + (c & 0xFF)))
            } else {
                slots.append(res?.aseq(16111 + 2 * (c & 0xFF)))
                slots.append(res?.aseq(16112 + 2 * (c & 0xFF)))
            }
        }
    }

    private weak var resGame: Game?
    private var res: ResourceStore? { resGame?.res }

    /// FUN_00424419 / FUN_00424459: replace the extra slots after the items.
    private func loadExtras(_ ids: [Int]) {
        if extrasStart > 0 { slots.removeSubrange(min(extrasStart, slots.count)...) }
        extrasStart = slots.count
        for id in ids { slots.append(res?.aseq(id)) }
    }

    private func slot(_ i: Int) -> Aseq? { i >= 0 && i < slots.count ? slots[i] : nil }
    private func fromEnd(_ k: Int) -> Int { slots.count - k }

    /// FUN_0041f737: a wrongly sorted toy goes to the back of the queue.
    private func requeue() {
        let p = cur + 2
        let c = codes[p], s0 = slot(2 * p + 28), s1 = slot(2 * p + 29)
        guard slots.count >= 44 else { return }
        for i in p..<7 {
            codes[i] = codes[i + 1]
            slots[2 * i + 28] = slots[2 * i + 30]
            slots[2 * i + 29] = slots[2 * i + 31]
        }
        codes[7] = c
        slots[42] = s0
        slots[43] = s1
    }

    /// FUN_004200c4: (re)build the actors for the current round.
    private func buildActors() {
        let a14 = slot(14), a15 = slot(15)
        body = a14.map { Actor($0, x: 295, y: 160) }
        upper = a15.map { Actor($0, x: 297, y: 53) }
        crates = Self.crateHome.enumerated().compactMap { k, p in
            slot(k < 3 ? 4 : 5).map { Actor($0, x: p.x, y: p.y) }
        }
        pieces = Array(repeating: nil, count: 6)
        if level > 1 {
            for k in 0..<6 {
                guard let a = slot(32 + 2 * k) else { continue }
                let it = Actor(a, step: 4)
                let p = Self.trayPoint(k)
                let r = it.rect
                place(it, left: p.x - r.w / 2, top: p.y - r.h)
                pieces[k] = it
            }
        }
        signs = [nil, nil]
        signShift = [0, 0]
        signAnim = [0, 0]
        if level < 2 {
            signs[0] = slot(2).map { Actor($0, x: 88, y: 50) }
            if level == 0 { signs[1] = slot(3).map { Actor($0, x: 436, y: 57) } }
        }
        boxLid = level < 2 ? slot(7).map { Actor($0, x: 243, y: 280) } : nil
        box = level < 2 ? slot(6).map { Actor($0, x: 237, y: 294) } : nil
        labels = [nil, nil]
        if level == 0 {
            for side in 0..<2 {
                guard let s = signs[side], let a = slot(28 + 2 * side) else { continue }
                let l = Actor(a, step: 4)
                let sr = s.rect, lr = l.rect
                place(l, left: (2 * sr.x + sr.w) / 2 - lr.w / 2, top: sr.y + sr.h - 20 - lr.h)
                labels[side] = l
            }
        } else if level == 1, let a = slot(28) {
            let p = Self.at(labelPos, codes[0], [0, 0, 0])
            labels[0] = Actor(a, x: p[0], y: p[1])
        }
        held = nil
        bounce = nil
        selected = -1
        cursor = -1
        highlight = nil
        rewardActors = []
        trunks = [slot(8), slot(9)].compactMap { $0.map { Actor($0, x: 0, y: 0) } }
        busy = 1
    }

    /// Move `a` so its current frame's top-left is (left, top).
    private func place(_ a: Actor, left: Int, top: Int) {
        let s = a.aseq.step(a.step)
        a.x = left - (s?.dx ?? 0)
        a.y = top - (s?.dy ?? 0)
    }

    private func frameAt(_ a: Actor, _ step: Int) -> Int { a.aseq.step(step)?.frame ?? -1 }

    // MARK: Monkey (FUN_0042058d / FUN_00420696)

    private func setBody(_ s: Int, x: Int, y: Int) {
        guard let a = slot(s) else { return }
        if let body { body.set(a, step: 1, x: x, y: y) } else { body = Actor(a, x: x, y: y) }
    }

    private var bodyX: Int { body?.rect.x ?? 295 }
    private var upperBottom: Int { upper.map { $0.rect.y + $0.rect.h } ?? 160 }

    /// FUN_0042058d: switch the monkey to slot `s` and advance the state.
    private func setMonkey(_ s: Int) {
        upperLimit = 0
        if s == 0xF || s == 0x10 {
            upper = slot(s).map { Actor($0, x: 297, y: 53) }
            setBody(14, x: 295, y: upperBottom)
        } else {
            upper = nil
            let x = s == 0x11 ? 295 : [0x1A, 0x12, 0x13].contains(s) ? 275 : bodyX
            setBody(s, x: x, y: 53)
        }
        state += 1
        anim = 0
    }

    /// FUN_00420696: monkey pose for a script animation (slot from table 0x442e5e).
    private func scriptAnim(_ s: Int) {
        anim = 0
        switch s {
        case 0xF, 0x10, 0x17, 0x18:
            upperLimit = s >= 0x17 ? 0x14 : 0
            upper = slot(s).map { Actor($0, x: 297, y: 53) }
            setBody(14, x: 295, y: upperBottom)
        case 0x14, 0x15:
            upperLimit = 5
            upper = slot(s).map { Actor($0, x: 297, y: 53) }
            setBody(0x16, x: 275, y: 172)
        case 0x16:
            upperLimit = 0
            upper = slot(20).map { Actor($0, x: 297, y: 53) }
            setBody(0x16, x: 275, y: 172)
        case 0x1A:
            upper = nil
            setBody(s, x: 275, y: 53)
        default:
            upper = nil
            setBody(s, x: bodyX, y: 53)
        }
        stopTalking()
    }

    private var idlePose: Int { level < 2 ? 0x1A : 0xF }

    // MARK: Speech (FUN_004208e9; lip sync FUN_00434f25 / FUN_00435051)

    private func runScript(_ s: [Int]) {
        script = s
        scriptPos = 0
        scriptDelay = 0
        animNo = 0
    }

    private func speak(_ game: Game, _ id: Int) {
        game.say(id)
        lips = game.res.lips(id)
        lipPos = 0
        talking = true
    }

    private func stopTalking() {
        talking = false
        lips = nil
    }

    /// One mouth value per logic tick; the monkey shows step mouth + 1.
    private func pollLips(_ game: Game) {
        guard talking else { return }
        var m = -1
        if let lips, lipPos < lips.mouth.count {
            m = lips.mouth[lipPos]
            lipPos += 1
        } else if game.speechPlaying {
            m = 0
        }
        if m < 0 { talking = false; m = 0 }
        if m > 8 { m = 0 }
        body?.step = m + 1
    }

    /// Script values: > 10 speech, < 0 delay, 1–10 monkey animation,
    /// 0x62/99 wait for the arm, 100/101 sign labels, 0x66–0x6a category words.
    private func stepScript(_ game: Game) {
        if animNo > 8, let b = body, frameAt(b, b.step + 1) >= 0 {
            b.step += 1
            return
        }
        if talking { return }
        if scriptDelay > 0 { scriptDelay -= 1; return }
        let v = scriptPos < script.count ? script[scriptPos] : 0
        if v == 0 {
            if animNo == 2 { setMonkey(0x1A) } else { state += 1 }
            return
        }
        if v < 0 {
            scriptDelay = -v
            scriptPos += 1
            return
        }
        let cat = codes[0]
        let item = codes[min(7, 2 + cur)]
        var id = v
        switch v {
        case 0x62:
            scriptPos += 1
            upperLimit = -1
            return
        case 99:
            if upperLimit > 0 { upperLimit = -1 }
            if upperLimit == 0 { scriptPos += 1 }
            return
        case 100: id = leftLabel
        case 101: id = rightLabel
        case 0x66, 0x67:
            let listening = (13...16).contains(cat)
            if v == 0x66 && listening {
                id = 24116
            } else {
                if v == 0x66 { scriptPos += 2 }
                if listening {
                    scriptPos += 2
                    id = Self.at(categoryExtra, cat, 0)
                } else if (17...21).contains(cat) {
                    id = 24116
                } else {
                    scriptPos += 2
                    id = leftLabel
                }
            }
        case 0x68:
            scriptPos += 1
            id = leftLabel
        case 0x69:
            id = name(item)
        case 0x6A:
            if item & 0xF00 == 0 {
                scriptPos += 1
                id = name(item)
            } else {
                id = groupSound(item)
            }
        default: break
        }
        if id < 1 || id > 10 {
            stopTalking()
            speak(game, id)
        } else {
            animNo = id
            scriptAnim(Self.at(animSlots, id, 0xF))
        }
        scriptPos += 1
    }

    private func pointerScript(_ table: Int, _ i: Int) -> [Int] {
        guard let exe, let p = exe.u32(at: table + 4 * i), p != 0 else { return [] }
        var s = exe.script(at: p)
        if p == 0x442C28, s.count > 1 { s[1] = rowHint }
        return s
    }

    /// Script buffer 0x442bb2: one animation, then the patched word.
    private func oneLinerScript() -> [Int] { [exe?.shorts(at: 0x442BB2, count: 1).first ?? 1, oneLiner] }

    /// FUN_00420d38: say a label or toy name when idle (states 0x29–0x2b).
    private func requestSay(_ word: Int) {
        sayWords = [word, 0]
        if state == 0x15 {
            savedState = state
            state = 0x29
        }
    }

    /// Frame-keyed sound table ((step, wave) pairs, FUN_00434e68).
    private func frameSounds(_ game: Game, _ table: Int, _ i: Int) {
        guard let exe, let p = exe.u32(at: table + 4 * i), let step = body?.step, step != lastSoundStep else { return }
        lastSoundStep = step
        let pairs = exe.script(at: p)
        for k in stride(from: 0, to: pairs.count - 1, by: 2) where pairs[k] == step {
            game.say(pairs[k + 1])
        }
    }

    // MARK: Tick (FUN_00421a6e)

    func tick(_ game: Game) {
        resGame = game
        if let fallback { fallback.tick(game); return }
        frame += 1
        if state < 0 {
            if game.speechPlaying { return }
            state = 0
        }
        sub += 1
        guard sub > 6 else { return }
        sub = 0
        blink(game)
        pollLips(game)
        slideSigns(game)
        animateUpper()
        animateMonkey()
        animateDrop(game)
        animateCrates()
        animateBounce(game)
        if state != 0x15 || carried != nil {
            idleDeadline = frame + 600
        }
        runState(game)
    }

    private func blink(_ game: Game) {
        guard !talking, let b = body, [14, 0x16, 0x1A].contains(where: { slot($0) === b.aseq }) else { return }
        var s = 1
        if blinkWait < 1 {
            if game.random(5) == 0 { blinkWait = 8; s = 2 }
        } else {
            blinkWait -= 1
        }
        b.step = s
    }

    /// Signs drop in 20 px per tick when a group forms, and lift out when it breaks.
    private func slideSigns(_ game: Game) {
        for side in 0..<2 where signAnim[side] != 0 {
            signAnim[side] += signAnim[side] > 0 ? -1 : 1
            signShift[side] = signBase[side] - signAnim[side] * 20 - signHomeBottom[side]
            if signAnim[side] == 0 && signBase[side] != 0 {
                var w = side == 0 ? leftLabel : rightLabel
                if w == 24116 { w = side == 0 ? leftGroupSound : rightGroupSound }
                requestSay(w)
            }
        }
    }

    private func animateUpper() {
        guard let u = upper, upperLimit != 0 else { return }
        let n = u.step + 1
        if n < upperLimit || upperLimit < 0 {
            if frameAt(u, n) < 0 { upperLimit = 0 } else { u.step = n }
        }
    }

    private func animateMonkey() {
        guard anim != 0, let b = body else { return }
        var n = b.step + 1
        if frameAt(b, n) < 0 {
            n = anim != 99 ? 1 : b.step
            anim = anim == 5 ? -1 : 0
        }
        b.step = n
        if anim == -1 {
            setMonkey(idlePose)
            state -= 1
        }
    }

    /// The handed-over toy plays its drop frames, then glides into the crate in 5 ticks.
    private func animateDrop(_ game: Game) {
        guard anim == 3, let h = held else { return }
        var n = h.step + 1
        if n == 2 { game.say(4412) }
        if frameAt(h, n) < 0 {
            if moveStep == 0 {
                let r = h.rect
                moveFrom = (h.x, h.y)
                moveTo = ((dropBox.x1 + dropBox.x2) / 2 - r.w / 2 + (h.x - r.x),
                          dropBox.y2 - (r.y + r.h) - 6 + h.y)
            }
            moveStep += 1
            if moveStep <= 5 {
                h.x = moveFrom.0 + (moveTo.0 - moveFrom.0) * moveStep / 5
                h.y = moveFrom.1 + (moveTo.1 - moveFrom.1) * moveStep / 5
            }
            n = h.step
        }
        h.step = n
    }

    /// Crates play their wobble (steps 2–7) or shake (8–13) and hold the last frame.
    private func animateCrates() {
        for c in crates {
            let n = c.step + 1
            if n != 2 && n != 8 && frameAt(c, n) >= 0 { c.step = n }
        }
    }

    private func animateBounce(_ game: Game) {
        guard state != 0x21, let b = bounce else { return }
        let n = b.step + 1
        if n == 13 { game.say(4411) }
        if frameAt(b, n) < 0 {
            if bounceEnding { bounce = nil } else { bounceEnding = true; b.hidden = true }
        } else {
            b.step = n
            if n == 15 { held = nil }
        }
    }

    private func runState(_ game: Game) {
        switch state {
        case 0:
            loadExtras([15150, 15151, 15152])
            runScript([])
            state = Self.welcomeVariant != 0 ? 2 : 1
            Self.welcomeVariant = game.random(2) + 1
            if state == 1 { runScript(pointerScript(0x442A58, Self.welcomeVariant)) }
        case 1, 3, 6, 8, 0xE, 0x11, 0x14, 0x1F, 0x26, 0x2A:
            stepScript(game)
        case 2:
            state = 3
            instructionScript = level + 1
            if level > 1 {
                if instructionsGiven {
                    setMonkey(0xF)
                    state = 0x15
                    break
                }
                instructionsGiven = true
                instructionScript = level == 3 ? 4 : 3
                loadExtras([15160, 15161, 15162])
            }
            runScript(pointerScript(0x442AA0, instructionScript))
        case 4:
            if level == 1 {
                state = 7
            } else if level == 0 {
                loadExtras([15022])
                setMonkey(fromEnd(1))
                anim = 4
            } else {
                setMonkey(0xF)
                state = 0x15
            }
        case 5:
            if anim == 0 {
                state = 6
                var s = pointerScript(0x442AE4, 1)
                if s.count > 2 { s[1] = promptWord; s[2] = promptCategory }
                runScript(s)
            }
        case 7:
            if codes[2] & 0xF00 == 0 {
                busy = 1
                state = 9
            } else {
                oneLiner = 24187
                runScript(oneLinerScript())
                state = 8
            }
        case 9:
            busy = 1
            setMonkey(0x11)
            anim = 2
            hintIndex = -1
        case 10:
            if body?.step == 1 {
                setMonkey(0x1A)
                let code = codes[2 + cur]
                let p = Self.at(handover, code & 0xFF, [300, 228, 1])
                held = slot(32 + 2 * cur).map { Actor($0, x: p[0], y: p[1]) }
            }
        case 0xB:
            if anim == 0 {
                let code = codes[2 + cur]
                let s = code & 0xF00 == 0 ? sound(code) : groupSound(code)
                if s != 0 { game.say(s) }
                state = 0xC
                busy = 0
            }
        case 0xC:
            if !game.speechPlaying {
                if crateScript < 0 { crateScript = -1 - crateScript }
                state = 0x15
                if cur == 0 && !crateIntroDone {
                    crateIntroDone = true
                    busy = 1
                    state = 0x13
                }
            }
        case 0xD:
            hintIndex += 1
            if hintIndex >= Self.hintCount[level] { hintIndex = 0 }
            runScript(pointerScript(0x442C38, Self.hintBase[level] + max(0, hintIndex)))
            state = 0xE
        case 0xF, 0x12:
            state = 0x15
        case 0x10:
            runScript(oneLinerScript())
            state = 0x11
        case 0x13:
            crateScript = game.random(3) + level * 3
            if level > 1 {
                loadExtras([15160, 15161, 15162])
                crateScript = 6
            }
            runScript(pointerScript(0x442B8C, crateScript))
            busy = 0
            state = 0x14
        case 0x15:
            idleTimer(game)
            busy = 0
        case 0x16:
            busy = 1
            if body?.step == 1 { setMonkey(0xF) }
        case 0x17:
            checkDrop(game)
        case 0x18:
            if bounce == nil {
                crates[dropTarget].step = 1
                requeue()
                held = nil
                crateScript = -1 - crateScript
                busy = 1
                state = 9
            }
        case 0x19:
            settleDrop(game)
        case 0x1A:
            cur += 1
            busy = 1
            if cur < 6 {
                crateScript = -1 - crateScript
                state = 9
            } else {
                state = 0x1D
            }
        case 0x1D:
            if !game.speechPlaying {
                afterRound(game)
                state = 0x1E
            }
        case 0x1E:
            if !game.speechPlaying {
                oneLiner = 24233 + game.random(5)
                runScript(oneLinerScript())
                state = 0x1F
            }
        case 0x20:
            if progressNow == 0 {
                setupRound(game)
                newRound(game)
            } else if progressNow == 4 {
                // Mid-level show (FUN_00424459 loads 15109, 15097+n, 15095/6).
                showVariant = game.random(2)
                Self.showIndex = (Self.showIndex + 1) % 8
                loadExtras([15109, 15097 + Self.showIndex, 15095 + showVariant])
                if level > 1 { box = slot(fromEnd(3)).map { Actor($0, x: 243, y: 280) } }
                state = 0x21
            } else {
                if levelDone && level == 3, let a = res?.aseq(15109) {
                    slots.append(a)
                    box = Actor(a, x: 243, y: 280)
                }
                state = 0x24
            }
        case 0x21:
            if level > 1, let b = box, frameAt(b, b.step + 1) >= 0 {
                if b.step + 1 == 2 { game.say(3073) }
                b.step += 1
                break
            }
            setMonkey(fromEnd(1))
            anim = 4
            busy = 1
            state = 0x22
        case 0x22:
            if body?.step == 2 { game.say(showVariant == 0 ? 3064 : 3065) }
            if anim == 0 {
                anim = 4
                busy = 1
                if let a = slot(fromEnd(2)), let b = body { b.set(a, step: 1) }
                lastSoundStep = -1
                state = 0x23
            }
        case 0x23:
            frameSounds(game, 0x442D90, Self.showIndex)
            if anim == 0 { setMonkey(0xF) }
        case 0x24:
            finishShow(game)
        case 0x25:
            if anim == 0 {
                state = 0x2C
                game.change(to: MainMenuScene(greet: false),
                            sound: Self.at(exitSpeech, game.random(7), 21116))
            } else {
                if level == 2 { rewardActors.forEach { $0.advance() } }
                frameSounds(game, 0x442D80, level)
            }
        case 0x27:
            if !game.speechPlaying && anim == 0 {
                state = level == 1 ? 7 : 5
                if level > 1 {
                    if !instructionsGiven {
                        instructionsGiven = true
                        busy = 1
                        state = 0x13
                    } else {
                        setMonkey(0xF)
                        state = 0x15
                    }
                }
            }
        case 0x28:
            if !game.speechPlaying { state = savedState }
        case 0x29:
            if sayWords[0] == 24228 {
                let extra = (13...16).contains(lastLabel) ? Self.at(categoryExtra, lastLabel, 0) : category(lastLabel)
                sayWords = [clickedGroupSound, extra]
            }
            scriptAnim(level < 2 ? 0x16 : 0xF)
            runScript(sayWords)
            state = 0x2A
        case 0x2B:
            state = savedState
            if level > 1 && bothFormed {
                busy = 1
                state = 0x1D
            }
        default:
            break
        }
    }

    /// FUN_00421998: after 10 s idle the monkey fidgets; after another 10 s, a hint.
    private func idleTimer(_ game: Game) {
        if anim != 0 {
            frameSounds(game, 0x442DC0, fidgetIndex)
            idleDeadline = frame + 600
            return
        }
        guard frame > idleDeadline else { return }
        fidgetOn.toggle()
        if fidgetOn {
            game.stopSpeech()
            fidgetIndex = game.random(2) + (level > 1 ? 2 : 0)
            loadExtras([Self.at(fidgets, fidgetIndex, 15516)])
            setMonkey(fromEnd(1))
            state -= 1
            anim = 5
            lastSoundStep = -1
        } else {
            state = 0xD
        }
    }

    /// FUN_0041fbd9: new arrangement (the original dissolves to it), then a one-liner.
    private func newRound(_ game: Game) {
        buildActors()
        oneLiner = 24136 + game.random(6)
        if oneLiner == 24138 { oneLiner = level < 2 ? 24143 : 24136 }
        runScript(oneLinerScript())
        state = 0x26
    }

    /// FUN_0041f69a + FUN_0041f581: credit the round and ring the progress chime.
    /// The original's "3 or more misses" check (0x41f6b8) is unreachable code,
    /// so every finished round counts.
    private func afterRound(_ game: Game) {
        let act = Activity.shapeShack.rawValue
        guard game.player.level[act] == level else { return }
        game.player.usedContent[act].append(row)
        guard game.player.progress[act] < 8 else { return }
        game.player.progress[act] += 1
        let p = game.player.progress[act]
        game.savePlayer()
        game.say(25000 + (p + 1) / 2)
        progressNow = p
        if p > 7 { levelDone = true }
    }

    /// State 0x24: next round, or the level reward and key (FUN_0041f538).
    private func finishShow(_ game: Game) {
        guard levelDone else {
            if progressNow != 0 { setupRound(game) }
            newRound(game)
            return
        }
        if level == 3, let b = box, frameAt(b, b.step + 1) >= 0 {
            if b.step + 1 == 2 { game.say(3073) }
            b.step += 1
            return
        }
        for id in Self.rewardAseqs[level] { slots.append(res?.aseq(id)) }
        setMonkey(fromEnd(1))
        switch level {
        case 0: upper = slot(fromEnd(2)).map { Actor($0, x: 329, y: 269) }
        case 2:
            upper = nil
            rewardActors = (1..<4).compactMap { k in slot(fromEnd(1 + k)).map { Actor($0, x: 0, y: 0) } }
        default: upper = slot(fromEnd(2)).map { Actor($0, x: 0, y: 0) }
        }
        upperLimit = 99
        anim = 99
        busy = 1
        lastSoundStep = -1
        let act = Activity.shapeShack.rawValue
        game.player.completeLevel(act)
        game.savePlayer()
        state = 0x25
    }

    // MARK: Levels 0–1: dropping the handed-over toy (FUN_00420d58)

    private func dropHeld(_ game: Game, _ p: Int) {
        guard let h = held, anim != 3 else { return }
        let base = p < 3 ? 0 : 3
        let dir = (p == 2 || p == 5) ? -1 : 1
        var t = p, tries = 0
        while pieces[t] != nil {
            tries += 1
            if tries > 2 {
                if level == 1 && p > 2 { return }
                if level == 0 {
                    let s = sound(codes[p > 2 ? 1 : 0])
                    if s != 0 { game.say(s); return }
                }
                requestSay(p < 3 ? leftLabel : rightLabel)
                return
            }
            t = base + (t - base + dir + 3) % 3
        }
        dropTarget = t
        let r = crates[t].rect
        dropBox = (r.x + (p < 3 ? 18 : 0), r.x + r.w - (p < 3 ? 0 : 18), r.y + r.h)
        if let a = slot(p < 3 ? 32 + 2 * cur : 33 + 2 * cur) { h.aseq = a }
        setMonkey(p < 3 ? 0x12 : 0x13)
        anim = 3
        moveStep = 0
        busy = 1
        state = 0x16
    }

    /// State 0x17: the 0x4000 bit says the toy belongs on the right.
    private func checkDrop(_ game: Game) {
        let right = codes[2 + cur] & 0x4000 != 0
        let onRight = dropTarget >= 3
        if right == onRight { state = 0x19; return }
        misses += 1
        loadExtras([onRight ? 15005 : 15006])
        state = 0x18
        let c = crates[dropTarget]
        c.step = 8
        let r = c.rect
        bounce = slot(fromEnd(1)).map { Actor($0, x: r.x + (onRight ? 0 : -0x45), y: r.y + 6) }
        bounceEnding = false
        game.say(4504)
    }

    /// State 0x19: the toy stays; filled crates line up (±10 px) and wobble.
    private func settleDrop(_ game: Game) {
        guard let h = held else { state = 0x1A; return }
        let t = dropTarget
        pieces[t] = h
        held = nil
        let dx = t % 2 == 1 ? -10 : 10
        h.x += dx
        crates[t].x += dx
        state = 0x1A
        if level == 1 && t >= 3 {
            crates[t].step = 1
        } else {
            game.say(3045 + t % 3)
            crates[t].step += 1
        }
    }

    // MARK: Levels 2–3: sorting from the tray (FUN_0042152b / FUN_00420bb9 / FUN_0042108c)

    private var bothFormed: Bool {
        crates.count == 6 && crates[0].x != Self.crateHome[0].x && crates[3].x != Self.crateHome[3].x
    }

    private func formed(_ side: Int) -> Bool { crates.count == 6 && crates[side * 3].x != Self.crateHome[side * 3].x }

    private func pick(_ game: Game, _ k: Int, x: Int, y: Int) {
        carried = k
        if let t = traySlot.firstIndex(of: k) { traySlot[t] = nil }
        for p in crateSlot.indices where crateSlot[p] == k { crateSlot[p] = nil }
        if let piece = pieces[k] {
            carriedOffset = (x - piece.x, y - piece.y)
        }
        dragStart = (x, y)
        dragMoved = false
        let code = codes[2 + k]
        var s = sound(code)
        if code & 0xF00 != 0 {
            clickedGroupSound = groupSound(code)
            s = clickedGroupSound
        }
        if s != 0 { game.say(s) }
    }

    /// Drop the carried toy at (x, y): onto a crate stack (first free crate from
    /// the one clicked) or a tray spot (next free one); otherwise back in place.
    private func drop(_ game: Game, x: Int, y: Int) {
        guard let k = carried, let it = pieces[k] else { carried = nil; return }
        let r = it.rect
        if let p = crates.indices.first(where: { crates[$0].rect.contains(r.x + 20, r.y + 20) }) {
            if crateSlot[p] == k { crateSlot[p] = nil }
        }
        if let p = crates.indices.first(where: { crates[$0].rect.contains(x, y) }) {
            let base = p < 3 ? 0 : 3
            let dir = (p == 2 || p == 5) ? -1 : 1
            var t = p
            for _ in 0..<3 {
                if crateSlot[t] == nil {
                    let c = crates[t].rect
                    let x1 = c.x + (p < 3 ? 18 : 0), x2 = c.x + c.w - (p < 3 ? 0 : 18)
                    place(it, left: (x1 + x2) / 2 - r.w / 2, top: c.y + c.h - 6 - r.h)
                    crateSlot[t] = k
                    carried = nil
                    dragMoved = false
                    checkGroups(game)
                    checkStuck()
                    return
                }
                t = base + (t - base + dir + 3) % 3
            }
            dropInPlace(k)
            checkGroups(game)
            return
        }
        for t in 0..<6 {
            let p = Self.trayPoint(t)
            guard Rect(x: p.x - 35, y: p.y - 65, w: 70, h: 70).contains(x, y) else { continue }
            var s = t
            while traySlot[s] != nil { s = (s + 1) % 6 }
            let q = Self.trayPoint(s)
            place(it, left: q.x - r.w / 2, top: q.y - r.h)
            traySlot[s] = k
            carried = nil
            dragMoved = false
            checkGroups(game)
            return
        }
        dropInPlace(k)
        checkGroups(game)
    }

    /// FUN_00420bb9: the toy stays where it is and joins the spot under it.
    private func dropInPlace(_ k: Int) {
        carried = nil
        dragMoved = false
        guard let r = pieces[k]?.rect else { return }
        let cx = r.x + 20, cy = r.y + 20
        for t in 0..<6 {
            let p = Self.trayPoint(t)
            if Rect(x: p.x - 30, y: p.y - 60, w: 60, h: 60).contains(cx, cy) { traySlot[t] = k; return }
        }
        if let p = crates.indices.first(where: { crates[$0].rect.contains(cx, cy) }) { crateSlot[p] = k }
    }

    /// Group number (1–4 mask A–D, 5 shared sound) of a full stack, or 0.
    private func groupOf(_ items: [Int]) -> (group: Int, sound: Int) {
        var counts = [0, 0, 0, 0, 0], g = 0, sg = 0
        for k in items.reversed() {
            let c = codes[2 + k] & 0xFFFF
            for m in 0..<min(4, masks.count) where c & masks[m] == masks[m] {
                counts[m] += 1
                if counts[m] == 3 { g = m + 1 }
            }
            if c & 0xF00 != 0 {
                if sg == 0 { sg = c & 0xF00 }
                if sg == c & 0xF00 {
                    counts[4] += 1
                    if counts[4] == 3 { g = 5 }
                }
            }
        }
        return (g, sg)
    }

    /// FUN_0042108c: a full stack sharing a group straightens up, chimes and its
    /// sign drops in with the group's label; a broken group lifts the sign away.
    private func checkGroups(_ game: Game) {
        for side in 0..<2 {
            let base = side * 3
            var g = 0, sg = 0
            let filled = (base..<base + 3).compactMap { crateSlot[$0] }
            if filled.count == 3 { (g, sg) = groupOf(filled) }
            if g == 0 {
                guard formed(side) else { continue }
                for p in base..<base + 3 { shiftCrate(p, formed: false) }
                if let s = signs[side] {
                    signs[side] = Actor(s.aseq, x: Self.signHome[side].x, y: Self.signHome[side].y, step: s.step)
                }
                signHomeBottom[side] = signs[side].map { $0.rect.y + $0.rect.h } ?? 0
                signAnim[side] = -5
                signBase[side] = 0
            } else if !formed(side) {
                for p in base..<base + 3 { shiftCrate(p, formed: true) }
                game.say(4503)
                let label = g == 5 ? 7 : Self.at(groupLabels, rowKey * 4 + g - 1, 7)
                lastLabel = label
                if side == 0 {
                    leftLabel = category(label)
                    if sg != 0 { leftGroupSound = groupSound(sg) }
                } else {
                    rightLabel = category(label)
                    if sg != 0 { rightGroupSound = groupSound(sg) }
                }
                let step = (24...27).contains(label) ? label - 22 : 1
                signs[side] = slot(2 + side).map {
                    Actor($0, x: Self.signHome[side].x, y: Self.signHome[side].y, step: step)
                }
                let bottom = signs[side].map { $0.rect.y + $0.rect.h } ?? 0
                signHomeBottom[side] = bottom
                signAnim[side] = 5
                signBase[side] = bottom
                signShift[side] = -bottom
                if step == 1 {
                    let p = Self.at(labelPos, label, [0, 0, 0])
                    labels[side] = slot(g == 5 ? 27 : 27 + g).map {
                        Actor($0, x: p[0] + (side == 1 ? 0x15C : 0), y: p[1])
                    }
                } else {
                    labels[side] = nil
                }
            }
        }
    }

    /// FUN_00420f1b: stack crates zig-zag; a formed group lines them up.
    private func shiftCrate(_ p: Int, formed: Bool) {
        let odd = p % 2 == 1
        let dx = (odd == formed) ? -10 : 10
        crates[p].x += dx
        if let k = crateSlot[p] { pieces[k]?.x += dx }
    }

    /// FUN_00420fee: every toy is in a crate but no group formed: row hint.
    private func checkStuck() {
        guard !formed(0), !formed(1), traySlot.allSatisfy({ $0 == nil }) else { return }
        oneLiner = rowHint
        state = 0x10
        if hintIndex < 0 { hintIndex = 0 }
    }

    // MARK: Input (FUN_004236ac / FUN_00423891 / FUN_00423cee)

    /// FUN_004236ac: input interrupts speech and scripts; true if the child may act.
    private func canInteract(_ game: Game) -> Bool {
        if anim == 3 { return false }
        if state > 0x27 {
            stopTalking()
            game.stopSpeech()
            setMonkey(idlePose)
            state = savedState
            if level > 1 && bothFormed {
                busy = 1
                state = 0x1D
                return false
            }
        }
        if (state == 0xB && anim == 0) || state == 0xC {
            stopTalking()
            game.stopSpeech()
            setMonkey(idlePose)
            if crateScript < 0 { crateScript = -1 - crateScript }
            state = 0x15
            busy = 0
        }
        if [1, 3, 6, 0x26].contains(state) {
            stopTalking()
            game.stopSpeech()
            setMonkey(0xF)
            return false
        }
        if state == 0x14 || state == 0xE {
            stopTalking()
            game.stopSpeech()
            setMonkey(idlePose)
            state = 0x15
            busy = 0
        }
        return busy == 0
    }

    func click(_ game: Game, x: Int, y: Int) {
        resGame = game
        if let fallback { fallback.click(game, x: x, y: y); return }
        if state < 0 { game.stopSpeech(); return }
        if exitSign?.rect.contains(x, y) == true { leave(game); return }
        idleDeadline = frame + 600
        guard canInteract(game) else { return }
        if level > 1 {
            if bothFormed { return }
            if selected >= 0 { hideHighlight() }
            if carried != nil { drop(game, x: x, y: y); return }
            for k in 0..<6 where pieces[k]?.rect.contains(x, y) == true {
                pick(game, k, x: x, y: y)
                return
            }
        }
        if held != nil || level > 1 {
            for side in 0..<2 where labels[side].map({ shifted($0.rect, signShift[side]) })?.contains(x, y) == true {
                var w = side == 0 ? leftLabel : rightLabel
                if w == 24116 { w = side == 0 ? leftGroupSound : rightGroupSound }
                requestSay(w)
                return
            }
            if let p = crates.indices.first(where: { crates[$0].rect.contains(x, y) }) {
                if level < 2 { dropHeld(game, p) }
                return
            }
        }
        if let h = held, h.rect.contains(x, y) {
            let code = codes[2 + cur]
            var w = code & 0xF00 == 0 ? sound(code) : groupSound(code)
            if code & 0xF00 == 0 && w == 0 { w = name(code) }
            requestSay(w)
            return
        }
        if monkeyContains(x, y) {
            state = state == 0x1A ? 0x24 : 0xD
            return
        }
        if meter?.rect.contains(x, y) == true {
            meterTalk.toggle()
            let act = Activity.shapeShack.rawValue
            if game.player.keys[act][level] { meterTalk = false }
            game.say(meterTalk ? 21117 + level : 21111 + level)
        }
    }

    func mouseMoved(_ game: Game, x: Int, y: Int) {
        guard let carried, let piece = pieces[carried] else { return }
        dragMoved = dragMoved || x != dragStart.x || y != dragStart.y
        piece.x = x - carriedOffset.x
        piece.y = y - carriedOffset.y
    }

    func mouseUp(_ game: Game, x: Int, y: Int) {
        guard carried != nil, dragMoved else { return }
        drop(game, x: x, y: y)
    }

    private var meterTalk = false            // DAT_00447e94

    private func monkeyContains(_ x: Int, _ y: Int) -> Bool {
        guard let b = body?.rect else { return false }
        var r = b
        if let u = upper?.rect, u.w > 0 {
            let x1 = min(r.x, u.x), y1 = min(r.y, u.y)
            r = Rect(x: x1, y: y1, w: max(r.x + r.w, u.x + u.w) - x1, h: max(r.y + r.h, u.y + u.h) - y1)
        }
        return r.contains(x, y)
    }

    func key(_ game: Game, _ key: Key) {
        resGame = game
        if let fallback { fallback.key(game, key); return }
        if state < 0 { game.stopSpeech(); return }
        idleDeadline = frame + 600
        switch key {
        case .escape:
            leave(game)
        case .left, .right:
            guard canInteract(game), state == 0x15 else { return }
            let side = key == .left ? 0 : 3
            if level < 2 {
                dropHeld(game, side)
            } else if selected >= 0, (side..<side + 3).contains(where: { crateSlot[$0] == nil }) {
                carried = selected
                if let t = traySlot.firstIndex(of: selected) { traySlot[t] = nil }
                let r = crates[side].rect
                drop(game, x: r.x, y: r.y)
                hideHighlight()
            }
        case .down:
            guard canInteract(game), state == 0x15, level > 1, selected >= 0, cursor > 5 else { return }
            carried = selected
            drop(game, x: 248, y: 348)
            hideHighlight()
        case .space:
            guard canInteract(game), state == 0x15 else { return }
            if level < 2 {
                if held != nil {
                    let code = codes[2 + cur]
                    requestSay(code & 0xF00 == 0 ? name(code) : groupSound(code))
                }
            } else if carried == nil {
                cycleHighlight(game)
            }
        case .char("1"):
            if canInteract(game), state == 0x15 { state = 0xD }
        default:
            break
        }
    }

    /// Space at levels 2–3: select the next toy (tray spots, then crates top-down).
    private func cycleHighlight(_ game: Game) {
        for _ in 0..<7 {
            cursor = (cursor + 1) % 12
            let k: Int?
            if cursor < 6 { k = traySlot[cursor] } else if cursor < 9 { k = crateSlot[8 - cursor] } else { k = crateSlot[14 - cursor] }
            if let k { selected = k; break }
        }
        guard selected >= 0, let r = pieces[selected]?.rect else { return }
        let cx = r.x + r.w / 2, cy = r.y + r.h / 2
        let spot = Self.highlightSpots.indices.first {
            let s = Self.highlightSpots[$0]
            return cx >= s.x && cx <= s.x + 70 && cy >= s.y && cy <= s.y + 70
        } ?? 0
        var hx = Self.highlightSpots[spot].x
        if (6...8).contains(spot), formed(0) { hx = crates[0].x + 0x12 }
        if spot > 8, formed(1) { hx = crates[3].x }
        highlight = slot(Self.highlightSpots[spot].slot).map { Actor($0, x: hx, y: Self.highlightSpots[spot].y) }
        let code = codes[2 + selected]
        let s = code & 0xF00 == 0 ? sound(code) : groupSound(code)
        if s != 0 { game.say(s) }
    }

    private func hideHighlight() {
        highlight = nil
        selected = -1
        cursor = -1
    }

    /// FUN_00423867: back to the exterior with one of three tunes.
    private func leave(_ game: Game) {
        state = 0x2C
        game.change(to: ExteriorScene(.shapeShack), sound: 32033 + game.random(3))
    }

    // MARK: Drawing (draw list built in FUN_00421a6e; HUD FUN_0041fc89)

    func draw(_ game: Game, _ fb: Framebuffer) {
        if let fallback { fallback.draw(game, fb); return }
        exitSign?.draw(fb)
        let act = Activity.shapeShack.rawValue
        meter?.step = (game.player.keys[act][level] ? 8 : min(8, game.player.progress[act])) + 1
        meter?.draw(fb)
        if let font {
            fb.drawText("Level \(level + 1)".macRoman, font: font, x: 0x27, y: 0x1A1, color: 0x76)
        }
        crates.forEach { $0.draw(fb) }
        for side in 0..<2 { drawShifted(signs[side], signShift[side], fb) }
        boxLid?.draw(fb)
        box?.draw(fb)
        highlight?.draw(fb)
        for (k, p) in pieces.enumerated() { drawShifted(p, k == carried ? -6 : 0, fb) }
        for side in 0..<2 { drawShifted(labels[side], signShift[side], fb) }
        body?.draw(fb)
        upper?.draw(fb)
        held?.draw(fb)
        if let b = bounce, !b.hidden {
            b.draw(fb)
            // FUN_0041fd3d: the tree trunks are redrawn over it, clipped to its rect.
            let clip = b.rect
            for t in trunks {
                guard let s = t.sprite else { continue }
                let r = t.rect
                let x1 = max(r.x, clip.x), y1 = max(r.y, clip.y)
                let x2 = min(r.x + r.w, clip.x + clip.w), y2 = min(r.y + r.h, clip.y + clip.h)
                guard x2 > x1, y2 > y1 else { continue }
                fb.draw(s.crop(x: x1 - r.x, y: y1 - r.y, w: x2 - x1, h: y2 - y1), x: x1, y: y1)
            }
        }
        if state == 0x25 { rewardActors.forEach { $0.draw(fb) } }
    }

    private func shifted(_ r: Rect, _ dy: Int) -> Rect { Rect(x: r.x, y: r.y + dy, w: r.w, h: r.h) }

    private func drawShifted(_ a: Actor?, _ dy: Int, _ fb: Framebuffer) {
        guard let a else { return }
        a.y += dy
        a.draw(fb)
        a.y -= dy
    }
}

private extension Sprite {
    func crop(x: Int, y: Int, w: Int, h: Int) -> Sprite {
        var px = [UInt8](), op = [Bool]()
        px.reserveCapacity(w * h)
        op.reserveCapacity(w * h)
        for row in y..<y + h {
            px += pixels[(row * width + x)..<(row * width + x + w)]
            op += opaque[(row * width + x)..<(row * width + x + w)]
        }
        return Sprite(width: w, height: h, pixels: px, opaque: op)
    }
}

private extension ExeTables {
    /// `count` signed 16-bit values at `va`.
    func shorts(at va: Int, count: Int) -> [Int] {
        (0..<count).map { i in u32(at: va + 2 * i).map { Int(Int16(truncatingIfNeeded: $0)) } ?? 0 }
    }

    /// A 0-terminated script of signed 16-bit values.
    func script(at va: Int) -> [Int] {
        var out: [Int] = []
        for i in 0..<64 {
            let v = shorts(at: va + 2 * i, count: 1)[0]
            if v == 0 { break }
            out.append(v)
        }
        return out
    }
}

// MARK: Development checks

extension ShapeShackScene: DebugDrivable {
    /// `solve` finishes the current round correctly; `miss` makes one wrong move
    /// (levels 0–1: the toy goes on the wrong stack; levels 2–3: a toy goes to
    /// the stack it does not belong to). `ss` prints the scene state.
    func debugCommand(_ game: Game, _ args: [String]) -> Bool {
        guard let cmd = args.first else { return false }
        switch cmd {
        case "solve", "miss":
            guard waitReady(game) else { return true }
            let start = round
            for _ in 0..<12 {
                if level < 2 {
                    guard let p = debugCrate(correct: cmd == "solve") else { break }
                    tap(game, crates[p].rect)
                } else if !debugSortStep(game, wrong: cmd == "miss") {
                    break
                }
                for _ in 0..<14 { game.tick() }
                if cmd == "miss" || round != start || (0x1D...0x25).contains(state) { break }
                guard waitReady(game), round == start else { break }
            }
            return true
        case "ss":
            print("shape shack: level \(level) row \(row) state \(state) item \(cur) misses \(misses)",
                  "progress \(game.player.progress[Activity.shapeShack.rawValue])",
                  "codes \(codes.map { String($0 & 0xFFFF, radix: 16) })")
            return true
        default:
            return false
        }
    }

    private var ready: Bool {
        state == 0x15 && busy == 0 && anim != 3 && carried == nil && (level > 1 || held != nil)
    }

    private func waitReady(_ game: Game) -> Bool {
        for _ in 0..<30000 {
            if ready { return true }
            game.tick()
            if !(game.scene === self) { return false }
        }
        return false
    }

    private func tap(_ game: Game, _ r: Rect) {
        game.mouseDown(x: r.midX, y: r.midY)
        game.tick()
    }

    /// Bottom crate of the stack the held toy belongs to (or the other one).
    private func debugCrate(correct: Bool) -> Int? {
        guard held != nil else { return nil }
        let right = codes[2 + cur] & 0x4000 != 0
        return (right == correct) ? 3 : 0
    }

    /// The split of the six toys (left, right) that forms two groups, preferring
    /// toys already in place.
    private func debugSplit() -> [Int]? {
        var best: [Int]?, bestScore = -1
        for mask in 0..<64 where mask.nonzeroBitCount == 3 {
            let left = (0..<6).filter { mask & (1 << $0) != 0 }, right = (0..<6).filter { mask & (1 << $0) == 0 }
            guard groupOf(left).group != 0, groupOf(right).group != 0 else { continue }
            var side = [Int](repeating: 0, count: 6)
            right.forEach { side[$0] = 1 }
            let score = (0..<6).filter { p in crateSlot[p].map { side[$0] == p / 3 } ?? false }.count
            if score > bestScore { best = side; bestScore = score }
        }
        return best
    }

    /// Move one toy toward the solution: misplaced toys back to the tray first.
    private func debugSortStep(_ game: Game, wrong: Bool) -> Bool {
        guard let side = debugSplit() else { return false }
        if wrong {
            guard let k = (0..<6).first(where: { k in !crateSlot.contains(k) }), let r = pieces[k]?.rect else { return false }
            tap(game, r)
            tap(game, crates[side[k] == 0 ? 3 : 0].rect)
            return true
        }
        if let p = (0..<6).first(where: { p in crateSlot[p].map { side[$0] != p / 3 } ?? false }),
           let k = crateSlot[p], let r = pieces[k]?.rect, let t = traySlot.firstIndex(of: nil) {
            tap(game, r)
            let q = Self.trayPoint(t)
            game.mouseDown(x: q.x, y: q.y - 20)
            game.tick()
            return true
        }
        guard let k = (0..<6).first(where: { !crateSlot.contains($0) }), let r = pieces[k]?.rect else { return false }
        tap(game, r)
        tap(game, crates[side[k] * 3].rect)
        return true
    }
}
