import AppKit

/// Shows the 640×480 game screen scaled to fit (nearest-neighbour, letterboxed)
/// and converts mouse/keyboard events into game coordinates and keys.
final class GameView: NSView {
    var game: Game?

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        layer?.contentsGravity = .resizeAspect
        layer?.magnificationFilter = .nearest
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var acceptsFirstResponder: Bool { true }

    func present(_ image: CGImage?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.contents = image
        CATransaction.commit()
    }

    /// Map a view point to 640×480 game coordinates (accounting for letterboxing).
    private func gamePoint(_ event: NSEvent) -> (Int, Int)? {
        let p = convert(event.locationInWindow, from: nil)
        let scale = min(bounds.width / 640, bounds.height / 480)
        let w = 640 * scale, h = 480 * scale
        let ox = (bounds.width - w) / 2, oy = (bounds.height - h) / 2
        let x = (p.x - ox) / scale, y = (bounds.height - p.y - oy) / scale
        guard x >= 0, y >= 0, x < 640, y < 480 else { return nil }
        return (Int(x), Int(y))
    }

    override func mouseDown(with event: NSEvent) {
        if let (x, y) = gamePoint(event) { game?.mouseDown(x: x, y: y) }
    }

    override func rightMouseDown(with event: NSEvent) { mouseDown(with: event) }

    override func mouseMoved(with event: NSEvent) { forwardMouseMove(event) }
    override func mouseDragged(with event: NSEvent) { forwardMouseMove(event) }
    override func rightMouseDragged(with event: NSEvent) { forwardMouseMove(event) }

    override func mouseUp(with event: NSEvent) { forwardMouseUp(event) }
    override func rightMouseUp(with event: NSEvent) { forwardMouseUp(event) }

    private func forwardMouseMove(_ event: NSEvent) {
        if let (x, y) = gamePoint(event) { game?.mouseMoved(x: x, y: y) }
    }

    private func forwardMouseUp(_ event: NSEvent) {
        let point = gamePoint(event) ?? (-1, -1)
        game?.mouseUp(x: point.0, y: point.1)
    }

    override func keyDown(with event: NSEvent) {
        guard let game else { return }
        if event.modifierFlags.contains(.control), event.charactersIgnoringModifiers == "s" {
            game.toggleSound()
            return
        }
        // Ctrl+P opens the parent options, as in the original (key code 0x10).
        if event.modifierFlags.contains(.control), event.charactersIgnoringModifiers == "p" {
            game.change(to: ParentMenuScene())
            return
        }
        switch event.keyCode {
        case 53: game.keyDown(.escape)
        case 36, 76: game.keyDown(.enter)
        case 49: game.keyDown(.space)
        case 48: game.keyDown(.tab)
        case 123: game.keyDown(.left)
        case 124: game.keyDown(.right)
        case 125: game.keyDown(.down)
        case 126: game.keyDown(.up)
        default:
            if let c = event.characters?.first { game.keyDown(.char(c)) }
        }
    }
}
