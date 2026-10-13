import Foundation

/// Iris wipe (Fx_IrisOpen FUN_00435f68 / Fx_IrisClose FUN_004361f8): a circle
/// around (320, 240) that grows or shrinks 8 px every 40 ms, black outside.
/// The original blocks the frame loop while it runs; a click skips it.
struct Iris {
    enum Mode { case opening, closing }
    let mode: Mode
    private(set) var radius: Int
    static let maxRadius = 400
    /// One 8 px step per tick at 25 fps (40 ms).
    static let fps = 25

    init(_ mode: Mode) {
        self.mode = mode
        radius = mode == .opening ? 8 : Self.maxRadius
    }

    /// Advance one step; true when finished.
    mutating func step() -> Bool {
        radius += mode == .opening ? 8 : -8
        return radius <= 0 || radius >= Self.maxRadius
    }

    func draw(_ fb: Framebuffer) {
        let r = max(0, radius)
        for y in 0..<Framebuffer.height {
            let dy = y - 240
            guard abs(dy) < r else { fb.fill(x: 0, y: y, w: Framebuffer.width, h: 1, color: 0xFF); continue }
            let half = Int(Double(r * r - dy * dy).squareRoot())
            fb.fill(x: 0, y: y, w: 320 - half, h: 1, color: 0xFF)
            fb.fill(x: 320 + half, y: y, w: 320 - half, h: 1, color: 0xFF)
        }
    }
}

/// The generic cutscene player used by the intro, title, story carousel and
/// ending (Slideshow_Enter FUN_00433275, tick FUN_00432c5b, click FUN_0043316e,
/// key FUN_004331b3, exit FUN_0043323c, next FUN_00433424).
///
/// Each slide is a background plus one animation (ASEQ id+1) drawn at the
/// background origin. When the animation reaches a control step the slide is
/// done and the next background in the scene's list follows. Sounds are cued
/// by the animation step from per-slide tables in the EXE.
class SlideshowScene: Scene {
    /// Scene id (DAT_00448394) = first background.
    let id: Int
    /// Backgrounds after the first (tables 0x445b2a / 0x445b36).
    let slides: [Int]
    /// EXE VA of the per-slide cue table pointers ((step, WAVE) pairs, 0-terminated).
    let cueTable: Int?
    var actors: [Actor] = []
    private var finished: [Bool] = []
    /// First tick after entering shows step 0 (DAT_0044839a).
    private var started = false
    /// Current animation reached its end (DAT_0044839e).
    var slideDone = false
    /// Per-scene counter (DAT_004483a2).
    var counter = 0
    /// Index of the current slide (DAT_00448396).
    var slideIndex = 0
    private(set) var currentSlide: Int
    var paletteId: Int
    var iris: Iris?
    private var afterIris: (() -> Void)?

    var fps: Int { iris == nil ? 8 : Iris.fps }

    init(id: Int, slides: [Int] = [], cueTable: Int? = nil) {
        self.id = id
        self.slides = slides
        self.cueTable = cueTable
        currentSlide = id
        paletteId = id
    }

    func enter(_ game: Game) {
        show(game, slide: id, palette: id)
    }

    /// Bg_Set(slide, palette) and the slide's animation (ASEQ slide+1).
    func show(_ game: Game, slide: Int, palette: Int, animations: Int = 1) {
        currentSlide = slide
        paletteId = palette
        game.setBackground(slide, palette: palette)
        actors = (0..<animations).compactMap { game.res.aseq(slide + 1 + $0) }.map { Actor($0, x: 0, y: 0, step: 0) }
        finished = actors.map { _ in false }
    }

    // MARK: Tick

    func tick(_ game: Game) {
        if var i = iris {
            let done = i.step()
            iris = done ? nil : i
            if done { finishIris() }
            return
        }
        slideTick(game)
    }

    /// FUN_00432c5b generic path.
    func slideTick(_ game: Game) {
        guard started else { started = true; return }
        if slideDone {
            nextSlide(game)
            return
        }
        if advanceActors() || actors.isEmpty { slideDone = true }
        if let a = actors.first { cue(game, step: a.step) }
    }

    /// FUN_00432b8c: step each running animation; LOOP goes to step 1, any
    /// other control code shows the step after it and stops. True if any
    /// animation hit a control code.
    private func advanceActors() -> Bool {
        var hit = false
        for (i, a) in actors.enumerated() where !finished[i] {
            var s = a.step + 1
            if let st = a.aseq.step(s), st.frame < 0 {
                if st.frame == StepCode.loop {
                    s = 1
                } else {
                    s = a.step + 2
                    finished[i] = true
                }
                hit = true
            }
            if a.aseq.step(s) != nil { a.step = s } else { finished[i] = true; hit = true }
        }
        return hit
    }

    /// FUN_00434e68: play the WAVE cued at this step of the current slide.
    private func cue(_ game: Game, step: Int) {
        guard let base = cueTable, let exe = game.exe,
              let ptr = exe.u32(at: base + 4 * slideIndex), ptr != 0 else { return }
        for k in 0..<99 {
            guard let v = exe.u32(at: ptr + 4 * k) else { return }
            let s = Int(Int16(truncatingIfNeeded: v)), wave = Int(Int16(truncatingIfNeeded: v >> 16))
            if s == 0 { return }
            if s == step { game.say(wave); return }
        }
    }

    /// Advance to the next background in the list, or leave when it runs out.
    func nextSlide(_ game: Game) {
        guard slideIndex < slides.count else { next(game, skip: false); return }
        let slide = slides[slideIndex]
        slideIndex += 1
        slideDone = false
        counter = 0
        willShow(game, slide: slide)
    }

    /// Show `slide` (palette kept unless the subclass says otherwise).
    func willShow(_ game: Game, slide: Int) {
        show(game, slide: slide, palette: paletteId)
    }

    /// Slideshow_Next (FUN_00433424); `skip` = Space (or the intro ending).
    func next(_ game: Game, skip: Bool) {}

    func closeIris(then action: @escaping () -> Void) {
        iris = Iris(.closing)
        afterIris = action
    }

    func openIris() {
        iris = Iris(.opening)
        afterIris = nil
    }

    private func finishIris() {
        let a = afterIris
        afterIris = nil
        a?()
    }

    // MARK: Input

    /// FUN_0043316e: the carousel and ending skip to the next slide; others leave.
    func click(_ game: Game, x: Int, y: Int) {
        if iris != nil { iris = nil; finishIris(); return }
        next(game, skip: false)
    }

    /// Stop speech and move on at the next tick (carousel / ending clicks).
    func skipSlide(_ game: Game) {
        game.stopSpeech()
        slideDone = true
        counter = 9999
    }

    /// FUN_004331b3: ESC quits, Enter / Ctrl-C continue, Space skips.
    func key(_ game: Game, _ key: Key) {
        guard iris == nil else { return }
        switch key {
        case .escape: game.requestQuit()
        case .enter, .char("\u{3}"): next(game, skip: false)
        case .space: next(game, skip: true)
        default: break
        }
    }

    /// FUN_0043323c.
    func exit(_ game: Game) {
        game.stopMusic()
    }

    // MARK: Drawing

    func draw(_ game: Game, _ fb: Framebuffer) {
        for a in actors { a.draw(fb) }
        iris?.draw(fb)
    }

    /// Draw an ASEQ's first drawable step straight into the background page,
    /// as the title and credits do (they never restore under these frames).
    func stampFirstFrame(_ game: Game, _ aseqId: Int) {
        guard let a = game.res.aseq(aseqId),
              let s = a.steps.first(where: { $0.frame >= 0 }), let f = a.frame(s.frame) else { return }
        game.fb.stamp(f, x: s.dx, y: s.dy)
    }
}

/// Intro 30500 (Intro_Enter FUN_00433405): stars and a shooting star while
/// WAVE 23000 plays; when it ends the title follows.
final class IntroScene: SlideshowScene {
    private var duration = 0.0

    init() { super.init(id: 30500) }

    override func enter(_ game: Game) {
        super.enter(game)
        game.say(23000)
        duration = game.res.wave(23000)?.duration ?? 0
    }

    override func slideTick(_ game: Game) {
        counter += 1
        // Wait for the speech to end (with audio off, for its length).
        let elapsed = Double(counter) * 0.116
        if !game.speechPlaying, elapsed >= duration || game.audio.enabled && counter > 2 {
            next(game, skip: true)
            return
        }
        super.slideTick(game)
    }

    override func next(_ game: Game, skip: Bool) {
        game.stopSpeech()
        game.change(to: TitleScene())
    }
}

/// Title 30600 (Title_Enter FUN_0043334b): Reader surfing in, drawn one
/// picture per tick from ASEQ 30601–30667 over MUSIC 2092, then the copyright
/// lines in NFNT 1012 while SOUNDS 3787 repeats until the child clicks.
/// Palette 30600 is the one palette the original leaves un-remapped.
final class TitleScene: SlideshowScene {
    private var copyright: [[UInt8]] = []
    private var showCopyright = false
    private var font: BitmapFont?

    init() { super.init(id: 30600) }

    override func enter(_ game: Game) {
        show(game, slide: id, palette: id, animations: 0)
        font = game.res.font(1012)
        // Two copyright strings (pointer table 0x445b40).
        copyright = (game.exe?.stringTable(at: 0x445b40, count: 2) ?? []).compactMap { $0?.macRoman }
    }

    override func slideTick(_ game: Game) {
        counter = min(99, counter + 1)
        if counter == 1 { game.playMusic(2092, loop: false) }
        if counter < 0x44 {
            stampFirstFrame(game, 30600 + counter)
        } else {
            showCopyright = true
            if !game.speechPlaying { game.say(3787) }
        }
    }

    override func next(_ game: Game, skip: Bool) {
        if skip {
            game.stopSpeech()
            game.change(to: PlayerSignInScene())
        } else {
            closeIris { game.change(to: StoryCarouselScene()) }
        }
    }

    override func draw(_ game: Game, _ fb: Framebuffer) {
        if showCopyright, let font {
            var y = 0x1AE
            for line in copyright {
                fb.drawText(line, font: font, x: (640 - font.width(of: line)) / 2, y: y, color: 0x92)
                y += 20
            }
        }
        super.draw(game, fb)
    }
}

/// Story carousel 30110 → 30120 → 30122 → 30124 → 30130 (Carousel_Enter
/// FUN_00433382): opens with an iris and SOUNDS 3777; each slide plays once
/// with its step-cued sounds (table 0x445b04). A click skips a slide; at the
/// end an iris closes onto sign-in (the main menu in this port).
final class StoryCarouselScene: SlideshowScene {
    init() { super.init(id: 30110, slides: [30120, 30122, 30124, 30130], cueTable: 0x445b04) }

    override func enter(_ game: Game) {
        super.enter(game)
        game.say(3777)
        openIris()
    }

    override func click(_ game: Game, x: Int, y: Int) {
        if iris != nil { super.click(game, x: x, y: y); return }
        skipSlide(game)
    }

    override func key(_ game: Game, _ key: Key) {
        // Enter only silences the narration while a slide is running.
        if iris == nil, key == .enter, counter == 0 { game.stopSpeech(); return }
        super.key(game, key)
    }

    override func next(_ game: Game, skip: Bool) {
        if skip {
            game.stopSpeech()
            game.change(to: PlayerSignInScene())
        } else {
            closeIris { game.change(to: PlayerSignInScene()) }
        }
    }
}
