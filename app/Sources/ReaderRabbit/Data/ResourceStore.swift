import Foundation

/// Little-endian readers over raw resource bytes.
extension Data {
    @inline(__always) func u8(_ o: Int) -> UInt8 { self[startIndex + o] }
    @inline(__always) func u16(_ o: Int) -> UInt16 {
        UInt16(self[startIndex + o]) | UInt16(self[startIndex + o + 1]) << 8
    }
    @inline(__always) func s16(_ o: Int) -> Int { Int(Int16(bitPattern: u16(o))) }
    @inline(__always) func u32(_ o: Int) -> UInt32 { UInt32(u16(o)) | UInt32(u16(o + 2)) << 16 }
}

enum GameDataError: LocalizedError {
    case missingFile(String)
    case badFormat(String)

    var errorDescription: String? {
        switch self {
        case .missingFile(let p): return "Missing game file: \(p)"
        case .badFormat(let p): return "Unrecognised game file: \(p)"
        }
    }
}

/// One RRPDATA/*.DAT file: a Win16 NE module containing only resources.
/// Resources are addressed by the FourCC tag from the module's RT_NAMETABLE
/// plus a numeric ID (RRPW32.EXE FUN_0041606b / FUN_004162ab).
final class DatFile {
    let name: String
    private let data: Data
    private var table: [String: [Int: Range<Int>]] = [:]

    init(url: URL) throws {
        name = url.lastPathComponent
        data = try Data(contentsOf: url, options: .alwaysMapped)
        try parse()
    }

    private func parse() throws {
        guard data.count > 0x40, data.u16(0) == 0x5A4D else { throw GameDataError.badFormat(name) }
        let ne = Int(data.u32(0x3C))
        guard data.u16(ne) == 0x454E else { throw GameDataError.badFormat(name) }
        let rsrc = ne + Int(data.u16(ne + 0x24))
        let shift = Int(data.u16(rsrc))
        var pos = rsrc + 2
        var byType: [Int: [Int: Range<Int>]] = [:]
        var nameTable: Range<Int>?
        while true {
            let typeId = Int(data.u16(pos)), count = Int(data.u16(pos + 2))
            if typeId == 0 { break }
            pos += 8
            for _ in 0..<count {
                let off = Int(data.u16(pos)) << shift, len = Int(data.u16(pos + 2)) << shift
                let rid = Int(data.u16(pos + 6))
                pos += 12
                guard typeId & 0x8000 != 0, rid & 0x8000 != 0 else { continue }
                if typeId & 0x7FFF == 15 { nameTable = off..<off + len; continue }
                byType[typeId, default: [:]][rid & 0x7FFF] = off..<off + len
            }
        }
        // RT_NAMETABLE entries: u16 len, u16 type_id, u16 res_id, "TAG\0", "\0".
        guard let nt = nameTable else { throw GameDataError.badFormat(name) }
        var p = nt.lowerBound
        var tags: [Int: String] = [:]
        while p + 6 < nt.upperBound {
            let len = Int(data.u16(p))
            if len == 0 { break }
            let typeId = Int(data.u16(p + 2))
            let tagBytes = data[(data.startIndex + p + 6)..<(data.startIndex + p + 10)]
            tags[typeId] = String(decoding: tagBytes, as: UTF8.self)
            p += len
        }
        for (typeId, entries) in byType {
            if let tag = tags[typeId] { table[tag] = entries }
        }
    }

    func resource(_ tag: String, _ id: Int) -> Data? {
        guard let r = table[tag]?[id] else { return nil }
        return data.subdata(in: r)
    }

    func ids(_ tag: String) -> [Int] { (table[tag] ?? [:]).keys.sorted() }
}

/// The four game DAT files, searched in the same order as the original
/// (GRAPHIC, SPEECH, SOUNDS, MUSIC; FUN_00438745 / FUN_0043895b).
final class ResourceStore {
    let root: URL
    private let files: [DatFile]
    private var aseqCache: [Int: Aseq] = [:]
    private var paletteCache: [Int: Palette] = [:]
    private var fontCache: [Int: BitmapFont] = [:]
    private var waveCache: [Int: WaveSound] = [:]

    static let datNames = ["GRAPHIC", "SPEECH", "SOUNDS", "MUSIC"]

    /// `root` is the folder containing RRPDATA (the game CD or a copy of it).
    init(root: URL) throws {
        self.root = root
        var files: [DatFile] = []
        for n in Self.datNames {
            guard let url = Self.locate(root: root, name: n) else {
                throw GameDataError.missingFile("RRPDATA/\(n).DAT")
            }
            files.append(try DatFile(url: url))
        }
        self.files = files
    }

    static func locate(root: URL, name: String) -> URL? {
        let fm = FileManager.default
        for dir in ["RRPDATA", "rrpdata", "RRPData"] {
            for ext in ["DAT", "dat", "DLL", "dll"] {
                let u = root.appendingPathComponent(dir).appendingPathComponent("\(name).\(ext)")
                if fm.fileExists(atPath: u.path) { return u }
            }
        }
        return nil
    }

    static func looksLikeGame(_ root: URL) -> Bool {
        locate(root: root, name: "GRAPHIC") != nil
    }

    func raw(_ tag: String, _ id: Int) -> Data? {
        for f in files { if let d = f.resource(tag, id) { return d } }
        return nil
    }

    func ids(_ tag: String) -> [Int] { files.flatMap { $0.ids(tag) }.sorted() }

    func aseq(_ id: Int) -> Aseq? {
        if let a = aseqCache[id] { return a }
        guard let d = raw("ASEQ", id), let a = try? Aseq(id: id, data: d) else { return nil }
        aseqCache[id] = a
        return a
    }

    func palette(_ id: Int) -> Palette? {
        if let p = paletteCache[id] { return p }
        guard let d = raw("RRGB", id) else { return nil }
        let p = Palette(data: d)
        paletteCache[id] = p
        return p
    }

    func font(_ id: Int) -> BitmapFont? {
        if let f = fontCache[id] { return f }
        guard let d = raw("NFNT", id), let f = try? BitmapFont(data: d) else { return nil }
        fontCache[id] = f
        return f
    }

    func comb(_ id: Int) -> SceneLayout? {
        guard let d = raw("COMB", id) else { return nil }
        return try? SceneLayout(data: d)
    }

    func lips(_ id: Int) -> LipTrack? {
        guard let d = raw("LIPS", id) else { return nil }
        return try? LipTrack(data: d)
    }

    func wave(_ id: Int) -> WaveSound? {
        if let w = waveCache[id] { return w }
        guard let d = raw("WAVE", id), let w = try? WaveSound(data: d) else { return nil }
        if waveCache.count > 400 { waveCache.removeAll() }
        waveCache[id] = w
        return w
    }

    /// Drop decoded sprites when switching scenes so memory stays bounded.
    func trimSprites(keeping ids: Set<Int>) {
        aseqCache = aseqCache.filter { ids.contains($0.key) }
    }
}
