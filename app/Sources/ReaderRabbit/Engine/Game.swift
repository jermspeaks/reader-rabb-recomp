import Foundation

enum Key: Equatable {
    case escape, enter, space, left, right, up, down, tab
    case char(Character)
}

/// A scene owns the screen between transitions, like the four handlers each
/// original scene registers with Scene_SetHandlers (FUN_004336e7).
protocol Scene: AnyObject {
    /// Ticks per second; the original runs most scenes at 8 (116 ms ticks).
    var fps: Int { get }
    func enter(_ game: Game)
    func tick(_ game: Game)
    func click(_ game: Game, x: Int, y: Int)
    func key(_ game: Game, _ key: Key)
    func draw(_ game: Game, _ fb: Framebuffer)
    func exit(_ game: Game)
}

/// Scenes can accept extra headless commands for development checks
/// (see App/Snapshot.swift), e.g. answering an activity round automatically.
protocol DebugDrivable {
    /// Handle `args` (command name first). Return false if the command is unknown.
    func debugCommand(_ game: Game, _ args: [String]) -> Bool
}

extension Scene {
    var fps: Int { 8 }
    func key(_ game: Game, _ key: Key) {}
    func exit(_ game: Game) {}
}

/// Saved progress for one player (our own format; the original used RRP.DAT).
/// Activities are indexed in menu order: 0 Counting Club, 1 ABC Diner,
/// 2 Shape Shack, 3 Pattern Parade.
struct PlayerProfile: Codable {
    var name = "Player"
    var lowercase = false
    var soundOn = true
    var level = [0, 0, 0, 0]
    var progress = [0, 0, 0, 0]
    var keys = Array(repeating: Array(repeating: false, count: 4), count: 4)
    var usedContent = [[Int]](repeating: [], count: 4)
    var endingSeen = false

    var totalKeys: Int { keys.joined().filter { $0 }.count }

    /// Level complete (FUN_0043102e + the per-activity level-up helpers):
    /// award the key, raise the level (max 3) and reset progress.
    mutating func completeLevel(_ activity: Int) {
        keys[activity][level[activity]] = true
        level[activity] = min(3, level[activity] + 1)
        progress[activity] = 0
        usedContent[activity] = []
    }

    static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ReaderRabbitPreschool", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("player.json")
    }

    static func load() -> PlayerProfile {
        guard let d = try? Data(contentsOf: url), let p = try? JSONDecoder().decode(PlayerProfile.self, from: d)
        else { return PlayerProfile() }
        return p
    }

    func save() {
        if let d = try? JSONEncoder().encode(self) { try? d.write(to: Self.url) }
    }
}

/// Lip-synced speech in progress (Lips_Queue / Lips_Poll, FUN_00434f25 / FUN_00435051).
final class LipSync {
    private let track: LipTrack
    private var index = 0
    let waveId: Int
    var actor: Int { track.actor }

    init(track: LipTrack, waveId: Int) {
        self.track = track
        self.waveId = waveId
    }

    /// Next mouth value, or nil when the track has finished.
    func poll() -> Int? {
        guard index < track.mouth.count else { return nil }
        defer { index += 1 }
        return track.mouth[index]
    }
}

/// Owns resources, screen, audio, player and the scene loop.
final class Game {
    let res: ResourceStore
    /// Tables read from the user's RRPW32.EXE (nil if it is missing).
    let exe: ExeTables?
    let fb = Framebuffer()
    let audio = AudioSystem()
    var player: PlayerProfile
    /// Menu index of the current activity (DAT_004471d6).
    var activity = 0
    /// Exteriors whose host introduction has played this session.
    var introducedExteriors = Set<Int>()
    var menuVisits = 0

    private(set) var scene: Scene?
    private var pending: (scene: Scene, sound: Int?)?
    private var inputQueue: [(Int, Int)?] = []
    private var keyQueue: [Key] = []
    private(set) var tickCount = 0
    private var lips: LipSync?
    var onQuitRequest: (() -> Void)?
    var onFrame: (() -> Void)?
    private var paletteId = -1

    init(root: URL) throws {
        res = try ResourceStore(root: root)
        exe = ExeTables(root: root)
        player = PlayerProfile.load()
        audio.enabled = player.soundOn
    }

    var tickInterval: TimeInterval {
        let fps = scene?.fps ?? 8
        // FUN_004339a4: period = 1000/fps - 9 ms below 60 fps, else -1 ms.
        return (fps < 60 ? 1000.0 / Double(fps) - 9 : 1000.0 / Double(fps) - 1) / 1000
    }

    func start(_ first: Scene) {
        change(to: first)
        processPendingScene()
    }

    // MARK: Scene changes

    /// Queue a scene change; `sound` plays at the cut (DAT_004483c0 / DAT_004483e8).
    func change(to scene: Scene, sound: Int? = nil) {
        pending = (scene, sound)
    }

    private func processPendingScene() {
        guard let p = pending else { return }
        pending = nil
        scene?.exit(self)
        stopSpeech()
        lips = nil
        scene = p.scene
        if let s = p.sound { say(s) }
        p.scene.enter(self)
        player.save()
    }

    // MARK: Background and palette

    func setBackground(_ id: Int, palette: Int? = nil) {
        let pid = palette ?? id
        if let pal = res.palette(pid) {
            fb.palette = pal
            paletteId = pid
        }
        fb.setBackground(res.aseq(id))
    }

    // MARK: Audio

    func say(_ id: Int) {
        lips = nil
        audio.playSpeech(res.wave(id), id: id)
    }

    /// Start lip-synced speech `id` (LIPS + WAVE with the same id).
    func sayWithLips(_ id: Int) {
        guard let track = res.lips(id) else { say(id); return }
        say(id)
        lips = LipSync(track: track, waveId: id)
    }

    func stopSpeech() {
        lips = nil
        audio.stopSpeech()
    }

    var speechPlaying: Bool { audio.speechPlaying }
    var currentSpeech: Int { audio.speechPlaying ? audio.currentSpeechId : 0 }

    /// The current mouth value (0–8) of the lip-synced speaker, or nil when silent.
    private(set) var mouth: Int?
    /// ASEQ id of the actor the current lip track belongs to.
    var mouthActor: Int? { mouth == nil ? nil : lips?.actor ?? lastLipsActor }
    private var lastLipsActor: Int?

    func playMusic(_ id: Int, loop: Bool = true) { audio.playMusic(res.wave(id), loop: loop) }
    func stopMusic() { audio.stopMusic() }

    func toggleSound() {
        player.soundOn.toggle()
        audio.enabled = player.soundOn
        if !player.soundOn { audio.stopSpeech(); audio.stopMusic() } else { say(1238) }
        player.save()
    }

    // MARK: Input and ticks

    func mouseDown(x: Int, y: Int) { inputQueue.append((x, y)) }
    func keyDown(_ k: Key) { keyQueue.append(k) }

    func random(_ n: Int) -> Int { n <= 1 ? 0 : Int.random(in: 0..<n) }

    func tick() {
        tickCount += 1
        processPendingScene()
        if let l = lips {
            lastLipsActor = l.actor
            if let m = l.poll() { mouth = m > 8 ? 0 : m } else { lips = nil; mouth = nil }
        } else {
            mouth = nil
        }
        // One input event per tick, as the original frame loop does.
        if !inputQueue.isEmpty, let ev = inputQueue.removeFirst() {
            scene?.click(self, x: ev.0, y: ev.1)
        } else if !keyQueue.isEmpty {
            let k = keyQueue.removeFirst()
            scene?.key(self, k)
        }
        processPendingScene()
        scene?.tick(self)
        render()
    }

    func render() {
        fb.beginFrame()
        scene?.draw(self, fb)
        onFrame?()
    }

    func requestQuit() { onQuitRequest?() }
}
