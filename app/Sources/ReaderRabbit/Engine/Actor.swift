import Foundation

struct Rect {
    var x: Int, y: Int, w: Int, h: Int

    func contains(_ px: Int, _ py: Int) -> Bool {
        w >= 2 && h >= 2 && px >= x && py >= y && px < x + w && py < y + h
    }

    var midX: Int { x + w / 2 }
    var midY: Int { y + h / 2 }
}

/// An on-screen sprite driven by an ASEQ step script (RRPW32.EXE actor slots
/// at DAT_004483f6; FUN_004340de / FUN_00433cbf / FUN_00433d23).
final class Actor {
    var aseq: Aseq
    var x: Int
    var y: Int
    var step: Int
    var hidden = false
    /// Scene-specific tag (COMB entry id for layout actors).
    var tag: Int = 0

    init(_ aseq: Aseq, x: Int = 0, y: Int = 0, step: Int = 1) {
        self.aseq = aseq
        self.x = x
        self.y = y
        self.step = step
    }

    var frameIndex: Int { aseq.step(step).map { $0.frame } ?? -1 }

    var sprite: Sprite? {
        guard !hidden, let s = aseq.step(step), s.frame >= 0 else { return nil }
        return aseq.frame(s.frame)
    }

    var rect: Rect {
        guard let s = aseq.step(step), s.frame >= 0, let f = aseq.frame(s.frame) else {
            return Rect(x: x, y: y, w: 0, h: 0)
        }
        return Rect(x: x + s.dx, y: y + s.dy, w: f.width, h: f.height)
    }

    func set(_ aseq: Aseq, step: Int, x: Int? = nil, y: Int? = nil) {
        self.aseq = aseq
        self.step = step
        if let x { self.x = x }
        if let y { self.y = y }
    }

    func draw(_ fb: Framebuffer) {
        guard !hidden, let s = aseq.step(step), s.frame >= 0, let f = aseq.frame(s.frame) else { return }
        fb.draw(f, x: x + s.dx, y: y + s.dy)
    }

    enum Advance { case moved, ended, wrapped }

    /// Actor_Advance (FUN_00433d23): step forward, skipping TRIGGER markers;
    /// BRANCH loops back (re-basing x so walk cycles continue), LOOP restarts,
    /// any other control code ends the script.
    @discardableResult
    func advance() -> Advance {
        var cur = step
        var next = cur + 1
        var code = aseq.step(next)?.frame ?? StepCode.end
        while code == StepCode.trigger {
            cur = next
            next += 1
            code = aseq.step(next)?.frame ?? StepCode.end
        }
        guard code < 0 else { step = next; return .moved }
        if code == StepCode.branch {
            if frameIndex < 0 { return .ended }
            let target = aseq.step(next)?.dx ?? 0
            let after = aseq.step(next + 1), tgt = aseq.step(target)
            x += (after?.dx ?? 0) - (tgt?.dx ?? 0)
            step = target
            return .moved
        }
        if code == StepCode.loop {
            step = (aseq.step(0)?.frame ?? 0) < 0 ? 1 : 0
            return step == 0 ? .wrapped : .ended
        }
        step = min(next + 1, aseq.steps.count - 1)
        if (aseq.step(step)?.frame ?? -1) < 0 { step = max(0, cur) }
        return .ended
    }

    /// First step index after a leading REST marker (the idle pose).
    var restStep: Int { (aseq.step(0)?.frame ?? 0) < 0 ? 1 : 0 }
}
