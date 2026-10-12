import Foundation

/// Stand-in for activities that are not ported yet: shows the activity's
/// game background and an EXIT sign that returns to the exterior.
final class PlaceholderActivityScene: Scene {
    let activity: Activity
    private var exitSign: Actor?
    private var font: BitmapFont?

    init(_ activity: Activity) { self.activity = activity }

    func enter(_ game: Game) {
        game.setBackground(activity.gameBackground)
        if let a = game.res.aseq(212) { exitSign = Actor(a, x: 480, y: 406, step: 1) }
        font = game.res.font(1018)
    }

    func tick(_ game: Game) {}

    func click(_ game: Game, x: Int, y: Int) {
        if exitSign?.rect.contains(x, y) == true { leave(game) }
    }

    func key(_ game: Game, _ key: Key) {
        if key == .escape { leave(game) }
    }

    private func leave(_ game: Game) {
        game.change(to: ExteriorScene(activity))
    }

    func draw(_ game: Game, _ fb: Framebuffer) {
        exitSign?.draw(fb)
        if let font {
            let text = "\(activity.name) is not ported yet".macRoman
            let w = font.width(of: text)
            fb.fill(x: 320 - w / 2 - 12, y: 20, w: w + 24, h: font.height + 12, color: 0xFF)
            fb.drawText(text, font: font, x: 320 - w / 2, y: 26 + font.ascent, color: 0)
        }
    }
}

/// Stand-in for the bonus areas behind each exterior's signpost.
final class BonusScene: Scene {
    let activity: Activity
    init(_ activity: Activity) { self.activity = activity }

    func enter(_ game: Game) {
        game.setBackground(activity.bonusBackground)
        game.playMusic(activity.bonusMusic, loop: false)
    }

    func tick(_ game: Game) {}

    func click(_ game: Game, x: Int, y: Int) { leave(game) }

    func key(_ game: Game, _ key: Key) { leave(game) }

    func exit(_ game: Game) { game.stopMusic() }

    private func leave(_ game: Game) { game.change(to: ExteriorScene(activity)) }

    func draw(_ game: Game, _ fb: Framebuffer) {}
}
