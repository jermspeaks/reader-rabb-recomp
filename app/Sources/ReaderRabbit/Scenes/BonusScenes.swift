import AppKit

/// Bonus areas behind each exterior's signpost (FUN_0041dad0(p), p = menu
/// index): 0 picture gallery 2100, 1 waterfall 2900, 2 stage 2300, 3 Crazy
/// Costumes 2500. They are free-play toys that return to their exterior.
///
/// `BonusScene` keeps the exterior's entry point: it plays the WAVE the
/// original queues at the cut (DAT_004483e8: 32024 / 32040 / 32041 / 32018)
/// and forwards everything to the area's own scene.
final class BonusScene: Scene {
    let activity: Activity
    private let inner: Scene

    init(_ activity: Activity) {
        self.activity = activity
        switch activity {
        case .countingClub: inner = GalleryScene()
        case .abcDiner: inner = WaterfallScene()
        case .shapeShack: inner = StageScene()
        case .patternParade: inner = CostumesScene()
        }
    }

    var fps: Int { inner.fps }

    func enter(_ game: Game) {
        game.say(activity.bonusMusic)
        inner.enter(game)
    }

    func tick(_ game: Game) { inner.tick(game) }
    func click(_ game: Game, x: Int, y: Int) { inner.click(game, x: x, y: y) }
    func key(_ game: Game, _ key: Key) { inner.key(game, key) }
    func draw(_ game: Game, _ fb: Framebuffer) { inner.draw(game, fb) }
    func exit(_ game: Game) { inner.exit(game) }
}


// MARK: - Gallery

/// Picture gallery bonus toy behind the Counting Club signpost (RRPW32.EXE
/// enter FUN_0041549e, tick FUN_004149ba, mouse FUN_00415020, key FUN_004152ab,
/// exit FUN_004153e9). Background 2100.
///
/// Reader Rabbit jumps onto the bench, talks, then stands by the bench. Five
/// framed pictures hang on the wall; clicking one makes him jump into it and
/// the picture fills the screen (one of 10 variants per picture, 2 backgrounds
/// × 5 hidden-object animations). Clicking the hidden object plays its
/// animation and a comment, then he returns to the hall. Each visit to a
/// picture (click on the object or exit sign) advances that picture's variant.
final class GalleryScene: Scene {
    // MARK: Constants (RRPW32.EXE data at 0x4416d4..0x4417cc)

    /// Wall picture hit rects (left, top, right, bottom), table 0x441706.
    private static let pictureRects: [(l: Int, t: Int, r: Int, b: Int)] = [
        (68, 25, 210, 134), (259, 25, 403, 134), (450, 25, 593, 134),
        (165, 157, 310, 266), (349, 157, 492, 266),
    ]
    /// Picture background bases (0x44172c[n]): variant v uses bg base (+1000 if v > 4)
    /// and hidden-object ASEQ base+v+1 (v ≤ 4) or base+1000+v−4 (v > 4).
    private static let pictureBase = [2120, 2150, 2110, 2140, 2130]
    /// Rabbit jumping into picture n (0x441736[n]).
    private static let zoomAseq = [2129, 2159, 2119, 2149, 2139]
    /// Music per picture (0x4417cc[n]); the hall alternates 0x7791 / 0x778a.
    private static let pictureMusic = [30603, 30606, 30605, 30601, 30604]
    /// Hall idle remarks, lip-synced (0x441768: count 7).
    private static let hallPrompts = [22208, 22209, 22210, 22211, 22213, 22214, 22215]
    /// Picture-view idle remarks: 0x44179a (f2a != 0) and 0x4417b8 (f2a == 0).
    private static let pictureHintsA = [22216, 22217, 22218, 22219, 22221, 22222, 22223,
                                        22224, 22225, 22226, 22227, 22228, 22229, 22230]
    private static let pictureHintsB = [22231, 22232, 22233, 22235, 22236, 22239, 22240, 22256, 22258]
    /// Comment after a hidden-object animation (0x44177e: count 13).
    private static let afterAnimation = Array(22243...22255)
    /// Lip-synced intro scripts (PTR_DAT_0044175c[0..1]) and first-return script ([2]).
    private static let introScripts = [[22205, 22206, 22207], [22206, 22207, 22204]]
    private static let firstReturnScript = [22202]

    private static let idleTicks = 160          // 20 000 ms at 8 fps

    // MARK: Session globals (BSS in the original; reset by FUN_00415565 on player load)

    private static var introIndex = -1           // DAT_00446f2c
    private static var saidFirstReturn = false   // DAT_00446f4e
    private static var music = 0x778a            // DAT_00446f48
    private static var hallTrack = 0x7791        // DAT_004417cc
    private static var lastHallPrompt = 22208    // DAT_0044177a
    /// Per-picture variant 0–9 (DAT_00446f32..; stored with the active profile).
    // MARK: State

    private var state = -1          // DAT_00446f28
    private var view = 0            // DAT_00446f30: 0 hall, 1–5 picture
    private var chosen = 0          // DAT_00446f2e
    private var seated = true       // DAT_00446f52
    private var highlightStep = 0   // DAT_00446f50
    private var blinkOff = true     // DAT_00446f0c
    private var blinkTimer = 0      // DAT_00446f20
    private var altPrompt = false   // DAT_00446f2a
    private var idleDeadline = 0    // DAT_00446f3c (ticks)
    private var script: [Int]?      // DAT_00446f18
    private var scriptIndex = 0     // DAT_00446f14
    private var lipsActive = false  // DAT_00446f1e[0]
    private var playingMusic: Int?

    private var highlight: Actor?   // slot 0x44844e (ASEQ 2101)
    private var body: Actor?        // slot 0x448582
    private var head: Actor?        // slot 0x4485ae (hall)
    private var picture: Actor?     // slot 0x4485ae (picture view)
    private var exitSign: Actor?

    init() {}

    // MARK: Enter / exit

    /// FUN_0041549e
    func enter(_ game: Game) {
        Self.music = Self.music != 0x7791 ? 0x7791 : 0x778a
        game.setBackground(2100)
        view = 0
        highlightStep = 0
        seated = true
        setupActors(game)
        // Entrance: Rabbit hops onto the bench (2105); head hidden until he lands.
        if let a = game.res.aseq(2105) { body = Actor(a, x: 0, y: 0, step: 1) }
        head?.hidden = true
        blinkOff = true
        state = -1
    }

    /// FUN_004153e9
    func exit(_ game: Game) {
        game.stopMusic()
        game.stopSpeech()
    }

    /// Hall or picture view after a change of `view` (FUN_00414409).
    private func rebuild(_ game: Game) {
        game.stopMusic()
        playingMusic = nil
        if view == 0 {
            Self.hallTrack = Self.hallTrack != 0x7791 ? 0x7791 : 0x778a
            Self.music = Self.hallTrack
            game.setBackground(2100)
        } else {
            Self.music = Self.pictureMusic[view - 1]
            let v = game.player.galleryPictureVariants[view - 1], hi = v > 4
            let bg = Self.pictureBase[view - 1] + (hi ? 1000 : 0)
            game.setBackground(bg, palette: bg)
        }
        setupActors(game)
    }

    /// FUN_004142c7 + FUN_00414216: actors for the current view; exit sign on the background.
    private func setupActors(_ game: Game) {
        let r = game.res
        highlight = nil; body = nil; head = nil; picture = nil
        if view == 0 {
            if seated {
                if let a = r.aseq(2103) { head = Actor(a, x: 365, y: 135, step: 1) }
                if let a = r.aseq(2102) { body = Actor(a, x: 345, y: 273, step: 1) }
            } else {
                if let a = r.aseq(2107) { head = Actor(a, x: 371, y: 139, step: 1) }
                if let a = r.aseq(2106) { body = Actor(a, x: 350, y: 281, step: 1) }
            }
            if let a = r.aseq(2101) { highlight = Actor(a, x: 0, y: 0, step: highlightStep) }
            exitSign = r.aseq(212).map { Actor($0, x: 550, y: 415, step: 1) }
        } else {
            let v = game.player.galleryPictureVariants[view - 1], hi = v > 4
            let id = Self.pictureBase[view - 1] + (hi ? 1000 + v - 4 : v + 1)
            if let a = r.aseq(id) { picture = Actor(a, x: 0, y: 0, step: 1) }
            exitSign = r.aseq(2104).map { Actor($0, x: 562, y: 423, step: 1) }
        }
        if let e = exitSign, let s = e.sprite { game.fb.stamp(s, x: e.rect.x, y: e.rect.y) }
        blinkOff = false
        script = nil
        lipsActive = false
    }

    // MARK: Tick (FUN_004149ba)

    func tick(_ game: Game) {
        let now = game.tickCount
        if state < 0 {
            if game.speechPlaying { return }
            state = 0
        }
        if playingMusic != Self.music {
            game.playMusic(Self.music, loop: true)
            playingMusic = Self.music
        }
        if view == 0 { updateHead(game) }
        if script != nil { stepScript(game) }
        if state != 4 && state != 9 { idleDeadline = now + Self.idleTicks }

        switch state {
        case 0: // entrance hop; thump at step 2
            guard let b = body else { state = 1; break }
            if b.step == 2 { game.say(15971) }
            if b.advance() != .moved {
                head?.hidden = false
                if let a = game.res.aseq(2102) { b.set(a, step: 1, x: 345, y: 273) }
                blinkOff = false
                state = 1
            }
        case 1:
            Self.introIndex = min(Self.introIndex + 1, 1)
            runScript(Self.introScripts[Self.introIndex])
            state = 2
        case 2:
            if script == nil { standUp(game); state = 3 }
        case 3, 6:
            if body?.advance() != .moved {
                seated = false
                if let a = game.res.aseq(2107) { head?.set(a, step: 1, x: 371, y: 139) }
                head?.hidden = false
                if let a = game.res.aseq(2106) { body?.set(a, step: 1, x: 350, y: 281) }
                state += 1          // 3 -> 4 (idle), 6 -> 7 (jump in)
            }
        case 4, 9:
            idle(game)
        case 5:
            if seated { standUp(game); state = 6 } else { state = 7 }
        case 7:
            if let a = game.res.aseq(Self.zoomAseq[chosen - 1]) { body?.set(a, step: 1, x: 0, y: 0) }
            head?.hidden = true
            game.say(15970)
            blinkOff = true
            state = 8
        case 8:
            if body?.advance() != .moved {
                view = chosen
                rebuild(game)
                state = 9
            }
        case 10: // hidden-object animation, then a comment
            if picture?.advance() != .moved {
                game.say(Self.afterAnimation[game.random(Self.afterAnimation.count)])
                state = 11
            }
        case 11:
            if !game.speechPlaying {
                view = 0
                seated = true
                rebuild(game)
                state = 12
            }
        case 12:
            if !Self.saidFirstReturn {
                Self.saidFirstReturn = true
                runScript(Self.firstReturnScript)
            }
            state = 2
        default:
            break
        }
    }

    /// Body plays the stand-up/sit transition 2108; head hidden meanwhile.
    private func standUp(_ game: Game) {
        if let a = game.res.aseq(2108) { body?.set(a, step: 1, x: 0, y: 0) }
        head?.hidden = true
        blinkOff = true
    }

    /// FUN_0041460f: lip sync while a script talks, otherwise random pose changes.
    private func updateHead(_ game: Game) {
        guard let h = head else { return }
        if lipsActive {
            if let m = game.mouth {
                h.step = m + 1
            } else if !game.speechPlaying {
                lipsActive = false
                h.step = 1
            }
            return
        }
        guard !blinkOff, !h.hidden else { return }
        if blinkTimer > 0 { blinkTimer -= 1; return }
        guard game.random(5) == 0 else { return }
        let alt = seated ? 10 : 15
        blinkTimer = seated ? 10 : 20
        h.step = h.step == 1 ? alt : 1
    }

    // MARK: Lip-synced scripts (FUN_004144f1 / FUN_00414553)

    private func runScript(_ ids: [Int]) {
        script = ids
        scriptIndex = 0
        lipsActive = false
    }

    private func stepScript(_ game: Game) {
        guard let s = script, !lipsActive else { return }
        guard scriptIndex < s.count else { script = nil; return }
        game.sayWithLips(s[scriptIndex])
        scriptIndex += 1
        lipsActive = true
    }

    private func stopScript(_ game: Game) {
        guard script != nil else { return }
        game.stopSpeech()
        script = nil
    }

    // MARK: Idle prompts (FUN_00414869)

    private func idle(_ game: Game) {
        let now = game.tickCount
        guard script == nil, !game.speechPlaying else {
            idleDeadline = now + Self.idleTicks
            return
        }
        guard idleDeadline < now else { return }
        altPrompt.toggle()
        if view == 0 {
            var p = Self.lastHallPrompt
            while p == Self.lastHallPrompt { p = Self.hallPrompts[game.random(Self.hallPrompts.count)] }
            Self.lastHallPrompt = p
            runScript([p])
        } else {
            let list = altPrompt ? Self.pictureHintsA : Self.pictureHintsB
            game.say(list[game.random(list.count)])
        }
        idleDeadline = now + Self.idleTicks
    }

    // MARK: Input

    /// FUN_00414fb8: input accepted in states 2, 4 and 9; state 11 skips the comment.
    private func inputReady(_ game: Game) -> Bool {
        if state == 11 { game.stopSpeech(); return false }
        return state == 2 || state == 4 || state == 9
    }

    /// Advance picture `view`'s variant (0–9) for the next visit.
    private func nextVariant(_ game: Game) {
        game.player.galleryPictureVariants[view - 1] = (game.player.galleryPictureVariants[view - 1] + 1) % 10
        game.savePlayer()
    }

    /// FUN_00415020
    func click(_ game: Game, x: Int, y: Int) {
        if state < 0 { game.stopSpeech(); return }
        idleDeadline = game.tickCount + Self.idleTicks
        if exitSign?.rect.contains(x, y) == true {
            if view == 0 { leave(game); return }
            if state == 9 { nextVariant(game) }
            state = 11
            return
        }
        stopScript(game)
        guard inputReady(game) else { return }
        if view == 0 {
            for (i, r) in Self.pictureRects.enumerated() where x >= r.l && x < r.r && y >= r.t && y < r.b {
                chosen = i + 1
                state = 5
                return
            }
            if !seated { altPrompt = true; idleDeadline = 0 }
        } else {
            if state == 9, picture?.rect.contains(x, y) == true {
                game.say(7103 + game.random(5))
                nextVariant(game)
                state = 10
                return
            }
            idleDeadline = 0
        }
    }

    /// FUN_004152ab
    func key(_ game: Game, _ key: Key) {
        if state < 0 { game.stopSpeech(); return }
        idleDeadline = game.tickCount + Self.idleTicks
        switch key {
        case .escape:
            if view != 0 { state = 11 } else { leave(game) }
        case .enter:
            if inputReady(game), view == 0, highlightStep != 0 {
                chosen = highlightStep
                stopScript(game)
                state = 5
            }
        case .space:
            guard view == 0 else { break }
            highlightStep = highlightStep >= 5 ? 1 : highlightStep + 1
            highlight?.step = highlightStep
        case .char("1"):
            if inputReady(game) { altPrompt = true; idleDeadline = 0 }
        default:
            break
        }
    }

    /// FUN_00414ff6: back to the Counting Club exterior (transition 0x1a, WAVE 32019–32023).
    private func leave(_ game: Game) {
        game.change(to: ExteriorScene(.countingClub), sound: 32019 + game.random(5))
    }

    // MARK: Draw (draw list 0x44844e, 0x448582, 0x4485ae)

    func draw(_ game: Game, _ fb: Framebuffer) {
        if view == 0 {
            highlight?.draw(fb)
            body?.draw(fb)
            head?.draw(fb)
        } else {
            picture?.draw(fb)
        }
    }
}

// MARK: - Waterfall

/// Waterfall bonus toy behind the ABC Diner signpost (RRPW32.EXE enter
/// FUN_00415f39, tick FUN_00415762, mouse FUN_00415be6, key FUN_00415d91,
/// exit FUN_00415e6c). Background 2900, music WAVE 0x7792 looping.
///
/// The cursor becomes a magnifying glass (ASEQ 22009 step 8). Clicking one of
/// ten areas of the scene opens a round magnified view (ASEQ base, static,
/// stamped on the background) with a looping close-up animation (base+1).
/// Clicking the view (or the same area) again shows a second close-up
/// (base+5 / base+6); when that one loops, the view closes again.
final class WaterfallScene: Scene {
    // MARK: Constants (RRPW32.EXE data at 0x4417d8..0x4419a0)

    /// Click areas (left, top, right, bottom), table 0x4417da; area k = index+1.
    /// Tested from the last to the first, with the magnifier lens centre (mouse + 15).
    private static let areas: [(l: Int, t: Int, r: Int, b: Int)] = [
        (0, 0, 151, 369), (151, 0, 486, 90), (151, 87, 486, 283), (151, 283, 466, 369),
        (0, 369, 154, 479), (484, 0, 640, 168), (466, 168, 640, 298), (442, 298, 642, 339),
        (295, 324, 640, 480), (154, 369, 295, 480),
    ]
    /// Magnified view ASEQ for area k, phase 1 / 2 (0x441824[k*2 + phase]);
    /// each is followed by its animation (+1). Area 10 reads into the next
    /// table in the original and so repeats area 8's view.
    private static let views: [(Int, Int)] = [
        (2920, 2925), (2910, 2915), (2970, 2975), (2940, 2945), (2930, 2935),
        (2980, 2985), (2960, 2965), (2950, 2955), (2990, 2995), (2950, 2955),
    ]
    /// View position for area k (0x44184c[k], 6-byte entries).
    private static let viewPos: [(x: Int, y: Int)] = [
        (0, 43), (144, 1), (150, 36), (109, 89), (0, 154),
        (309, 0), (309, 63), (309, 73), (238, 154), (58, 154),
    ]
    /// Spoken prompts (PTR_DAT_004418b4[0..5]); 0 is the first-visit intro.
    private static let prompts: [[Int]] = [
        [22304, 22305, 22306, 22307, -2, 22309], [22308], [22309], [22310], [22311], [22312],
    ]
    /// One-shot hint after the first animation finishes (0x4418b0).
    private static let hint = [22313]
    /// Pointer table of (step, WAVE) cue lists, index k + phase*10 (FUN_00434e68).
    private static let cueTable = 0x441974

    private static let music = 0x7792
    private static let idleTicks = 160          // 20 000 ms at 8 fps
    private static let hintTicks = 16           // 2 000 ms

    /// DAT_00446f7a: prompt rotation; FUN_00415fbd sets -1 (intro on first visit).
    private static var promptIndex = -1

    // MARK: State

    private var state = -1          // DAT_00446f78
    private var area = 0            // DAT_00446f8c (1–10, 0 none)
    private var spaceArea = 0       // DAT_00446f8e
    private var phase = 0           // DAT_00446f8a (1, 2; 0 none)
    private var hintState = 0       // DAT_00446f90
    private var viewCount = 0       // DAT_00446f92
    private var idleDeadline = 0    // DAT_00446f7c (ticks)
    private var script: [Int]?      // DAT_00446f70
    private var scriptIndex = 0     // DAT_00446f6c
    private var musicStarted = false

    private var waterfall: Actor?   // slot 0x4485ae (ASEQ 2902)
    private var panel: Actor?       // slot 0x448422 (stamped on the background)
    private var panelAnim: Actor?   // slot 0x4483f6
    private var animDone = false    // DAT_00448404
    private var exitSign: Actor?
    private var cues: [(step: Int, wave: Int)] = []

    private let dissolve = Dissolve()
    private var cursor: MagnifierCursor?

    init() {}

    // MARK: Enter / exit

    /// FUN_00415f39 + FUN_0041564a
    func enter(_ game: Game) {
        redrawBackground(game)
        if let a = game.res.aseq(2902) { waterfall = Actor(a, x: 0, y: 0, step: 0) }
        area = 0; spaceArea = 0; phase = 0; hintState = 0
        state = -1
        // FUN_004344f8(8): software cursor 22009 step 8 (magnifying glass).
        if let a = game.res.aseq(22009), let s = a.step(8), let f = a.frame(s.frame) {
            cursor = MagnifierCursor(sprite: f, palette: game.fb.palette)
            cursor?.push()
        }
    }

    /// FUN_00415e6c
    func exit(_ game: Game) {
        game.stopMusic()
        game.stopSpeech()
        cursor?.pop()
        cursor = nil
    }

    /// Bg_Redraw + FUN_004155a0: plain background with the exit sign (212 at 550,415).
    private func redrawBackground(_ game: Game) {
        game.setBackground(2900)
        exitSign = game.res.aseq(212).map { Actor($0, x: 550, y: 415, step: 1) }
        if let e = exitSign, let s = e.sprite { game.fb.stamp(s, x: e.rect.x, y: e.rect.y) }
    }

    // MARK: Tick (FUN_00415762)

    func tick(_ game: Game) {
        let now = game.tickCount
        if state < 0 {
            if game.speechPlaying { return }
            state = 0
        }
        if !musicStarted {
            game.playMusic(Self.music, loop: true)
            musicStarted = true
        }
        cursor?.refresh()
        if script != nil { stepScript(game) }

        if let anim = panelAnim {
            if script == nil, let c = cues.first(where: { $0.step == anim.step }) { game.say(c.wave) }
            if !animDone {
                let r = anim.advance()
                if r != .moved {
                    if hintState == 0 { hintState = 1; idleDeadline = now + Self.hintTicks }
                    if r == .wrapped {
                        if phase == 2 { state = 5 }
                    } else {
                        animDone = true
                    }
                }
            }
        } else {
            waterfall?.advance()
        }
        if state != 2 && state != 4 { idleDeadline = now + Self.idleTicks }

        switch state {
        case 0:
            Self.promptIndex = Self.promptIndex + 1 > 5 ? 1 : Self.promptIndex + 1
            startScript(Self.prompts[Self.promptIndex])
            state = 1
        case 1:
            if script == nil { state = 2 }
        case 2, 4:
            idle(game)
        case 3:
            showView(game)
            state = 4
        case 5:
            game.stopSpeech()
            script = nil
            area = 0
            phase = 0
            panel = nil
            panelAnim = nil
            dissolve.start(from: game.fb)
            redrawBackground(game)
            state = 2
        default:
            break
        }
    }

    /// State 3: open the magnified view for `area` / `phase`.
    private func showView(_ game: Game) {
        game.say(7103 + game.random(5))
        viewCount += 1
        if viewCount > 2 { viewCount = 0; hintState = 0 }
        dissolve.start(from: game.fb)
        redrawBackground(game)
        let base = phase == 2 ? Self.views[area - 1].1 : Self.views[area - 1].0
        let pos = Self.viewPos[area - 1]
        panel = game.res.aseq(base).map { Actor($0, x: pos.x, y: pos.y, step: 1) }
        panelAnim = game.res.aseq(base + 1).map { Actor($0, x: pos.x, y: pos.y, step: 0) }
        animDone = false
        if let p = panel, let s = p.sprite { game.fb.stamp(s, x: p.rect.x, y: p.rect.y) }
        cues = loadCues(game, index: area + phase * 10)
    }

    /// (step, WAVE) pairs, zero-terminated, from the pointer table at 0x441974.
    private func loadCues(_ game: Game, index: Int) -> [(step: Int, wave: Int)] {
        guard let exe = game.exe, let p = exe.u32(at: Self.cueTable + index * 4), p != 0 else { return [] }
        var out: [(step: Int, wave: Int)] = []
        for i in 0..<0x63 {
            guard let v = exe.u32(at: p + i * 4), v & 0xFFFF != 0 else { break }
            out.append((Int(Int16(truncatingIfNeeded: v)), Int(Int16(truncatingIfNeeded: v >> 16))))
        }
        return out
    }

    // MARK: Prompts (FUN_00415690 / FUN_004156d9)

    private func startScript(_ ids: [Int]) {
        script = ids
        scriptIndex = 0
    }

    /// Play the next WAVE once the previous one has finished.
    private func stepScript(_ game: Game) {
        guard let s = script, !game.speechPlaying else { return }
        guard scriptIndex < s.count else { script = nil; return }
        if s[scriptIndex] > 0 { game.say(s[scriptIndex]) }
        scriptIndex += 1
    }

    private func idle(_ game: Game) {
        let now = game.tickCount
        if script != nil { idleDeadline = now + Self.idleTicks; return }
        guard idleDeadline < now else { return }
        Self.promptIndex = Self.promptIndex + 1 > 5 ? 1 : Self.promptIndex + 1
        startScript(Self.prompts[Self.promptIndex])
        if hintState == 1 {
            hintState = 2
            startScript(Self.hint)
        }
    }

    private func stopScript(_ game: Game) {
        guard script != nil else { return }
        game.stopSpeech()
        script = nil
    }

    // MARK: Input

    /// FUN_00415be6
    func click(_ game: Game, x: Int, y: Int) {
        if state < 0 { game.stopSpeech(); return }
        stopScript(game)
        idleDeadline = game.tickCount + Self.idleTicks
        let lx = x + 15, ly = y + 15   // magnifier lens centre
        if exitSign?.rect.contains(lx, ly) == true { leave(game); return }
        if let p = panel, p.rect.contains(x, y) {
            if phase != 2 { phase = 2; state = 3 } else if state == 4 { state = 5 }
            return
        }
        for i in Self.areas.indices.reversed() {
            let r = Self.areas[i]
            guard lx >= r.l, lx < r.r, ly >= r.t, ly < r.b else { continue }
            let k = i + 1
            if k == area {
                if phase == 2 {
                    if state == 4 { state = 5 }
                    return
                }
                phase = 2
            } else {
                phase = 1
            }
            state = 3
            area = k
            spaceArea = k
            return
        }
        idleDeadline = 0
    }

    /// FUN_00415d91
    func key(_ game: Game, _ key: Key) {
        if state < 0 { game.stopSpeech(); return }
        stopScript(game)
        idleDeadline = game.tickCount + Self.idleTicks
        switch key {
        case .space:
            if phase == 1 {
                phase = 2
            } else {
                spaceArea = spaceArea >= 9 ? 1 : spaceArea + 1
                area = spaceArea
                phase = 1
            }
            state = 3
        case .char("1"):
            idleDeadline = 0
        case .escape:
            leave(game)
        default:
            break
        }
    }

    /// FUN_00415bbc: back to the ABC Diner exterior (transition 0x1b, WAVE 32037–32039).
    private func leave(_ game: Game) {
        game.change(to: ExteriorScene(.abcDiner), sound: 32037 + game.random(3))
    }

    // MARK: Draw

    func draw(_ game: Game, _ fb: Framebuffer) {
        if let a = panelAnim { a.draw(fb) } else { waterfall?.draw(fb) }
        dissolve.apply(fb)
    }
}

/// Fx_Dissolve (FUN_00435eb6) stand-in: the old screen gives way to the new
/// one in a 4×4 ordered pattern over four ticks (16 passes × 33 ms originally).
private final class Dissolve {
    private static let order = [0, 8, 2, 10, 12, 4, 14, 6, 3, 11, 1, 9, 15, 7, 13, 5]
    private var old: [UInt8] = []
    private var revealed = 16

    func start(from fb: Framebuffer) {
        old = fb.front
        revealed = 0
    }

    func apply(_ fb: Framebuffer) {
        guard revealed < 16, old.count == Framebuffer.width * Framebuffer.height else { return }
        revealed += 4
        for y in 0..<Framebuffer.height {
            for x in 0..<Framebuffer.width where Self.order[(y & 3) * 4 + (x & 3)] >= revealed {
                fb.fill(x: x, y: y, w: 1, h: 1, color: old[y * Framebuffer.width + x])
            }
        }
    }
}

/// The magnifying-glass software cursor as an NSCursor. Hot spot is the
/// sprite's top-left corner, like the original, which drew the sprite at the
/// mouse position and hit-tested the lens centre (mouse + 15).
private final class MagnifierCursor {
    private let cursor: NSCursor

    init?(sprite: Sprite, palette: Palette) {
        guard sprite.width > 0, sprite.height > 0 else { return nil }
        var scale: CGFloat = 1
        if let app = NSApp, let v = app.windows.first?.contentView {
            scale = max(1, min(v.bounds.width / 640, v.bounds.height / 480))
        }
        let n = max(1, Int((scale * (NSScreen.main?.backingScaleFactor ?? 1)).rounded()))
        let w = sprite.width * n, h = sprite.height * n
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: w, pixelsHigh: h, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: w * 4, bitsPerPixel: 32), let px = rep.bitmapData else { return nil }
        for y in 0..<h {
            for x in 0..<w {
                let i = (y / n) * sprite.width + x / n, o = (y * w + x) * 4
                let c = palette.rgba[Int(sprite.pixels[i])]
                let on = sprite.opaque[i]
                px[o] = on ? UInt8(c & 0xFF) : 0
                px[o + 1] = on ? UInt8(c >> 8 & 0xFF) : 0
                px[o + 2] = on ? UInt8(c >> 16 & 0xFF) : 0
                px[o + 3] = on ? 255 : 0
            }
        }
        let image = NSImage(size: NSSize(width: CGFloat(sprite.width) * scale, height: CGFloat(sprite.height) * scale))
        image.addRepresentation(rep)
        cursor = NSCursor(image: image, hotSpot: .zero)
    }

    func push() { cursor.push() }
    func pop() { NSCursor.pop() }
    /// AppKit may reset the cursor (e.g. after leaving the window); re-apply it.
    func refresh() { if NSApp?.isActive == true { cursor.set() } }
}

// MARK: - Stage

/// "Body Builders": the stage-and-mirror toy behind the Shape Shack signpost
/// (RRPW32.EXE enter FUN_004122e3, tick FUN_0041139c, mouse FUN_00411f57,
/// key FUN_004120e8, exit FUN_0041221c; background 2300).
///
/// The moose host (body 2360, lip-synced head 2362) stands at the left. The
/// mirror has six panels (2310–2315); each shows a picture of one body section
/// from one of eight characters (part sheets 4100–4800). Clicking a panel puts
/// that section on the figure in the spotlight and moves the panel on to its
/// next picture. When all six sections come from the same character, that
/// character's dance plays (2380–2387). Then the curtain opens on the next
/// stage picture (2332–2348 with its animation one id higher), and a new round
/// starts. Music WAVE 30611 (0x7793) is restarted whenever it stops.
final class StageScene: Scene {
    // MARK: State that lives longer than one visit

    /// Intro script index (DAT_00446d84; -1 until the first visit, FUN_0041236c).
    static var introIndex = -1
    /// Player record +0x92: 1-based number of the last stage picture shown.
    static var pictureIndex = 0
    /// Help-line rotation (DAT_00446d82).
    static var helpIndex = 0
    /// Idle prompt rotation (DAT_00446d5e).
    static var idlePhase = 0

    // MARK: Layout (data section of RRPW32.EXE)

    private static let music = 30611                     // 0x7793
    private static let exitSign = (x: 560, y: 435)        // FUN_00410168
    /// Mirror panel hit rectangles, (left, top, right, bottom) (0x4400ae).
    private static let panelRects = [
        (202, 154, 308, 238), (307, 154, 419, 239), (201, 237, 307, 323),
        (307, 237, 417, 324), (208, 323, 306, 415), (306, 323, 409, 415),
    ]
    /// Panel picture actors 2310–2315 (0x4400de).
    private static let buttonPos = [(224, 178), (343, 157), (207, 246), (339, 257), (236, 357), (322, 362)]
    /// Sign and sparkles (0x44010e).
    private static let decor = [(2322, 180, 19), (2325, 494, 414), (2326, 192, 431)]
    /// Idle host animations (0x4412ec) and their (step, WAVE) cues (0x441318).
    private static let idleAnims = [2366, 2367, 2368, 2369, 2373, 2374, 2375]
    private static let idleAnimCues: [[(Int, Int)]] = [[(4, 15994)], [(5, 15996)], [(5, 15996)], [(6, 15997)], [], [], []]
    /// Stage picture order (0x441140) and per-picture (step, WAVE) cues (0x4412c4).
    private static let pictureOrder = [5, 2, 4, 3, 8, 6, 1, 7, 9]
    private static let pictureCues: [[(Int, Int)]] = [
        [(2, 20088)], [(2, 20085), (10, 15981)], [(2, 20094), (9, 20095)], [(2, 20091), (26, 20090)],
        [(2, 20096), (26, 20097)], [(2, 20088), (9, 15993), (17, 15990)], [(2, 20088), (9, 15993), (17, 15991)],
        [(2, 20088), (9, 15993), (17, 15992)], [(2, 20001), (9, 15988)], [(2, 20002), (9, 15989)],
    ]

    // MARK: Speech (scripts: 1 = host speaks, 2–10 = flex animation 2372, <0 = pause, 0 = end)

    private static let intros: [[Int]] = [                 // 0x4411a8
        [1, 20021, 20022, 15984, 20008, 0], [1, 20022, -4, 20024, 20075, 20025, 15984, 0],
        [1, 20023, 5, -2, 1, -2, 0], [1, 20022, -4, 20026, 15984, 0], [1, 20023, -4, 20028, 20010, 15984, 0],
    ]
    private static let demo = [1, 20009, 20010, 5, -2, 1, -2, 0]   // 0x44115e
    /// "Make the …" hint per target character (0x4411ce).
    private static let targetHints = [20034, 20030, 20031, 20029, 20036, 20035, 20033, 20032]
    /// Help lines 1–4 (0x4411bc).
    private static let helpLines = [20006, 20027, 20011, 20012, 20013]
    /// Character names, indexed 1–8 (0x4411dc).
    private static let names = [20032, 20040, 20037, 20043, 20044, 20042, 20041, 20039, 20038]
    /// Remarks about one panel: mismatched (0x4411e8) or matching the head (0x44120c).
    private static let panelRemarks = [
        [20068, 20069, 20070], [20059, 20060, 20061], [20056, 20057, 20058],
        [20071, 20072, 20073], [20062, 20063, 20064], [20065, 20066, 20067],
    ]
    private static let panelPraise = [
        [20070, 20070, 20070], [20061, 20061, 20061], [20057, 20058, 20058],
        [20073, 20073, 20073], [20064, 20064, 20064], [20066, 20067, 20067],
    ]

    // MARK: Actors (slot numbers of the original actor table DAT_004483f6)

    private struct Part { let x: Int, y: Int, code: Int }
    /// 64 layouts of ten part placements, one per (neighbour, character) pair
    /// (pointer table 0x441040, read from the EXE).
    private var layout: [[Part]] = []

    private var parts = [Actor?](repeating: nil, count: 10)  // slots 0–9
    private var buttons: [Actor] = []                        // slots 10–15
    private var finale: Actor?                               // slot 16
    private var finaleDone = false
    private var body: Actor?                                 // slot 19
    private var head: Actor?                                 // slot 20
    private var decor: [Actor] = []                          // slots 25–27
    private var highlight: Actor?                            // slot 29 (2301)
    private var picture: Actor?                              // slot 20 during the show

    // MARK: Game state

    private var state = -1               // DAT_00446d80
    private var ticks = 0
    private var now: Int { ticks * 1000 / fps }
    private var deadline = 0             // DAT_00446d8c: idle prompt time
    private var clickTime = 0            // DAT_00446da8
    /// 0 idle, 20 = host animation running, -1 just finished, (DAT_00446d60).
    private var hostAnim = 0
    private var animCue = -1             // DAT_00446da6
    private var showDone = false         // DAT_00446d60 == -2 during the picture show
    private var counter = 0              // DAT_00446d86
    private var picks = [Int](repeating: 0, count: 6)       // DAT_00446e1a
    private var order = [[Int]](repeating: [], count: 6)    // DAT_00446db0 per panel
    private var cursor = [Int](repeating: 0, count: 6)      // DAT_00446dae per panel
    private var built = [Bool](repeating: false, count: 8)  // DAT_00446e26
    private var target = 0                // DAT_00446d9c
    private var targetShowing = 0         // DAT_00446d9e
    private var lastPanel = 0             // DAT_00446dac (1-based)
    private var cooldown = 0              // DAT_00446d9a
    private var clicksLeft = 99           // DAT_00446d5c
    private var selected = 0              // DAT_00446da4 (keyboard panel, 1-based)
    private var nameLine = 0              // DAT_004411c8 when a character is built
    private var blink = 0                 // DAT_00446d78

    private var script: [Int]?
    private var scriptPos = 0
    private var scriptDelay = 0
    private var scriptSpeech = 0

    init() {}

    // MARK: Enter / exit (FUN_004122e3, FUN_0041221c)

    func enter(_ game: Game) {
        game.setBackground(2300, palette: 2300)
        Self.pictureIndex = max(0, game.player.stagePictureIndex)
        stampExitSign(game)
        loadLayout(game)
        state = -1
        clicksLeft = 99
        lastPanel = 0
        built = Array(repeating: false, count: 8)
        reset(game)
    }

    func exit(_ game: Game) { game.stopMusic() }

    private func leave(_ game: Game) {
        // FUN_00411f2d: transition 0x1d, WAVE 32000 + random(6) at the cut.
        game.change(to: ExteriorScene(.shapeShack), sound: 32000 + game.random(6))
    }

    private func stampExitSign(_ game: Game) {
        if let a = game.res.aseq(212), let f = a.frame(0) { game.fb.stamp(f, x: Self.exitSign.x, y: Self.exitSign.y) }
    }

    private func loadLayout(_ game: Game) {
        guard layout.isEmpty, let exe = game.exe else { return }
        func s16(_ va: Int) -> Int { Int(Int16(truncatingIfNeeded: exe.u32(at: va) ?? 0)) }
        for i in 0..<64 {
            guard let p = exe.u32(at: 0x441040 + 4 * i) else { layout = []; return }
            layout.append((0..<10).map { Part(x: s16(p + 6 * $0), y: s16(p + 6 * $0 + 2), code: s16(p + 6 * $0 + 4)) })
        }
    }

    private func actor(_ game: Game, _ id: Int, _ x: Int, _ y: Int, _ step: Int) -> Actor? {
        game.res.aseq(id).map { Actor($0, x: x, y: y, step: step) }
    }

    /// FUN_00410c4d: shuffle the panels, place the host and decorations.
    private func reset(_ game: Game) {
        for p in 0..<6 {
            var o = Array(0...8)
            for k in 1...8 { o.swapAt(game.random(8) + 1, k) }
            order[p] = Array(o[1...8])
            cursor[p] = 0
        }
        buttons = (0..<6).compactMap { actor(game, 2310 + $0, Self.buttonPos[$0].0, Self.buttonPos[$0].1, order[$0][0]) }
        showTarget(game)
        parts = Array(repeating: nil, count: 10)   // the copy loop clears every part's ASEQ
        decor = Self.decor.compactMap { actor(game, $0.0, $0.1, $0.2, 1) }
        selected = 0
        highlight = actor(game, 2301, 0, 0, 0)
        head = actor(game, 2362, 0, 82, 1)
        body = actor(game, 2360, 0, 160, Self.introIndex > -1 ? 2 : 1)
        finale = nil
        hostAnim = 0
        script = nil
    }

    // MARK: Building the figure (FUN_004104ab / FUN_004103cd / FUN_00410ad1)

    /// Layout for section owner `p` next to character `q` (both 1–8).
    private func entry(_ p: Int, _ q: Int) -> [Part] { layout[(q - 1) * 8 + (p - 1)] }

    /// FUN_00410454: part code 4xyy = sheet 4x00, frame yy.
    private func setPart(_ game: Game, _ slot: Int, _ x: Int, _ y: Int, _ code: Int) {
        let n = code - 4100
        guard let a = game.res.aseq(4100 + 100 * (n / 100)) else { return }
        if let p = parts[slot] { p.set(a, step: n % 100 + 1, x: x, y: y) } else {
            parts[slot] = Actor(a, x: x, y: y, step: n % 100 + 1)
        }
        parts[slot]?.hidden = false
    }

    private func rebuild(_ game: Game) {
        guard layout.count == 64 else { return }
        let a = picks
        func z(_ v: Int) -> Int { v == 0 ? 4 : v }
        var e = entry(z(a[0]), z(a[1]))[9]                          // head
        setPart(game, 9, e.x, e.y, e.code)
        parts[9]?.hidden = a[0] == 0
        e = entry(z(a[1]), z(a[1]))[8]                              // chest
        setPart(game, 8, e.x, e.y, e.code)
        parts[8]?.hidden = a[1] == 0
        for k in 4...5 {                                            // arms
            if a[2] == 0 { parts[k]?.hidden = true; continue }
            e = entry(a[2], z(a[1]))[k]
            setPart(game, k, e.x, e.y, e.code)
        }
        for k in 6...7 {                                            // legs
            e = entry(z(a[3]), z(a[1]))[k]
            setPart(game, k, e.x, e.y, e.code)
            parts[k]?.hidden = a[3] == 0
        }
        for k in 2...3 {                                            // ears / hat, relative to the head
            if a[4] == 0 { parts[k]?.hidden = true; continue }
            let rel = entry(z(a[0]), a[4]), own = entry(a[4], a[4])
            setPart(game, k, rel[k].x - rel[9].x + (parts[9]?.x ?? 0), rel[k].y - rel[9].y + (parts[9]?.y ?? 0), own[k].code)
        }
        let s3 = z(a[5]), rel = entry(z(a[3]), s3), own = entry(s3, s3)
        for k in 0...1 {                                            // feet, relative to the legs
            setPart(game, k, rel[k].x - rel[k + 6].x + (parts[k + 6]?.x ?? 0),
                    rel[k].y - rel[k + 6].y + (parts[k + 6]?.y ?? 0), own[k].code)
            parts[k]?.hidden = a[5] == 0
        }
        standOnFloor()
    }

    /// FUN_004103cd: stand the figure on the spotlight disc.
    private func standOnFloor() {
        var dy: Int
        if let p0 = parts[0] { dy = 407 - (p0.rect.y + p0.rect.h) } else if let p6 = parts[6] {
            dy = 380 - (p6.rect.y + p6.rect.h)
        } else { return }
        if picks[5] == 8 { dy += 15 }
        for case let p? in parts where !p.hidden {
            p.x -= 10
            p.y += dy
        }
    }

    /// FUN_00410ad1: pick a character not built yet and show it whole.
    private func showTarget(_ game: Game) {
        var t = game.random(8), n = 0
        while n < 8, built[t] { t = (t + 1) % 8; n += 1 }
        if n == 8 {
            built = Array(repeating: false, count: 8)
            repeat { t = game.random(8) } while t == target
        }
        target = t
        targetShowing = 1
        lastPanel = 0
        cooldown = 0
        picks = Array(repeating: t + 1, count: 6)
        guard layout.count == 64 else { return }
        let e = entry(t + 1, t + 1)
        for k in 0..<10 { setPart(game, k, e[k].x, e[k].y, e[k].code) }
        standOnFloor()
    }

    private func hideParts() {
        for p in parts { p?.hidden = true }
        picks = Array(repeating: 0, count: 6)
    }

    // MARK: Panels (FUN_004109e5 / FUN_004102ab)

    private func clickPanel(_ game: Game, _ p: Int) {
        lastPanel = p + 1
        game.say(7103 + game.random(5))
        picks[p] = order[p][cursor[p]]
        rebuild(game)
        cursor[p] = (cursor[p] + 1) % 8
        if p < buttons.count { buttons[p].step = order[p][cursor[p]] }
        clickTime = now + 2000
        Self.idlePhase = 0
        if cooldown > 0 { cooldown -= 1 }
        if clicksLeft > 0 { clicksLeft -= 1 }
    }

    private func checkFigure(_ game: Game) {
        guard !picks.contains(0) else { return }
        if picks.contains(where: { $0 != picks[0] }) {
            guard cooldown == 0, clickTime != 0, clickTime <= now else { return }
            clickTime = 0
            cooldown = 6
            let line = picks[0] == picks[1] ? 20053 + game.random(3) : 20051 + game.random(5)
            runScript(game, [1, line, -4, 0])
            state = 9
        } else {
            cooldown = 6
            nameLine = Self.names[picks[0]]
            game.say(20098)
            state = 0xd
            target = picks[0] - 1
            built[target] = true
        }
    }

    // MARK: Host (FUN_00411183, FUN_0041103a, FUN_00410e9b / FUN_00410efd)

    private func startHostAnim(_ game: Game, _ id: Int, cue: Int) {
        guard let a = game.res.aseq(id) else { return }
        hostAnim = 20
        head?.set(a, step: 1)
        body?.hidden = true
        animCue = cue
    }

    private func restoreHost(_ game: Game) {
        hostAnim = 0
        if let a = game.res.aseq(2362) { head?.aseq = a }
        body?.hidden = false
        body?.step = 2   // frame 1 is forced visible
    }

    private func runScript(_ game: Game, _ s: [Int]) {
        game.stopSpeech()
        script = s
        scriptPos = 0
        scriptDelay = 0
    }

    /// Returns true when the script has finished.
    private func stepScript(_ game: Game) -> Bool {
        guard let s = script else { return true }
        if hostAnim != 0 {
            if hostAnim > 0 {
                if head?.step == 6 { game.say(20006) }
                return false
            }
            restoreHost(game)
        }
        if game.mouth != nil || (game.speechPlaying && game.currentSpeech == scriptSpeech) { return false }
        if scriptDelay > 0 { scriptDelay -= 1; return false }
        let v = scriptPos < s.count ? s[scriptPos] : 0
        if v == 0 { return true }
        if v < 0 {
            scriptDelay = -v
        } else if v <= 10 {
            if v >= 2 { startHostAnim(game, 2372, cue: -1) }
        } else {
            game.stopSpeech()
            game.sayWithLips(v)
            scriptSpeech = v
        }
        scriptPos += 1
        return false
    }

    private func animateHead(_ game: Game) {
        guard hostAnim == 0, let head else { return }
        if let m = game.mouth {
            head.step = m + 1
        } else if blink < 1, game.random(5) == 0 {
            blink = 10
            head.step = 6
        } else {
            if blink > 0 { blink -= 1 }
            head.step = 1
        }
    }

    // MARK: Idle prompts (FUN_004111ee)

    private func idle(_ game: Game) {
        guard deadline < now else { return }
        guard clicksLeft == 0 || clicksLeft > 98 else {
            clicksLeft = 0
            runScript(game, [1, 20013, -4, 0])
            state = 8
            return
        }
        Self.idlePhase = (Self.idlePhase + 1) % 3
        if Self.idlePhase == 0 {
            let i = game.random(7)
            startHostAnim(game, Self.idleAnims[i], cue: i)
            return
        }
        var line = 0
        if Self.idlePhase == 1 {
            var panel = lastPanel
            lastPanel = 0
            if panel == 0 {
                let filled = (0..<6).filter { picks[$0] != 0 }
                if !filled.isEmpty { panel = filled[game.random(filled.count)] + 1 }
            }
            if panel == 0 {
                Self.idlePhase = 2
            } else {
                let r = game.random(3)
                line = picks[0] == 0 || picks[panel - 1] != picks[0] ? Self.panelRemarks[panel - 1][r] : Self.panelPraise[panel - 1][r]
            }
        }
        if Self.idlePhase == 2 { line = 20014 + game.random(7) }
        runScript(game, [1, line, -4, 0])
        state = 8
    }

    /// FUN_00411ef4: is the toy waiting for the child?
    private func ready() -> Bool {
        if state == 6 || state == 8 { state = 10 }
        return state == 10 && targetShowing == 0
    }

    private func cue(_ game: Game, _ cues: [(Int, Int)], _ step: Int) {
        if let c = cues.first(where: { $0.0 == step }) { game.say(c.1) }
    }

    // MARK: Tick (FUN_0041139c)

    func tick(_ game: Game) {
        ticks += 1
        if state < 0 {
            if game.speechPlaying { return }
            state = 0
        }
        if !game.audio.musicPlaying, game.player.soundOn { game.playMusic(Self.music, loop: true) }
        if state == 0x12 { showTick(game); return }

        animateHead(game)
        if let f = finale, !finaleDone, f.advance() != .moved { finaleDone = true }
        for d in decor { d.advance() }
        if script != nil, stepScript(game) { script = nil }
        if hostAnim > 0, let head {
            if (0..<7).contains(animCue) { cue(game, Self.idleAnimCues[animCue], head.step) }
            if head.advance() != .moved {
                hostAnim = -1
                clickTime = now + 1000
            }
        }
        if state != 10 || hostAnim != 0 { deadline = now + 5000 }

        switch state {
        case 0:
            Self.introIndex += 1
            if Self.introIndex > 4 { Self.introIndex = 1 }
            runScript(game, Self.intros[Self.introIndex])
            state = 1
        case 1:
            guard script == nil else { break }
            state = 2
            if Self.introIndex < 1 { startHostAnim(game, 2365, cue: -1) } else { state = 5 }
        case 2:   // first visit: the moose ponders (2365) …
            if head?.step == 8 { game.say(15980) }
            if hostAnim == -1 {
                restoreHost(game)
                runScript(game, Self.demo)
                state = 3
            }
        case 3:   // … then strips off his suit (2370 + 2371)
            guard script == nil else { break }
            startHostAnim(game, 2370, cue: -1)
            if let a = game.res.aseq(2371) { body?.set(a, step: 1, x: 0, y: 0) }
            body?.hidden = false
            state = 4
        case 4:
            if head?.step == 10 { game.say(20007) }
            if hostAnim == -1 {
                restoreHost(game)
                if let a = game.res.aseq(2360) { body?.set(a, step: 2, x: 0, y: 160) }
                runScript(game, Self.demo)
                state = 5
            } else {
                body?.advance()
            }
        case 5:   // new round: show the character to build
            showTarget(game)
            counter = 0
            runScript(game, [1, Self.targetHints[target], -4, 0])
            state = 6
        case 6:
            guard script == nil else { break }
            game.say(15987)
            targetShowing = 0
            hideParts()
            state = 10
        case 7:   // help (click on the backdrop or key 1)
            var line = Self.targetHints[target]
            if counter >= 1 {
                Self.helpIndex = Self.helpIndex % 4 + 1
                line = Self.helpLines[Self.helpIndex]
            }
            runScript(game, [1, line, -4, 0])
            state = 8
        case 8:
            if script == nil { state = 10 }
        case 9:
            guard script == nil else { break }
            state = 10
            game.say(game.random(2) == 0 ? 15985 : 15983)
        case 10:
            if targetShowing != 0 {
                targetShowing += 1
                if targetShowing == 3 { targetShowing = 0 } else { hideParts() }
                return
            }
            if hostAnim == -1 { restoreHost(game) }
            idle(game)
            checkFigure(game)
        case 0xd:   // whole character built: its dance replaces the head
            guard !game.speechPlaying else { break }
            let r = [parts[9], parts[2], parts[3]].compactMap { $0?.rect }.reduce(Rect?.none) { union($0, $1) }
            if let r, let a = game.res.aseq(2380 + picks[0] - 1) {
                finale = Actor(a, x: r.x, y: r.y, step: 1)
                finaleDone = false
            }
            for k in [2, 3, 9] { parts[k]?.hidden = true }
            runScript(game, [1, nameLine, -4, 0])
            state = 0xe
        case 0xe:
            guard script == nil else { break }
            game.say(15984)
            state = 0xf
        case 0xf:
            guard !game.speechPlaying else { break }
            runScript(game, [1, game.random(2) == 0 ? 20045 : 20084, -4, 0])
            state = 0x10
        case 0x10:
            guard script == nil else { break }
            hostAnim = -1
            state = 0x11
        case 0x11:   // curtain up on the next stage picture
            guard hostAnim == -1, clickTime <= now else { break }
            let n = Self.pictureIndex % 9
            Self.pictureIndex = n + 1
            game.player.stagePictureIndex = Self.pictureIndex
            game.savePlayer()
            let k = Self.pictureOrder[n]
            game.setBackground(2330 + 2 * k, palette: 2300)
            picture = actor(game, 2331 + 2 * k, 0, 0, 0)
            counter = 0
            showDone = false
            state = 0x12
        case 0x15:
            runScript(game, [1, 20047 + game.random(4), -4, 0])
            state = 0x16
        case 0x16:
            if script == nil { state = 5 }
        default:
            break
        }
    }

    private func union(_ a: Rect?, _ b: Rect) -> Rect? {
        guard b.w > 0, b.h > 0 else { return a }
        guard let a, a.w > 0, a.h > 0 else { return b }
        let x0 = min(a.x, b.x), y0 = min(a.y, b.y)
        return Rect(x: x0, y: y0, w: max(a.x + a.w, b.x + b.w) - x0, h: max(a.y + a.h, b.y + b.h) - y0)
    }

    /// State 0x12: the picture animation is drawn into the background page;
    /// its lead-in runs, waits for speech, then the main part plays once.
    private func showTick(_ game: Game) {
        if counter == 1 {
            if game.speechPlaying { return }
            counter = 2
        }
        if showDone {
            guard !game.speechPlaying, clickTime <= now else { return }
            game.setBackground(2300, palette: 2300)
            stampExitSign(game)
            lastPanel = 0
            reset(game)
            counter = 0
            state = 0x15
            return
        }
        guard let pic = picture else { showDone = true; return }
        let k = Self.pictureOrder[(Self.pictureIndex + 8) % 9]
        cue(game, Self.pictureCues[k], pic.step)
        if let s = pic.aseq.step(pic.step), s.frame >= 0, let f = pic.aseq.frame(s.frame) {
            game.fb.stamp(f, x: pic.x + s.dx, y: pic.y + s.dy)
        }
        if pic.advance() != .moved {
            counter += 1
            if counter == 3 {
                showDone = true
                clickTime = now + 1000
            }
        }
    }

    // MARK: Input

    private func inside(_ r: (Int, Int, Int, Int), _ x: Int, _ y: Int) -> Bool {
        x >= r.0 && x < r.2 && y >= r.1 && y < r.3
    }

    func click(_ game: Game, x: Int, y: Int) {
        if state < 0 { game.stopSpeech(); return }
        if inside((Self.exitSign.x, Self.exitSign.y, Self.exitSign.x + 73, Self.exitSign.y + 43), x, y) {
            leave(game)
            return
        }
        if state == 0x12 { game.stopSpeech(); return }
        if hostAnim == 0 {
            if script != nil, state != 0xd || clickTime < now {
                game.stopSpeech()
                script = nil
            }
            deadline = now + 5000
            guard ready() else { return }
            if let p = Self.panelRects.firstIndex(where: { inside($0, x, y) }) {
                clickPanel(game, p)
                return
            }
            askForHelp(game)
        } else if (2...4).contains(state) {
            game.stopSpeech()
            hostAnim = -1
        }
    }

    private func askForHelp(_ game: Game) {
        counter = (counter + 1) % 3
        state = 7
        clickTime = 1
        checkFigure(game)
    }

    func key(_ game: Game, _ key: Key) {
        if state < 0 { game.stopSpeech(); return }
        deadline = now + 5000
        if state == 0x12, key != .escape { game.stopSpeech(); return }
        switch key {
        case .escape:
            leave(game)
        case .enter:
            if ready(), selected != 0 { clickPanel(game, selected - 1) }
        case .space:
            selected = selected % 6 + 1
            highlight?.step = selected
        case .char("1"):
            if ready() { askForHelp(game) }
        default:
            break
        }
    }

    // MARK: Drawing (draw list built in FUN_0041139c)

    func draw(_ game: Game, _ fb: Framebuffer) {
        guard state != 0x12 else { return }
        highlight?.draw(fb)
        for d in decor { d.draw(fb) }
        let earsLate = picks[0] == 6
        for k in [0, 1, 4, 5, 6, 7, 8, 9] {
            if k == 9, !earsLate { parts[2]?.draw(fb); parts[3]?.draw(fb) }
            parts[k]?.draw(fb)
        }
        if earsLate { parts[2]?.draw(fb); parts[3]?.draw(fb) }
        for b in buttons { b.draw(fb) }
        body?.draw(fb)
        head?.draw(fb)
        finale?.draw(fb)
    }
}

// MARK: - Costumes

/// Crazy Costumes, the dress-up toy behind the Pattern Parade signpost
/// (RRPW32.EXE enter FUN_00414129, tick FUN_004133ba, mouse FUN_00413c19,
/// key FUN_00413e59, exit FUN_00414074; background 2500).
///
/// Two characters stand in tree-trunk booths. Each has a lip-synced head
/// (2503 / 2504) and a hat, top and bottom (char 0: 2550–2561 / 2750–2761,
/// char 1: 2570–2581 / 2770–2781). A dresser (2505) holds one costume piece
/// (2506) on top. Clicking a drawer picks a piece of that kind (hat / top /
/// bottom). The piece goes on the character it is dropped on. A piece made
/// for the other character gives the "crazy" version. Completing a matching
/// outfit plays that costume's animation (2511–2521 / 2531–2541), then a star
/// (2590–2593) appears in the trees.
///
/// The original runs at 60 fps so a dragged piece can follow the mouse. This
/// port keeps its 9 fps scene tick for lip-sync, while the input layer forwards
/// coalesced pointer moves and releases in order. Click-to-pick-up/click-to-drop
/// and ←/→ remain available as alternatives.
final class CostumesScene: Scene {
    var fps: Int { 9 }

    // MARK: State that lives longer than one visit

    /// Music alternates between WAVE 30608 and 30607 (DAT_00446e50, reset by FUN_004141a0).
    static var lastMusic = 30607
    static var introIndex = -1          // DAT_00446e80
    static var idleIndex = 0            // DAT_00446e86
    static var leftToggle = false       // DAT_00446e82

    // MARK: Layout (data section of RRPW32.EXE)

    private static let exitSign = (x: 550, y: 415)                 // FUN_0041239c
    private static let dresser = (x: 209, y: 248)                  // 0x4413c2
    /// Drop targets (left, top, right, bottom): two booths, then the dresser (0x4413c8).
    private static let targets = [(59, 152, 177, 387), (434, 247, 528, 388), (213, 248, 387, 401)]
    /// Drawers: hats, tops, bottoms (0x4413e0).
    private static let drawers = [(213, 248, 387, 306), (213, 305, 387, 355), (213, 355, 387, 401)]
    /// Clicks on the bush behind the dresser do nothing (0x4413f8).
    private static let bush = (191, 122, 414, 284)
    private static let anchorPos = [(65, 160), (451, 271)]         // 0x4413aa: 2501 / 2502
    private static let headPos = [(96, 160), (457, 271)]           // 2503 / 2504
    /// Item steps 67, 69, 70 and 72 do not exist (set 11 is a one-piece suit).
    private static let missing: Set<Int> = [0x43, 0x45, 0x46, 0x48]

    // MARK: Scripts (1/2 = speaker, 100–103 = light a drawer, <0 = pause, 0 = end)

    private static let intros: [[Int]] = [                         // 0x4414dc
        [1, 22126, -2, 2, 22022, -2, 1, 22118, 22119, 101, 22120, 102, 22121, 103, 22122, 100, 0],
        [1, 22126, -2, 2, 22022, -2, 1, 22118, 0], [2, 22019, 0], [1, 22128, 0], [1, 22129, 0], [2, 22021, 0],
    ]
    private static let help: [[Int]] = [                           // 0x441560
        [1, 22117, 0], [1, 22118, 0], [1, 22119, 0],
        [1, 101, 22120, 100, 0], [1, 102, 22121, 100, 0], [1, 103, 22122, 100, 0],
    ]

    // MARK: Actors

    private var anchors: [Actor?] = [nil, nil]                     // slots 0–1 (offset per costume)
    private var heads: [Actor?] = [nil, nil]                       // slots 2–3
    private var headHidden = [false, false]
    private var item: Actor?                                       // slot 5
    private var itemHidden = false
    private var drag: Actor?                                       // slot 6 (copy being carried)
    private var dragOffset = (x: 0, y: 0)
    private var dragStart = (x: 0, y: 0)
    private var dragMoved = false
    private var pieces = [Actor?](repeating: nil, count: 6)        // slots 10–15
    private var stars = [Actor?](repeating: nil, count: 24)        // slots 20–43
    private var starDone = [Bool](repeating: false, count: 24)
    private var starPos: [(Int, Int)] = []                         // 0x441400

    // MARK: Game state

    private var state = -1                // DAT_00446e78
    private var ticks = 0
    private var now: Int { ticks * 1000 / fps }
    private var deadline = 0              // DAT_00446e8c
    private var helpIndex = -1            // DAT_00446e84
    private var lastBooth = 0             // DAT_00446e88
    private var sets = Array(1...11)      // DAT_00446eb0 (costume sets, front = current)
    private var kinds = Array(1...6)      // DAT_00446ec8 (1–3 for char 0, 4–6 for char 1)
    private var kindCursor = 0            // DAT_00446ee0
    private var lastDrawer = -1           // DAT_00446ee2
    private var worn = [Int](repeating: 0, count: 6)       // DAT_00446ed4: item steps worn
    private var outfit = [Int](repeating: 0, count: 6)     // DAT_00446e98: costume per part
    private var snapshot = [Int](repeating: 0, count: 6)   // DAT_00446ea4
    private var names = [0, 0]            // speech ids in idle scripts 2/3 (0x44150e / 0x441514)
    private var owner = 0                 // DAT_00446e7c
    private var cueIndex = 0              // DAT_00446e7e
    private var celebrating = false       // DAT_00446e7a != 0
    private var drawerLight = 0           // DAT_00446ee4
    private var blink = [0, 0]            // DAT_00446e6a

    private var script: [Int]?
    private var scriptPos = 0
    private var scriptDelay = 0
    private var scriptSpeech = 0
    private var speaker = 0               // DAT_00446e64

    init() {}

    // MARK: EXE tables

    private func s16(_ game: Game, _ va: Int) -> Int {
        Int(Int16(truncatingIfNeeded: game.exe?.u32(at: va) ?? 0))
    }

    // MARK: Enter / exit (FUN_00414129, FUN_00414074)

    func enter(_ game: Game) {
        game.setBackground(2500, palette: 2500)
        if let a = game.res.aseq(212), let f = a.frame(0) { game.fb.stamp(f, x: Self.exitSign.x, y: Self.exitSign.y) }
        Self.lastMusic = Self.lastMusic != 30608 ? 30608 : 30607
        state = -1
        lastBooth = 0
        starPos = (0..<24).map { (s16(game, 0x441400 + 6 * $0), s16(game, 0x441402 + 6 * $0)) }
        setUp(game)
    }

    func exit(_ game: Game) { game.stopMusic() }

    private func leave(_ game: Game) {
        // FUN_00413bef: transition 0x1c, WAVE 32010 + random(8) at the cut.
        game.change(to: ExteriorScene(.patternParade), sound: 32010 + game.random(8))
    }

    private func actor(_ game: Game, _ id: Int, _ x: Int, _ y: Int, _ step: Int) -> Actor? {
        game.res.aseq(id).map { Actor($0, x: x, y: y, step: step) }
    }

    /// FUN_0041250f.
    private func setUp(_ game: Game) {
        stars = Array(repeating: nil, count: 24)
        worn = Array(repeating: 0, count: 6)
        kinds = Array(1...6)
        for i in 0..<6 { kinds.swapAt(i, game.random(6)) }
        sets = Array(1...11)
        for i in 0..<11 { sets.swapAt(i, game.random(11)) }
        for p in 0..<2 {
            anchors[p] = actor(game, 2501 + p, Self.anchorPos[p].0, Self.anchorPos[p].1, 1)
            heads[p] = actor(game, 2503 + p, Self.headPos[p].0, Self.headPos[p].1, 1)
            headHidden[p] = false
            let r = anchors[p]?.rect ?? Rect(x: 0, y: 0, w: 0, h: 0)
            for k in 0..<3 {
                outfit[p * 3 + k] = 0
                snapshot[p * 3 + k] = 0
                pieces[p * 3 + k] = actor(game, p == 0 ? 2550 : 2570, r.x, r.y, k + 3)
            }
        }
        lastDrawer = -1
        kindCursor = 0
        while Self.missing.contains(sets[0] * 6 + kinds[0]) { nextSet(game) }
        item = game.res.aseq(2506).map { Actor($0) }
        placeItem(sets[0] * 6 + kinds[0])
        updateNames(game)
        drag = nil
        itemHidden = false
        celebrating = false
        script = nil
    }

    // MARK: Choosing the piece on the dresser

    private func updateNames(_ game: Game) {
        names = [s16(game, 0x441578 + 2 * sets[0]), s16(game, 0x441590 + 2 * sets[0])]
    }

    /// FUN_00412863.
    private func nextSet(_ game: Game) {
        sets.append(sets.removeFirst())
        updateNames(game)
    }

    /// FUN_004128b1.
    private func nextKind() { kinds.append(kinds.removeFirst()) }

    private func usable(_ s: Int) -> Bool { !worn.contains(s) && !Self.missing.contains(s) }

    /// Centre the piece on top of the dresser.
    private func placeItem(_ s: Int) {
        guard let item, let st = item.aseq.step(s), let f = item.aseq.frame(st.frame) else { return }
        item.step = s
        item.x = (213 + 387 - (st.dx + f.width)) / 2
        item.y = 248 - 10 - (st.dy + f.height)
    }

    /// FUN_004128dd: after a drop, put the next unused piece on the dresser.
    private func nextItem(_ game: Game) {
        while true {
            kindCursor += 1
            if kindCursor > 5 { kindCursor = 0; nextSet(game) }
            let s = sets[0] * 6 + kinds[kindCursor]
            guard usable(s) else { continue }
            placeItem(s)
            drag = nil
            dragMoved = false
            itemHidden = false
            return
        }
    }

    /// FUN_004139bb: a drawer was clicked.
    private func openDrawer(_ game: Game, _ d: Int) {
        while kindCursor != 0 { nextKind(); kindCursor -= 1 }
        while true {
            if d == lastDrawer { nextKind(); lastDrawer = -1 } else { nextSet(game); lastDrawer = d }
            for _ in 0..<6 where kinds[0] != d + 1 && kinds[0] != d + 4 { nextKind() }
            let s = sets[0] * 6 + kinds[0]
            guard usable(s) else { continue }
            if drag == nil { placeItem(s) }
            return
        }
    }

    // MARK: Dressing (FUN_00413ae5 / FUN_00412a61 / FUN_004129ff)

    private func dress(_ game: Game, _ p: Int, _ part: Int, _ v: Int) {
        outfit[p * 3 + part] = v
        anchors[p]?.step = v + 1
        let r = anchors[p]?.rect ?? Rect(x: 0, y: 0, w: 0, h: 0)
        let id = v < 12 ? (p == 0 ? 2550 : 2570) + v : (p == 0 ? 2750 : 2770) + v - 12
        pieces[p * 3 + part] = actor(game, id, r.x, r.y, part == 0 ? 2 : part + 3)
    }

    private func pickUp(x: Int? = nil, y: Int? = nil) {
        guard let item, drag == nil else { return }
        drag = Actor(item.aseq, x: item.x, y: item.y, step: item.step)
        let point = (x ?? item.rect.midX, y ?? item.rect.midY)
        dragOffset = (point.0 - item.x, point.1 - item.y)
        dragStart = point
        dragMoved = false
        itemHidden = true
    }

    private func cancelDrag() {
        guard drag != nil else { return }
        drag = nil
        dragMoved = false
        itemHidden = false
    }


    private func drop(_ game: Game, _ x: Int, _ y: Int) {
        guard drag != nil else { return }
        guard let k = Self.targets.firstIndex(where: { inside($0, x, y) }) else { cancelDrag(); return }
        if k > 1 { nextItem(game); return }
        let kind = kinds[kindCursor]
        names[k] = 0
        let v = (k == 0) == (kind < 4) ? sets[0] : sets[0] + 12
        let s = sets[0] * 6 + kind, part = (kind - 1) % 3
        worn[part + k * 3] = s
        if (k == 0 && s == 0x44) || (k == 1 && s == 0x47) {          // one-piece suit
            worn[k * 3] = s - 1
            dress(game, k, 0, v)
            worn[k * 3 + 2] = s + 1
            dress(game, k, 2, v)
        } else if part == 1, (k == 0 && worn[2] == 0x45) || (k == 1 && worn[5] == 0x48) {
            worn[k * 3 + 2] = 0
            dress(game, k, 2, 0)
            snapshot[k * 3 + 2] = outfit[k * 3 + 2]
        }
        dress(game, k, part, v)
        nextItem(game)
        if v > 11 {
            runScript(game, [k + 1, k == 0 ? 22170 + game.random(12) : 22061 + game.random(11), 0], speaker: k)
        }
        var changed = true, matched = v
        for i in 0..<3 {
            if outfit[k * 3 + i] == snapshot[k * 3 + i] { changed = false }
            if outfit[k * 3 + i] != outfit[k * 3] { matched = -1 }
        }
        if changed || (matched != -1 && matched < 12) {
            for i in 0..<3 { snapshot[k * 3 + i] = outfit[k * 3 + i] }
        }
        if matched != -1, matched < 12 {                              // whole outfit
            cueIndex = k + matched * 2
            owner = k
            runScript(game, [k + 1, s16(game, 0x4415ae + cueIndex * 8), 0], speaker: k)
            itemHidden = true
            state = 5
            return
        }
        guard changed else { return }
        runScript(game, [k + 1, k == 0 ? 22130 + game.random(9) : 22025 + game.random(11), 0], speaker: k)
    }

    // MARK: Outfit celebration (FUN_004131de / FUN_0041316e)

    private func celebrate(_ game: Game, _ p: Int) {
        let x = pieces[p * 3]?.x ?? 0, y = pieces[p * 3]?.y ?? 0
        for k in 0..<3 { pieces[p * 3 + k] = nil }
        headHidden[p] = true
        pieces[p * 3] = actor(game, (p == 0 ? 2510 : 2530) + outfit[p * 3], x, y, 1)
        celebrating = true
    }

    private func endCelebration(_ game: Game, _ p: Int) {
        itemHidden = drag != nil
        for k in 0..<3 { dress(game, p, k, outfit[p * 3 + k]) }
        headHidden[p] = false
    }

    // MARK: Scripts (FUN_00412e70 / FUN_00412f4c) and heads (FUN_00413025)

    private func runScript(_ game: Game, _ s: [Int], speaker p: Int) {
        game.stopSpeech()
        script = s
        scriptPos = 0
        scriptDelay = 0
        speaker = p
    }

    private func stepScript(_ game: Game) -> Bool {
        guard let s = script else { return true }
        if game.mouth != nil || (game.speechPlaying && game.currentSpeech == scriptSpeech) { return false }
        if scriptDelay > 0 { scriptDelay -= 1; return false }
        let v = scriptPos < s.count ? s[scriptPos] : 0
        if v == 0 { return true }
        if v < 0 {
            scriptDelay = -v
        } else if v <= 10 {
            speaker = v - 1
        } else if (100...199).contains(v) {
            drawerLight = v - 100
        } else {
            game.stopSpeech()
            game.sayWithLips(v)
            scriptSpeech = v
        }
        scriptPos += 1
        return false
    }

    private func animateHeads(_ game: Game) {
        guard !celebrating else { return }
        for p in 0..<2 {
            guard let h = heads[p], !headHidden[p] else { continue }
            if p == speaker, let m = game.mouth {
                h.step = m + 1
            } else if blink[p] < 1, game.random(5) == 0 {
                blink[p] = 10
                h.step = 2
            } else {
                if blink[p] > 0 { blink[p] -= 1 }
                h.step = 1
            }
        }
    }

    // MARK: Tick (FUN_004133ba logic block)

    func tick(_ game: Game) {
        ticks += 1
        if state < 0 {
            if game.speechPlaying { return }
            state = 0
        }
        if !game.audio.musicPlaying, game.player.soundOn { game.playMusic(Self.lastMusic, loop: true) }

        animateHeads(game)
        if script != nil, stepScript(game) { script = nil }
        for i in 0..<24 {
            guard let s = stars[i], !starDone[i] else { continue }
            if s.advance() != .moved, s.step > 2 { starDone[i] = true }
        }
        if celebrating, let c = pieces[owner * 3], c.advance() != .moved { celebrating = false }
        if state != 4 { deadline = now + 20000 }

        switch state {
        case 0:
            Self.introIndex += 1
            if Self.introIndex > 5 { Self.introIndex = 1 }
            runScript(game, Self.intros[Self.introIndex], speaker: 0)
            helpIndex = -1
            state = 1
        case 1:
            if script == nil { state = 4 }
        case 2:
            helpIndex = (helpIndex + 1) % 6
            runScript(game, Self.help[helpIndex], speaker: 0)
            state = 3
        case 3:
            if script == nil { state = 4 }
        case 4:
            idle(game)
        case 5:
            if script == nil { state = 6 }
        case 6:
            celebrate(game, owner)
            state = 7
        case 7:
            if !celebrating {
                guard !game.speechPlaying else { break }
                endCelebration(game, owner)
                state = 8
            } else if pieces[owner * 3]?.step == s16(game, 0x441668 + cueIndex * 4) {
                game.say(s16(game, 0x44166a + cueIndex * 4))
            }
        case 8:
            let i = outfit[owner * 3] + (owner != 0 ? 12 : 0)
            if i < 24, i < starPos.count {
                stars[i] = actor(game, 2590 + game.random(4), starPos[i].0, starPos[i].1, 1)
                starDone[i] = false
            }
            game.say(2202)
            state = 4
        default:
            break
        }
    }

    /// FUN_004132e6: after 20 s without input one of the characters speaks.
    private func idle(_ game: Game) {
        guard deadline < now else { return }
        var s: [Int]
        repeat {
            Self.idleIndex = (Self.idleIndex + 1) % 6
            let scripts = [[1, 22158, 0], [2, 22052, 0], [1, names[0], 0], [2, names[1], 0], [1, 22159, 0], [2, 22053, 0]]
            s = scripts[Self.idleIndex]
            if s[1] == 0 || (lastBooth != 0 && s[0] != lastBooth) { s = [] }
        } while s.isEmpty
        lastBooth = 0
        runScript(game, s, speaker: 0)
        state = 3
    }

    /// FUN_00413bc5.
    private func ready(_ game: Game) -> Bool {
        if state == 7 { game.stopSpeech() }
        return state == 4
    }

    // MARK: Input

    private func inside(_ r: (Int, Int, Int, Int), _ x: Int, _ y: Int) -> Bool {
        x >= r.0 && x < r.2 && y >= r.1 && y < r.3
    }

    /// Any input cuts a running script short.
    private func interrupt(_ game: Game) {
        guard script != nil else { return }
        drawerLight = 0
        game.stopSpeech()
        script = nil
        if state == 1 || state == 3 { state = 4 }
    }

    func click(_ game: Game, x: Int, y: Int) {
        if state < 0 { game.stopSpeech(); return }
        interrupt(game)
        if inside((Self.exitSign.x, Self.exitSign.y, Self.exitSign.x + 73, Self.exitSign.y + 43), x, y) {
            leave(game)
            return
        }
        deadline = now + 20000
        guard ready(game) else { return }
        if drag != nil { drop(game, x, y); return }
        if var r = item?.rect, !itemHidden {
            if r.h < 30 { r = Rect(x: r.x - 10, y: r.y - 10, w: r.w + 20, h: r.h + 20) }
            if x >= r.x, x < r.x + r.w, y >= r.y, y < r.y + r.h { pickUp(x: x, y: y); return }
        }
        if let k = Self.targets.prefix(2).firstIndex(where: { inside($0, x, y) }) {
            lastBooth = k + 1
            if k == 0 {
                Self.leftToggle.toggle()
                if !Self.leftToggle { state = 2; return }
            }
            deadline = 0
            return
        }
        if let d = Self.drawers.firstIndex(where: { inside($0, x, y) }) {
            game.say(7103 + game.random(5))
            openDrawer(game, d)
            return
        }
        if !inside(Self.bush, x, y) { state = 2 }
    }

    func mouseMoved(_ game: Game, x: Int, y: Int) {
        guard let drag else { return }
        dragMoved = dragMoved || x != dragStart.x || y != dragStart.y
        drag.x = x - dragOffset.x
        drag.y = y - dragOffset.y
    }

    func mouseUp(_ game: Game, x: Int, y: Int) {
        guard drag != nil, dragMoved else { return }
        drop(game, x, y)
    }

    func key(_ game: Game, _ key: Key) {
        if state < 0 { game.stopSpeech(); return }
        interrupt(game)
        deadline = now + 20000
        switch key {
        case .escape:
            leave(game)
        case .space:
            guard ready(game), drag == nil else { return }
            game.say(7103 + game.random(5))
            openDrawer(game, game.random(3))
        case .char("1"):
            if ready(game) { state = 2 }
        case .left, .right:
            guard ready(game) else { return }
            if drag == nil {
                game.say(7103 + game.random(5))
                pickUp()
            }
            let t = Self.targets[key == .right ? 1 : 0]
            drop(game, t.0, t.1)
        default:
            break
        }
    }

    // MARK: Drawing (draw list in FUN_004133ba)

    func draw(_ game: Game, _ fb: Framebuffer) {
        if let a = game.res.aseq(2505) {
            let step = drawerLight * 2 + (drawerLight == 0 ? 1 : 0)
            if let s = a.step(step), let f = a.frame(s.frame) { fb.draw(f, x: Self.dresser.x, y: Self.dresser.y) }
        }
        for case let s? in stars { s.draw(fb) }
        for i in stride(from: 5, through: 0, by: -1) {
            if i == 0 || i == 3, !headHidden[i / 3] { heads[i / 3]?.draw(fb) }
            pieces[i]?.draw(fb)
        }
        if !itemHidden { item?.draw(fb) }
        if let d = drag {   // carried piece, lifted a little (no mouse-move events)
            d.y -= 8
            d.draw(fb)
            d.y += 8
        }
    }
}
