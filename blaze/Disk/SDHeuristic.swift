import Foundation

/// Score-ranks external disks by how likely they are to be an SD/microSD
/// card. Weights are tuned against real hardware: a microSD behind a USB
/// reader reports BusProtocol "USB" and MediaName "MassStorageClass", so bus
/// protocol and media name are weak, reader-dependent signals — Removable
/// combined with size is what actually discriminates.
nonisolated enum SDHeuristic {
    /// Word-bounded: "SD" must be a standalone token so model numbers that
    /// merely contain the letters (…P3PSSD8) don't score as card readers.
    static let namePattern = try! NSRegularExpression(
        pattern: #"\b(SD|SDHC|SDXC)\b|Card *Reader|SanDisk|Transcend|Lexar"#,
        options: [.caseInsensitive])

    /// Returns nil for disks that must not be offered at all.
    static func score(_ disk: Disk) -> Int? {
        guard !disk.isInternal else { return nil }

        var score = 0
        if disk.removable { score += 50 }
        if disk.ejectableOnly { score += 20 }
        switch disk.busProtocol {
        case "Secure Digital": score += 40
        case "USB": score += 15
        default: break
        }
        let names = disk.mediaName + " " + disk.ioRegName
        if namePattern.firstMatch(in: names, range: NSRange(names.startIndex..., in: names)) != nil {
            score += 25
        }
        let gb = Double(disk.size) / 1_000_000_000
        if gb <= 128 { score += 25 }
        else if gb <= 512 { score += 10 }
        else if gb > 1000 { score -= 30 }
        if disk.solidState { score -= 10 }
        return score
    }
}
