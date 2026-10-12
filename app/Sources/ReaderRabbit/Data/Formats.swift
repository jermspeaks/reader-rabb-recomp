import Foundation

/// COMB scene layout: actors (id > 0, an ASEQ placed at x1,y1) and hotspots
/// (id <= 0, a rectangle), with optional speech cues per actor step.
/// (docs/formats.md §6; RRPW32.EXE FUN_0041d5ea)
struct SceneLayout {
    struct Entry {
        let id: Int
        let x1: Int, y1: Int, x2: Int, y2: Int
        /// (sound id, step) pairs: play `sound` when the actor reaches `step`.
        let cues: [(sound: Int, step: Int)]
    }

    let sceneId: Int
    let entries: [Entry]

    init(data: Data) throws {
        sceneId = data.s16(2)
        let count = min(data.s16(4), 0x46)
        var entries: [Entry] = []
        for i in 0..<count {
            let o = 6 + 12 * i
            var cues: [(Int, Int)] = []
            let cueOff = data.s16(o + 10)
            if cueOff > 0, cueOff + 2 <= data.count {
                let n = data.s16(cueOff)
                for k in 0..<max(0, n) {
                    cues.append((data.s16(cueOff + 2 + 4 * k), data.s16(cueOff + 4 + 4 * k)))
                }
            }
            entries.append(Entry(id: data.s16(o), x1: data.s16(o + 2), y1: data.s16(o + 4),
                                 x2: data.s16(o + 6), y2: data.s16(o + 8),
                                 cues: cues.map { (sound: $0.0, step: $0.1) }))
        }
        self.entries = entries
    }
}

/// LIPS track: one mouth value per engine tick; the talking actor shows step mouth+1.
/// The WAVE with the same id is the speech. (docs/formats.md §5)
struct LipTrack {
    let mouth: [Int]
    /// ASEQ id of the speaking actor (e.g. 8100 chef, 8210 Reader Rabbit at the diner window).
    let actor: Int

    init(data: Data) throws {
        guard data.s16(0) == 0x0101 else { throw GameDataError.badFormat("LIPS") }
        actor = data.s16(2)
        let count = data.s16(4)
        // The engine shows records 1..count-1 (the last one ends the track).
        mouth = (1..<max(1, count)).map { data.s16(6 * $0) }
    }
}

/// 8-bit unsigned mono PCM from a RIFF WAVE resource.
struct WaveSound {
    let sampleRate: Int
    let samples: Data

    init(data: Data) throws {
        guard data.count > 44, data.u32(0) == 0x4646_4952 else { throw GameDataError.badFormat("WAVE") }
        var rate = 22050
        var p = 12
        var pcm: Data?
        while p + 8 <= data.count {
            let tag = data.u32(p), n = Int(data.u32(p + 4))
            if tag == 0x2074_6D66 { rate = Int(data.u32(p + 12)) } // "fmt "
            if tag == 0x6174_6164 { // "data"
                let start = data.startIndex + p + 8
                pcm = data.subdata(in: start..<min(start + n, data.endIndex))
                break
            }
            p += 8 + n + (n & 1)
        }
        guard let pcm else { throw GameDataError.badFormat("WAVE") }
        sampleRate = rate
        samples = pcm
    }

    var duration: Double { Double(samples.count) / Double(max(1, sampleRate)) }
}

/// Mac NFNT bitmap font with a little-endian header (docs/formats.md §7).
struct BitmapFont {
    let kernMax: Int
    let ascent: Int
    let descent: Int
    let height: Int
    let rowBytes: Int
    let bitmap: [UInt8]
    let loc: [Int]
    let ow: [(offset: Int, width: Int)?]

    init(data: Data) throws {
        let firstChar = data.s16(2), lastChar = data.s16(4)
        kernMax = data.s16(8)
        height = data.s16(0x0E)
        let owTLoc = data.s16(0x10)
        ascent = data.s16(0x12)
        descent = data.s16(0x14)
        rowBytes = data.s16(0x18) * 2
        guard data.u16(0) == 0x9000, firstChar == 0 else { throw GameDataError.badFormat("NFNT") }
        let n = lastChar - firstChar + 3
        let owOff = 0x10 + 2 * owTLoc
        let locOff = owOff - 2 * n
        bitmap = [UInt8](data[(data.startIndex + 0x1A)..<(data.startIndex + locOff)])
        var loc = (0..<(n - 1)).map { Int(data.u16(locOff + 2 * $0)) }
        let last = locOff + 2 * (n - 1)
        loc.append(Int(data.u8(last)) << 8 | Int(data.u8(last + 1))) // never byte-swapped
        self.loc = loc
        ow = (0..<n).map { i in
            let a = Int(data.u8(owOff + 2 * i)), b = Int(data.u8(owOff + 2 * i + 1))
            return a == 255 && b == 255 ? nil : (offset: a, width: b)
        }
    }

    func advance(_ c: UInt8) -> Int { glyphInfo(c)?.width ?? 0 }

    func width(of text: [UInt8]) -> Int { text.reduce(0) { $0 + advance($1) } }

    func glyphInfo(_ c: UInt8) -> (offset: Int, width: Int)? {
        let i = Int(c)
        guard i + 1 < loc.count, i < ow.count else { return nil }
        return ow[i]
    }

    func pixel(_ c: UInt8, _ x: Int, _ y: Int) -> Bool {
        let i = Int(c)
        let bit = loc[i] + x
        guard bit < loc[i + 1] else { return false }
        return bitmap[y * rowBytes + (bit >> 3)] & (0x80 >> UInt8(bit & 7)) != 0
    }

    func glyphWidth(_ c: UInt8) -> Int {
        let i = Int(c)
        guard i + 1 < loc.count else { return 0 }
        return loc[i + 1] - loc[i]
    }
}

/// Mac Roman → byte string helper for drawing text with NFNT fonts.
extension String {
    var macRoman: [UInt8] {
        Array(data(using: .macOSRoman, allowLossyConversion: true) ?? Data())
    }
}
