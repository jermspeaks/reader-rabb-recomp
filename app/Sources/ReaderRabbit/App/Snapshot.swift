import AppKit
import ImageIO
import UniformTypeIdentifiers

/// Headless driver for development checks:
///   ReaderRabbit --snapshot --game DIR --out DIR "t 20" "click 500 100" "shot menu" ...
/// Commands: `t N` runs N ticks, `click X Y`, `key NAME` (escape, enter, space,
/// left, right, up, down or a character), `shot NAME` writes NAME.png,
/// `level A L` sets activity A's level, `start menu|intro|finale|parent|ext N|
/// game N|bonus N` jumps to a scene. Anything else is passed to the current scene if it is DebugDrivable
/// (ABC Diner: `solve` / `miss` answer the current item).
enum Snapshot {
    static func run(_ args: [String]) -> Bool {
        func value(_ flag: String) -> String? {
            guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
            return args[i + 1]
        }
        guard let gameDir = value("--game"), let outDir = value("--out") else {
            print("usage: --snapshot --game DIR --out DIR [commands…]")
            return false
        }
        let out = URL(fileURLWithPath: outDir)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        PlayerProfile.persistenceEnabled = false
        let game: Game
        do { game = try Game(root: URL(fileURLWithPath: gameDir)) } catch {
            print("error: \(error.localizedDescription)")
            return false
        }
        game.audio.enabled = args.contains("--audio")
        game.player = PlayerProfile()
        game.start(MainMenuScene())
        let skip: Set<String> = ["--snapshot", "--game", "--out", "--audio", gameDir, outDir]
        for cmd in args.dropFirst() where !skip.contains(cmd) {
            let p = cmd.split(separator: " ").map(String.init)
            switch p.first {
            case "t":
                for _ in 0..<(Int(p[1]) ?? 1) { game.tick() }
            case "click":
                game.mouseDown(x: Int(p[1]) ?? 0, y: Int(p[2]) ?? 0)
                game.tick()
            case "key":
                let map: [String: Key] = ["escape": .escape, "enter": .enter, "space": .space,
                                          "left": .left, "right": .right, "up": .up, "down": .down]
                game.keyDown(map[p[1]] ?? .char(p[1].first ?? " "))
                game.tick()
            case "level":
                game.player.level[Int(p[1]) ?? 0] = Int(p[2]) ?? 0
            case "shot":
                game.render()
                write(game.fb.makeImage(), to: out.appendingPathComponent("\(p[1]).png"))
                print("shot \(p[1]) scene=\(type(of: game.scene!)) tick=\(game.tickCount)")
            case "start":
                // Jump straight to a scene: start menu | intro | finale | parent |
                // ext N | game N | bonus N (menu-order activity index).
                let n = Int(p.count > 2 ? p[2] : "0") ?? 0
                switch p[1] {
                case "ext": game.change(to: ExteriorScene(Activity(rawValue: n)!))
                case "game": game.change(to: Activity(rawValue: n)!.makeGameScene())
                case "intro": game.change(to: IntroScene())
                case "finale": game.change(to: EndingScene())
                case "bonus": game.change(to: BonusScene(Activity(rawValue: n)!))
                case "parent": game.change(to: ParentMenuScene())
                default: game.change(to: MainMenuScene())
                }
                game.tick()
            default:
                if let d = game.scene as? DebugDrivable, d.debugCommand(game, p) { continue }
                print("unknown command: \(cmd)")
            }
        }
        return true
    }

    private static func write(_ image: CGImage?, to url: URL) {
        guard let image,
              let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
