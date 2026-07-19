import Foundation

/// One external whole disk as the picker presents it.
nonisolated struct Disk: Identifiable, Equatable, Sendable {
    let bsdName: String          // "disk8"
    let size: Int64
    let mediaName: String
    let ioRegName: String
    let busProtocol: String
    let removable: Bool
    let ejectableOnly: Bool
    let solidState: Bool
    let isInternal: Bool
    let volumeNames: [String]
    let mountPoints: [String]
    var score: Int = 0

    var id: String { bsdName }

    /// What a person recognizes: the volume label first, then the media
    /// name, then the bare device node. System partition labels (EFI) are
    /// not names anyone chose — skip them.
    var displayName: String {
        let volumes = volumeNames.filter { !$0.isEmpty && $0.uppercased() != "EFI" }
        if !volumes.isEmpty { return volumes.joined(separator: ", ") }
        if !mediaName.isEmpty { return mediaName }
        return bsdName
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var identity: DiskIdentity {
        DiskIdentity(mediaName: mediaName, size: size,
                     ioRegName: ioRegName, volumeNames: volumeNames.sorted())
    }
}

/// Best-effort identity used to re-preselect the last card across reboots
/// (BSD names are reassigned and must never be persisted). Not unique —
/// generic readers report "MassStorageClass" — so a match only ever drives a
/// preselection, never a write.
nonisolated struct DiskIdentity: Codable, Equatable, Sendable {
    let mediaName: String
    let size: Int64
    let ioRegName: String
    let volumeNames: [String]
}
