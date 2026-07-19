import Foundation
import os.log

/// Enumerates external physical whole disks via diskutil's plist output.
/// Blocking — call off the main actor.
nonisolated enum DiskEnumerator {
    private static let log = Logger(subsystem: "dev.derivation48.blaze", category: "disks")

    static func enumerate() -> [Disk] {
        guard let list = diskutilPlist(["list", "-plist", "external", "physical"]) else { return [] }
        let wholeDisks = list["WholeDisks"] as? [String] ?? []

        // Volume names come from the list plist, keyed by whole disk.
        var volumesByDisk: [String: [String]] = [:]
        var mountsByDisk: [String: [String]] = [:]
        for entry in list["AllDisksAndPartitions"] as? [[String: Any]] ?? [] {
            guard let dev = entry["DeviceIdentifier"] as? String else { continue }
            var names: [String] = []
            var mounts: [String] = []
            let children = (entry["Partitions"] as? [[String: Any]] ?? [])
                + (entry["APFSVolumes"] as? [[String: Any]] ?? [])
            for part in children {
                if let name = part["VolumeName"] as? String, !name.isEmpty { names.append(name) }
                if let mount = part["MountPoint"] as? String, !mount.isEmpty { mounts.append(mount) }
            }
            volumesByDisk[dev] = names
            mountsByDisk[dev] = mounts
        }

        var disks: [Disk] = []
        for bsdName in wholeDisks.sorted() {
            guard let info = diskutilPlist(["info", "-plist", bsdName]) else { continue }
            var disk = Disk(
                bsdName: bsdName,
                size: (info["Size"] as? Int64) ?? Int64(info["Size"] as? Int ?? 0),
                mediaName: info["MediaName"] as? String ?? "",
                ioRegName: info["IORegistryEntryName"] as? String ?? "",
                busProtocol: info["BusProtocol"] as? String ?? "",
                removable: (info["Removable"] as? Bool ?? false) || (info["RemovableMedia"] as? Bool ?? false),
                ejectableOnly: info["EjectableOnly"] as? Bool ?? false,
                solidState: info["SolidState"] as? Bool ?? false,
                isInternal: info["Internal"] as? Bool ?? false,
                volumeNames: volumesByDisk[bsdName] ?? [],
                mountPoints: mountsByDisk[bsdName] ?? [])
            // Fixed external drives (NVMe/SSD/HDD enclosures) report
            // Removable=false; SD/microSD readers and sticks report true.
            // Only removable media belongs in a card picker.
            guard disk.removable else {
                log.info("hiding non-removable external disk \(bsdName, privacy: .public) (\(disk.mediaName, privacy: .public))")
                continue
            }
            guard let score = SDHeuristic.score(disk) else {
                log.info("excluding internal disk \(bsdName, privacy: .public)")
                continue
            }
            disk.score = score
            log.info("scored \(bsdName, privacy: .public) (\(disk.displayName, privacy: .public)): \(score)")
            disks.append(disk)
        }
        return disks.sorted { $0.score > $1.score }
    }

    static func mountDisk(_ bsdName: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = ["mountDisk", bsdName]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run()
        p.waitUntilExit()
    }

    static func mountPoints(of bsdName: String) -> [String] {
        guard let list = diskutilPlist(["list", "-plist", bsdName]) else { return [] }
        var mounts: [String] = []
        for entry in list["AllDisksAndPartitions"] as? [[String: Any]] ?? [] {
            let children = (entry["Partitions"] as? [[String: Any]] ?? [])
                + (entry["APFSVolumes"] as? [[String: Any]] ?? [])
            for part in children {
                if let mount = part["MountPoint"] as? String, !mount.isEmpty { mounts.append(mount) }
            }
        }
        return mounts
    }

    private static func diskutilPlist(_ args: [String]) -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        do {
            try p.run()
        } catch {
            log.error("diskutil failed to launch: \(error, privacy: .public)")
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }
}
