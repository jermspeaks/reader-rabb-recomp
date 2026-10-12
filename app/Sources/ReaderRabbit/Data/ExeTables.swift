import Foundation

/// Reads data tables out of the user's own RRPW32.EXE at runtime, so game
/// content (food names, order lists) never has to be copied into this repo.
final class ExeTables {
    private let data: Data
    private var sections: [(va: Int, size: Int, raw: Int)] = []
    private let imageBase: Int

    init?(root: URL) {
        let fm = FileManager.default
        guard let url = ["RRPW32.EXE", "rrpw32.exe"].map({ root.appendingPathComponent($0) })
            .first(where: { fm.fileExists(atPath: $0.path) }),
              let d = try? Data(contentsOf: url), d.count > 0x200, d.u16(0) == 0x5A4D else { return nil }
        data = d
        let pe = Int(d.u32(0x3C))
        guard d.u32(pe) == 0x4550 else { return nil }
        let n = Int(d.u16(pe + 6)), opt = Int(d.u16(pe + 20))
        imageBase = Int(d.u32(pe + 24 + 28))
        for i in 0..<n {
            let o = pe + 24 + opt + 40 * i
            sections.append((Int(d.u32(o + 12)), Int(d.u32(o + 8)), Int(d.u32(o + 20))))
        }
    }

    private func offset(_ va: Int) -> Int? {
        let rva = va - imageBase
        for s in sections where rva >= s.va && rva < s.va + max(s.size, 1) { return s.raw + rva - s.va }
        return nil
    }

    func u32(at va: Int) -> Int? { offset(va).map { Int(data.u32($0)) } }

    func cString(at va: Int) -> String? {
        guard va != 0, let o = offset(va) else { return nil }
        var end = o
        while end < data.count, data.u8(end) != 0 { end += 1 }
        return String(data: data.subdata(in: o..<end), encoding: .macOSRoman)
    }

    /// Strings referenced by a table of `count` pointers at `va` (nil for NULL entries).
    func stringTable(at va: Int, count: Int) -> [String?] {
        (0..<count).map { i in u32(at: va + 4 * i).flatMap { cString(at: $0) } }
    }
}
