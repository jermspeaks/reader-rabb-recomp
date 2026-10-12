import Foundation

/// Parent menu ("POP", Ctrl+P in the original): RRPW32.EXE overlay layer B.
///
/// Original: ParentMenu_Enter FUN_0041ce84 builds the panel (FUN_0041c344) and
/// draws it (FUN_0041b646 -> FUN_0041b5af) over whatever scene is running, with
/// key FUN_0041b943, click FUN_0041b737, tick FUN_0041c6e8 and exit FUN_0041cdfd.
/// The overlay never loads a palette; all of its art uses palette indices
/// 0..48 / 224..255, which are identical in nearly every scene palette (RRGB 2000
/// matches every index the panel uses), so this port shows it over the
/// main-menu background with palette 2000.
///
/// In this port it is a normal scene: closing it goes to the main menu.
final class ParentMenuScene: Scene {
    // MARK: Resource ids (RRPW32.EXE tables)

    /// Panel, "eyes" in the panel's top-right notch, DONE button.
    private static let panelId = 22301, eyesId = 22300, doneId = 22320
    /// Main-page buttons in table order (0x441e7c): Skills, Education, Levels,
    /// Upper/lower case, Menu, Sign-in, Movement, Sound on/off, Exit.
    private static let buttonIds = [22302, 22303, 22304, 22305, 22306, 22307, 22310, 22308, 22309]
    /// Speech per main button (0x441e86 indexed by slot+1). Case: 1232 upper /
    /// 1233 lower; sound: 1238 turning off / 1239 turning on; Exit has none.
    private static let buttonSounds = [1237, 1210, 1234, 1233, 1235, 1220, 1231, 1239, 0]
    /// Education/Movement buttons (0x441ea0): three topic buttons
    /// ("Did you know", "About school readiness", "The Reader Rabbit series"),
    /// then "Back a page" and "Next page".
    private static let topicIds = [22322, 22321, 22323]
    private static let prevId = 22330, nextId = 22331
    /// Skills chart (full screen) and its DONE button (0x441f2a).
    private static let skillsChartId = 22360, skillsDoneId = 22361
    private static let skillsDonePos = (x: 540, y: 408)
    /// Movement page pictures, indexed by page number (0x441ec4: x, y, ASEQ).
    private static let movementPictures: [Int: (x: Int, y: Int, id: Int)] = [
        3: (374, 140, 22353), 4: (362, 126, 22352), 5: (378, 122, 22351),
        7: (271, 174, 22354), 8: (279, 178, 22355), 9: (384, 138, 22356), 10: (398, 130, 22357),
    ]
    /// TEXT resources: 1001 = Education, 1002 = Movement.
    private static let educationText = 1001, movementText = 1002
    /// Fonts: TEXT pages 1012 (0x3f4); LEVELS title/digits/radio 1018 (0x3fa);
    /// LEVELS activity names 1014 (0x3f6).
    private static let textFontId = 1012, bigFontId = 1018, nameFontId = 1014
    /// EXE strings: activity names in menu order (0x441eb4), "LEVELS" (0x441f0e).
    private static let namesTable = 0x441eb4, levelsTitle = 0x441f0e

    // MARK: State

    /// DAT_00447ac2: 0 main, 1 skills, 2 education, 3 levels, 4 movement.
    private enum Page { case main, skills, education, levels, movement }

    private enum Target: Equatable {
        case done, button(Int), topic(Int), prev, next
    }

    private enum Action {
        case open(Page), back, indexPage, section(Int), prev, next, mainMenu, signIn, quit
    }

    private var page = Page.main
    private var panel: Actor?
    private var eyes: Actor?
    private var done: Actor?
    private var buttons: [Actor?] = []
    private var topics: [Actor?] = []
    private var prevButton: Actor?
    private var nextButton: Actor?
    private var skillsChart: Actor?
    private var skillsDone: Actor?
    private var picture: Actor?

    private var panelX = 0, panelY = 0, panelW = 0, panelH = 0

    /// Button being pressed (DAT_00447a86) and whether its action has fired (DAT_00447a88).
    private var pressed: (target: Target, actor: Actor, fired: Bool)?
    /// Deferred action (DAT_00447a84); runs once the eyes and the button are idle.
    private var pending: Action?
    /// Eyes animation mode (DAT_00447a8a; 0 = idle) and next idle-blink time (DAT_00447a8c).
    private var eyesMode = 0
    private var eyesStopped = true
    private var idleAt: TimeInterval = 0

    /// TEXT page state: document, current page (DAT_00447ab6), first/last page
    /// of the current range (DAT_00447ab2 / DAT_00447ab4) and section bounds
    /// (DAT_00447aba..ac0).
    private var text: [UInt8] = []
    private var pageNo = 1
    private var firstPage = 0, lastPage = 0
    private var bounds = [1, 1, 1, 1]
    private var runs: [TextRun] = []

    private var textFont: BitmapFont?
    private var bigFont: BitmapFont?
    private var nameFont: BitmapFont?
    private var names: [String] = []
    private var title: [UInt8] = []

    init() {}

    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    // MARK: Scene

    func enter(_ game: Game) {
        game.setBackground(2000, palette: 2000)
        textFont = game.res.font(Self.textFontId)
        bigFont = game.res.font(Self.bigFontId)
        nameFont = game.res.font(Self.nameFontId)
        let exeNames = game.exe?.stringTable(at: Self.namesTable, count: 4) ?? []
        names = (0..<4).map { i in
            (i < exeNames.count ? exeNames[i] : nil) ?? Activity(rawValue: i)?.name ?? ""
        }
        title = (game.exe?.cString(at: Self.levelsTitle) ?? "").macRoman
        buildMain(game)
        idleAt = now + 10 // first idle blink after 10 s (FUN_0041c344)
    }

    /// FUN_0041c344: centre the panel and lay out the eyes, DONE and the 3×3 buttons.
    private func buildMain(_ game: Game) {
        page = .main
        picture = nil
        if let a = game.res.aseq(Self.panelId), let f = a.frame(0) {
            panelW = f.width
            panelH = f.height
            panelX = (640 - panelW) / 2
            panelY = (480 - panelH) / 2
            panel = Actor(a, x: panelX, y: panelY, step: 1)
        }
        if let a = game.res.aseq(Self.eyesId), let f = a.frame(0) {
            eyes = Actor(a, x: panelX + panelW + 5 - f.width, y: panelY + 2, step: 1)
        }
        if let a = game.res.aseq(Self.doneId), let f = a.frame(0) {
            done = Actor(a, x: panelX + panelW - 0x38 - f.width, y: panelY + panelH - 0x1E - f.height, step: 1)
        }
        // Rows of three: x starts at panel+50 with 10 px gaps; rows 10 px apart,
        // the first row 30 px below the panel top.
        buttons = []
        var x = 0, y = panelY, prevW = 0, prevH = 0x14
        for (i, id) in Self.buttonIds.enumerated() {
            x += prevW + 10
            if i % 3 == 0 {
                x = panelX + 0x32
                y += prevH + 10
            }
            guard let a = game.res.aseq(id), let f = a.frame(0) else { buttons.append(nil); continue }
            prevW = f.width
            prevH = f.height
            let b = Actor(a, x: x, y: y, step: 1)
            buttons.append(b)
        }
        syncToggleButtons(game)
    }

    /// Upper/lower case and sound buttons show their second state at step 4.
    private func syncToggleButtons(_ game: Game) {
        if buttons.count > 7 {
            buttons[3]?.step = game.player.lowercase ? 4 : 1
            buttons[7]?.step = game.player.soundOn ? 1 : 4
        }
    }

    /// FUN_0041c225: TEXT page set (Education/Movement).
    private func openText(_ game: Game, _ id: Int, page p: Page) {
        page = p
        text = []
        if let d = game.res.raw("TEXT", id) {
            let bytes = [UInt8](d)
            text = Array(bytes.prefix { $0 != 0 })
        }
        guard !text.isEmpty else { close(game); return } // original closes the overlay
        firstPage = 0
        lastPage = 0
        pageNo = 1
        picture = nil
        topics = []
        var x = panelX + 0x14, w = 0
        let y = done?.y ?? 0
        for (i, id) in (Self.topicIds + [Self.prevId, Self.nextId]).enumerated() {
            x += 4 + w
            if i == 3 { x = panelX + 0x36 }
            guard let a = game.res.aseq(id), let f = a.frame(0) else {
                if i < 3 { topics.append(nil) }
                continue
            }
            let actor = Actor(a, x: x, y: y, step: 1)
            switch i {
            case 0..<3: topics.append(actor)
            case 3: prevButton = actor
            default: nextButton = actor
            }
            w = f.width
        }
        relayout()
    }

    private func relayout() {
        if page == .movement {
            // FUN_0041be3e: clamp to the document's page range.
            if pageNo < firstPage || pageNo > lastPage { pageNo = 1 }
        }
        runs = layoutPage(pageNo)
        if page == .movement {
            firstPage = bounds[0]
            lastPage = bounds[1]
        }
    }

    func tick(_ game: Game) {
        // FUN_0041c6e8
        if eyesMode != 0 && eyesStopped { eyesMode = 0 }
        if eyesMode == 0 && now > idleAt { startEyes(14) }
        if !eyesStopped, let eyes { eyesStopped = Self.advance(eyes) }
        if let p = picture {
            let next = p.step + 1
            p.step = (p.aseq.step(next)?.frame ?? -1) < 0 ? 1 : next // loops forever
        }
        if var pr = pressed {
            let stopped = Self.advance(pr.actor)
            if stopped, page == .main { syncToggleButtons(game) }
            if pr.fired {
                pressed = nil
            } else {
                pr.fired = true
                pressed = pr
                fire(game, pr.target)
            }
        }
        if let a = pending, eyesMode == 0, pressed == nil {
            perform(game, a)
        }
    }

    /// Advance one ASEQ step; at a control code go back to step 1 and stop (FUN_0041c623).
    @discardableResult
    private static func advance(_ a: Actor) -> Bool {
        let next = a.step + 1
        if (a.aseq.step(next)?.frame ?? -1) < 0 {
            a.step = 1
            return true
        }
        a.step = next
        return false
    }

    /// FUN_0041c699: play an eyes animation (1: steps 2-5, 7: steps 8-12, 14: steps 15-22).
    private func startEyes(_ mode: Int) {
        guard eyesMode == 0, let eyes else { return }
        eyesMode = mode
        eyesStopped = false
        eyes.step = mode + 1
        idleAt = now + 5
    }

    /// FUN_0041c5d1: start a button press.
    private func press(_ target: Target, _ actor: Actor) {
        pressed = (target, actor, false)
        var quick = target == .done
        if page == .main, case .button(let i) = target, [4, 5, 8].contains(i) { quick = true }
        startEyes(quick ? 1 : 7)
    }

    /// First tick of a press: immediate effects and the deferred action.
    private func fire(_ game: Game, _ target: Target) {
        switch (page, target) {
        case (.main, .button(let i)):
            var sound = Self.buttonSounds[i]
            switch i {
            case 0: pending = .open(.skills)
            case 1: pending = .open(.education)
            case 2: pending = .open(.levels)
            case 3:
                game.player.lowercase.toggle()
                game.player.save()
                if !game.player.lowercase { sound = 1232 }
            case 4: pending = .mainMenu
            case 5: pending = .signIn
            case 6: pending = .open(.movement)
            case 7:
                // DAT_00445be0: the "off" speech is forced through before muting.
                sound = 0
                setSound(game, on: !game.player.soundOn)
            case 8: pending = .quit
            default: break
            }
            if sound != 0 { game.say(sound) }
        case (.education, .done):
            pending = pageNo < 2 ? .back : .indexPage
        case (_, .done):
            pending = .back
        case (.education, .topic(let k)):
            pending = .section(k)
        case (_, .prev):
            pending = .prev
        case (_, .next):
            pending = .next
        default:
            break
        }
    }

    private func setSound(_ game: Game, on: Bool) {
        game.player.soundOn = on
        if on {
            game.audio.enabled = true
            game.say(1239)
        } else {
            game.audio.enabled = true
            game.say(1238)
            game.audio.enabled = false
            game.stopMusic()
        }
        game.player.save()
    }

    private func perform(_ game: Game, _ a: Action) {
        switch a {
        case .open(.skills):
            page = .skills
            if let c = game.res.aseq(Self.skillsChartId) { skillsChart = Actor(c, x: 0, y: 0, step: 0) }
            if let d = game.res.aseq(Self.skillsDoneId) {
                skillsDone = Actor(d, x: Self.skillsDonePos.x, y: Self.skillsDonePos.y, step: 1)
            }
        case .open(.education):
            openText(game, Self.educationText, page: .education)
        case .open(.movement):
            openText(game, Self.movementText, page: .movement)
        case .open(let p):
            page = p
        case .back:
            buildMain(game)
        case .indexPage:
            pageNo = 1
            relayout()
        case .section(let k):
            firstPage = bounds[k] + 1
            lastPage = bounds[k + 1]
            pageNo = firstPage
            relayout()
        case .prev:
            pageNo -= 1
            if page == .movement { loadPicture(game) }
            relayout()
        case .next:
            pageNo += 1
            if page == .movement { loadPicture(game) }
            relayout()
        case .mainMenu, .signIn:
            // Waits for the button's speech (FUN_004351df), then leaves. The
            // port has no sign-in screen, so Sign-in also returns to the menu.
            if game.speechPlaying { return }
            close(game)
        case .quit:
            // The original opens the quit confirmation (FUN_0041d403).
            game.requestQuit()
        }
        pending = nil
    }

    /// FUN_0041c110: picture for the current Movement page.
    private func loadPicture(_ game: Game) {
        picture = nil
        if let p = Self.movementPictures[pageNo], let a = game.res.aseq(p.id) {
            picture = Actor(a, x: p.x, y: p.y, step: 1)
        }
    }

    private func close(_ game: Game) {
        game.change(to: MainMenuScene())
    }

    // MARK: Input

    func click(_ game: Game, x: Int, y: Int) {
        // FUN_0041b737
        guard pending == nil, pressed == nil else { return }
        switch page {
        case .main:
            for i in stride(from: buttons.count - 1, through: 0, by: -1) {
                if let b = buttons[i], b.rect.contains(x, y) { press(.button(i), b); return }
            }
        case .skills:
            if let d = skillsDone, d.rect.contains(x, y) { press(.done, d) }
            return
        case .education, .levels, .movement:
            if let d = done, d.rect.contains(x, y) { press(.done, d); return }
            if page == .levels {
                levelsClick(game, x, y)
            } else {
                if page == .education && pageNo == 1 {
                    for (k, t) in topics.enumerated() {
                        if let t, t.rect.contains(x, y) { press(.topic(k), t); return }
                    }
                } else {
                    if pageNo > firstPage, let p = prevButton, p.rect.contains(x, y) { press(.prev, p); return }
                    if pageNo < lastPage, let n = nextButton, n.rect.contains(x, y) { press(.next, n); return }
                }
            }
        }
        // Clicking the eyes or outside the panel closes the overlay.
        let onEyes = eyes?.rect.contains(x, y) ?? false
        let inPanel = panel?.rect.contains(x, y) ?? false
        if onEyes || !inPanel { close(game) }
    }

    func key(_ game: Game, _ key: Key) {
        // FUN_0041b943: ESC closes the overlay.
        if key == .escape, pending == nil { close(game) }
    }

    // MARK: LEVELS (FUN_0041bf78 draw / FUN_0041b9a3 click)

    private static let levelColumnX = 0x144, levelColumnStep = 0x20
    private static let levelRowY = 0xAD, levelRowStep = 0x1E

    private func levelsClick(_ game: Game, _ x: Int, _ y: Int) {
        for row in 0..<4 {
            let ry = Self.levelRowY + row * Self.levelRowStep
            for col in 0..<4 {
                let cx = Self.levelColumnX + col * Self.levelColumnStep
                let r = Rect(x: cx - 5, y: ry - 0x14, w: 0x19, h: 0x19)
                guard r.contains(x, y) else { continue }
                if col == game.player.level[row] { return }
                // FUN_004310e3: set level and reset progress / used content.
                game.player.level[row] = col
                game.player.progress[row] = 0
                game.player.usedContent[row] = []
                game.player.save()
                startEyes(7)
                return
            }
        }
    }

    private func drawLevels(_ game: Game, _ fb: Framebuffer) {
        guard let big = bigFont else { return }
        fb.drawText(title, font: big, x: 0x140 - big.width(of: title) / 2, y: 0x71, color: 6)
        for col in 0..<4 {
            fb.drawText([UInt8(0x31 + col)], font: big,
                        x: Self.levelColumnX + col * Self.levelColumnStep, y: 0x8F, color: 6)
        }
        for row in 0..<4 {
            let y = Self.levelRowY + row * Self.levelRowStep
            if let nf = nameFont { fb.drawText(names[row].macRoman, font: nf, x: 0xB8, y: y, color: 6) }
            let level = max(0, min(3, game.player.level[row]))
            for col in 0..<4 {
                let x = Self.levelColumnX + col * Self.levelColumnStep
                fb.drawText([0x1F], font: big, x: x, y: y, color: 6) // empty circle
                if col == level { fb.drawText([0x1E], font: big, x: x, y: y, color: 6) } // dot
            }
        }
    }

    // MARK: TEXT layout (FUN_0041ba75, docs/formats.md §8)

    private struct TextRun {
        let x: Int, y: Int
        let bytes: [UInt8]
        let color: UInt8
    }

    private func layoutPage(_ wanted: Int) -> [TextRun] {
        guard let font = textFont else { return [] }
        let d = text
        func at(_ i: Int) -> UInt8 { i >= 0 && i < d.count ? d[i] : 0 }
        func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
        /// Copy bytes up to the next control character; returns the line and the index of that character.
        func line(_ i: Int) -> ([UInt8], Int) {
            var j = i
            while at(j) > 0x1F { j += 1 }
            return (Array(d[min(i, d.count)..<min(j, d.count)]), j)
        }
        /// sscanf-like: integers (and a final char) after the directive's comma.
        func fields(_ l: [UInt8], from start: Int) -> [[UInt8]] {
            guard l.count > start else { return [] }
            return l[start...].split(separator: 0x2C, omittingEmptySubsequences: false).map(Array.init)
        }
        func int(_ f: [UInt8]) -> Int? {
            let s = String(decoding: f, as: UTF8.self).trimmingCharacters(in: .whitespaces)
            return Int(s.prefix { $0 == "-" || $0.isNumber })
        }

        var runs: [TextRun] = []
        var color: UInt8 = 0xFF
        var p = 0
        var target = wanted
        // Find "&N" (and read the "&0,a,b,c,d" section line on the way).
        repeat {
            while at(p) != 0x26 {
                if at(p) == 0 { return runs }
                p += 1
            }
            let (l, end) = line(p)
            if isDigit(at(p + 1)) {
                if at(p + 1) == 0x30 && at(p + 2) == 0x2C {
                    let v = fields(l, from: 3).compactMap(int)
                    if v.count >= 4 {
                        bounds[0] = 1
                        bounds[1] = v[1] + 1
                        bounds[2] = bounds[1] + v[2]
                        bounds[3] = bounds[2] + v[3]
                    }
                } else if let n = int(Array(l.dropFirst())), n == target {
                    target = 0
                }
            }
            p = end + 1
        } while target != 0
        while at(p) != 0 && at(p) < 0x20 { p += 1 }

        var lineHeight = 0
        while at(p) == 0x26 {
            let c = at(p + 1)
            if isDigit(c) || c < 0x20 { break } // next page or the closing "&"
            let (l, end) = line(p)
            p = end
            if c == 0x54 { // "&T,x1,y1,x2,y2,skip,lineheight,align"
                let f = fields(l, from: 3)
                let v = f.prefix(6).compactMap(int)
                if v.count == 6, v[5] != 0 {
                    let x1 = v[0], x2 = v[2], skip = v[4]
                    lineHeight = v[5]
                    let centre = f.count > 6 && f[6].first == 0x63 // 'c'
                    var y = v[1] + (skip != 0 ? lineHeight * skip : 0)
                    repeat { p += 1 } while at(p) != 0 && at(p) < 0x20
                    while at(p) != 0x26 {
                        if p >= d.count { return runs }
                        let (src, lend) = line(p)
                        if src.isEmpty {
                            y += lineHeight
                        } else {
                            var start = 0
                            repeat {
                                y += lineHeight
                                var acc = 0, brk = 0, i = start
                                while i < src.count {
                                    acc += font.advance(src[i])
                                    if x2 - x1 < acc { break }
                                    if src[i] == 0x20 || i == src.count - 1 { brk = i + 1 }
                                    i += 1
                                }
                                if brk == 0 { brk = i }
                                if brk <= start { brk = start + 1 } // guard: glyph wider than the box
                                let piece = Array(src[start..<brk])
                                start = brk
                                var x = centre ? (x1 + x2 - acc) / 2 : x1
                                // '|' toggles between black (0xFF) and blue (6); the
                                // colour carries over across lines and blocks.
                                let segments = piece.split(separator: 0x7C, omittingEmptySubsequences: false)
                                for (k, seg) in segments.enumerated() {
                                    if !seg.isEmpty {
                                        let bytes = Array(seg)
                                        runs.append(TextRun(x: x + 0x40, y: y + 0x30, bytes: bytes, color: color))
                                        x += font.width(of: bytes)
                                    }
                                    if k < segments.count - 1 { color = color == 0xFF ? 6 : 0xFF }
                                }
                            } while start < src.count
                        }
                        p = lend + 1
                    }
                    continue
                }
            }
            // "&G,x,y" (picture position; the EXE table is used instead) and anything else.
            repeat { p += 1 } while at(p) != 0 && at(p) < 0x20
        }
        return runs
    }

    // MARK: Drawing (FUN_0041b5af + FUN_0041c6e8)

    func draw(_ game: Game, _ fb: Framebuffer) {
        panel?.draw(fb)
        if page != .skills { eyes?.draw(fb) }
        switch page {
        case .main:
            for b in buttons { b?.draw(fb) }
            return
        case .skills:
            skillsChart?.draw(fb)
            skillsDone?.draw(fb)
            return
        case .levels:
            drawLevels(game, fb)
        case .education, .movement:
            if let font = textFont {
                for r in runs { fb.drawText(r.bytes, font: font, x: r.x, y: r.y, color: r.color) }
            }
            if page == .education && pageNo == 1 {
                for t in topics { t?.draw(fb) }
            } else {
                if pageNo > firstPage { prevButton?.draw(fb) }
                if pageNo < lastPage { nextButton?.draw(fb) }
            }
            picture?.draw(fb)
        }
        done?.draw(fb)
    }
}
