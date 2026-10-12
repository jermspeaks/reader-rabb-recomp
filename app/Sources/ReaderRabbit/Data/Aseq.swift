import Foundation

/// A decoded sprite frame: palette indices plus an opacity mask.
struct Sprite {
    let width: Int
    let height: Int
    let pixels: [UInt8]
    let opaque: [Bool]
}

/// One step of an ASEQ script: `frame >= 0` draws that frame at origin + (dx, dy);
/// negative frames are control codes (docs/formats.md §3).
struct AseqStep {
    let dx: Int
    let dy: Int
    let frame: Int
}

enum StepCode {
    static let end = -1
    static let loop = -2
    static let rest = -4
    static let branch = -5
    static let ifSpeech = -7
    static let trigger = -500
}

/// ASEQ resource: frames (RLE, decoded lazily) and the step script of sequence 0.
/// Layout from RRPW32.EXE FUN_0043462a / FUN_004379c3.
final class Aseq {
    let id: Int
    let frameCount: Int
    let steps: [AseqStep]
    private let data: Data
    private let frameOffsets: [Int]
    private var frames: [Int: Sprite] = [:]

    init(id: Int, data: Data) throws {
        self.id = id
        self.data = data
        let seqCount = data.s16(0), frameCount = data.s16(2), version = data.s16(4)
        guard version <= 0xFE, seqCount >= 1, frameCount >= 0 else {
            throw GameDataError.badFormat("ASEQ \(id)")
        }
        self.frameCount = frameCount
        var pos = 10
        var offsets: [Int] = []
        for i in 0..<frameCount { offsets.append(Int(data.u32(pos + 4 * i))) }
        pos += 4 * frameCount + 4 * seqCount
        var steps: [AseqStep] = []
        for s in 0..<seqCount {
            let n = data.s16(pos)
            pos += 2
            for i in 0..<n where s == 0 {
                let o = pos + 8 * i
                steps.append(AseqStep(dx: data.s16(o), dy: data.s16(o + 2), frame: data.s16(o + 4)))
            }
            pos += 8 * n
        }
        self.steps = steps
        frameOffsets = offsets.map { $0 + pos }
    }

    func step(_ i: Int) -> AseqStep? { steps.indices.contains(i) ? steps[i] : nil }

    func frame(_ index: Int) -> Sprite? {
        guard index >= 0, index < frameCount else { return nil }
        if let f = frames[index] { return f }
        let f = decode(at: frameOffsets[index])
        frames[index] = f
        return f
    }

    /// Row RLE: `00 n` skip n, `FF c n` run of colour c, `k` k literal bytes.
    private func decode(at offset: Int) -> Sprite {
        let w = max(0, data.s16(offset + 2)), h = max(0, data.s16(offset + 4))
        var pixels = [UInt8](repeating: 0, count: w * h)
        var opaque = [Bool](repeating: false, count: w * h)
        var p = offset + 6
        let end = data.count
        for y in 0..<h {
            var x = 0
            let row = y * w
            while x < w, p < end {
                let b = data.u8(p)
                if b == 0 {
                    x += Int(data.u8(p + 1))
                    p += 2
                } else if b == 0xFF {
                    let c = data.u8(p + 1), n = Int(data.u8(p + 2))
                    for i in 0..<n where x + i < w {
                        pixels[row + x + i] = c
                        opaque[row + x + i] = true
                    }
                    x += n
                    p += 3
                } else {
                    let n = Int(b)
                    for i in 0..<n where x + i < w {
                        pixels[row + x + i] = data.u8(p + 1 + i)
                        opaque[row + x + i] = true
                    }
                    x += n
                    p += 1 + n
                }
            }
        }
        return Sprite(width: w, height: h, pixels: pixels, opaque: opaque)
    }
}

/// RRGB palette: 256 Mac RGBColor entries (6 bytes; high byte of each channel used).
struct Palette {
    var rgba: [UInt32]

    init(data: Data) {
        rgba = (0..<256).map { i in
            let r = UInt32(data.u8(i * 6)), g = UInt32(data.u8(i * 6 + 2)), b = UInt32(data.u8(i * 6 + 4))
            return r | g << 8 | b << 16 | 0xFF00_0000
        }
    }

    static let black = Palette(rgba: [UInt32](repeating: 0xFF00_0000, count: 256))

    private init(rgba: [UInt32]) { self.rgba = rgba }
}
