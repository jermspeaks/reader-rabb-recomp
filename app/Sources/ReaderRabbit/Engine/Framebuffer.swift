import CoreGraphics
import Foundation

/// 640×480 8-bit indexed screen with a clean background page, like the
/// original's 640×960 offscreen buffer (front rows 0–479, background 480–959).
final class Framebuffer {
    static let width = 640
    static let height = 480

    var palette = Palette.black
    private(set) var front = [UInt8](repeating: 0, count: width * height)
    private var background = [UInt8](repeating: 0, count: width * height)

    /// Draw frame 0 of a background ASEQ (centred, as Bg_Set FUN_00434c7c does).
    func setBackground(_ aseq: Aseq?) {
        background = [UInt8](repeating: 0xFF, count: Self.width * Self.height)
        guard let a = aseq, let f = a.frame(0) else { return }
        blit(f, x: (Self.width - f.width) / 2, y: (Self.height - f.height) / 2, into: &background)
    }

    /// Permanently draw onto the background page (static scene decorations).
    func stamp(_ sprite: Sprite, x: Int, y: Int) {
        blit(sprite, x: x, y: y, into: &background)
    }

    func beginFrame() { front = background }

    func draw(_ sprite: Sprite, x: Int, y: Int) { blit(sprite, x: x, y: y, into: &front) }

    func fill(x: Int, y: Int, w: Int, h: Int, color: UInt8) {
        let x0 = max(0, x), y0 = max(0, y), x1 = min(Self.width, x + w), y1 = min(Self.height, y + h)
        guard x0 < x1, y0 < y1 else { return }
        for yy in y0..<y1 { for xx in x0..<x1 { front[yy * Self.width + xx] = color } }
    }

    /// Draw text with its baseline at `y`. Returns the pen x after the text.
    @discardableResult
    func drawText(_ text: [UInt8], font: BitmapFont, x: Int, y: Int, color: UInt8) -> Int {
        var pen = x
        let top = y - font.ascent
        for c in text {
            guard let g = font.glyphInfo(c) else { continue }
            let gx = pen + font.kernMax + g.offset
            let gw = font.glyphWidth(c)
            for row in 0..<font.height {
                let yy = top + row
                guard yy >= 0, yy < Self.height else { continue }
                for col in 0..<gw where font.pixel(c, col, row) {
                    let xx = gx + col
                    if xx >= 0, xx < Self.width { front[yy * Self.width + xx] = color }
                }
            }
            pen += g.width
        }
        return pen
    }

    private func blit(_ s: Sprite, x: Int, y: Int, into buf: inout [UInt8]) {
        let x0 = max(0, x), y0 = max(0, y)
        let x1 = min(Self.width, x + s.width), y1 = min(Self.height, y + s.height)
        guard x0 < x1, y0 < y1 else { return }
        s.pixels.withUnsafeBufferPointer { px in
            s.opaque.withUnsafeBufferPointer { op in
                buf.withUnsafeMutableBufferPointer { dst in
                    for yy in y0..<y1 {
                        let srow = (yy - y) * s.width - x, drow = yy * Self.width
                        for xx in x0..<x1 where op[srow + xx] {
                            dst[drow + xx] = px[srow + xx]
                        }
                    }
                }
            }
        }
    }

    func makeImage() -> CGImage? {
        var rgba = [UInt32](repeating: 0, count: Self.width * Self.height)
        palette.rgba.withUnsafeBufferPointer { pal in
            for i in 0..<front.count { rgba[i] = pal[Int(front[i])] }
        }
        let data = rgba.withUnsafeBufferPointer { Data(buffer: $0) }
        guard let provider = CGDataProvider(data: data as CFData) else { return nil }
        return CGImage(width: Self.width, height: Self.height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: Self.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}
