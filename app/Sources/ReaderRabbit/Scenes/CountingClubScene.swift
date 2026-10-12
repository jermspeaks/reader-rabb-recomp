import Foundation

/// Not ported yet: shows the activity background with an EXIT sign.
final class CountingClubScene: Scene {
    private let placeholder = PlaceholderActivityScene(.countingClub)
    func enter(_ game: Game) { placeholder.enter(game) }
    func tick(_ game: Game) { placeholder.tick(game) }
    func click(_ game: Game, x: Int, y: Int) { placeholder.click(game, x: x, y: y) }
    func key(_ game: Game, _ key: Key) { placeholder.key(game, key) }
    func draw(_ game: Game, _ fb: Framebuffer) { placeholder.draw(game, fb) }
}
