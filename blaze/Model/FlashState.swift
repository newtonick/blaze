import Foundation

nonisolated struct FlashProgress: Equatable, Sendable {
    var phase: FlashPhase = .unmounting
    var bytesDone: Int64 = 0
    /// 0 = unknown (oversized gzip): the bar goes indeterminate with a live
    /// byte counter instead of a made-up percentage.
    var bytesTotal: Int64 = 0
    var startedAt = Date()
    var phaseStartedAt = Date()
    var bytesPerSecond: Double = 0

    var fraction: Double {
        guard bytesTotal > 0 else { return 0 }
        return min(1, Double(bytesDone) / Double(bytesTotal))
    }

    /// Only the byte-driven phases with a known total get a determinate bar.
    var isDeterminate: Bool { (phase == .writing || phase == .verifying) && bytesTotal > 0 }

    var etaSeconds: TimeInterval? {
        guard isDeterminate, bytesPerSecond > 1, bytesDone > 0 else { return nil }
        return Double(bytesTotal - bytesDone) / bytesPerSecond
    }
}

nonisolated enum FlashState: Equatable, Sendable {
    case idle
    case flashing(FlashProgress, simulated: Bool)
    case success(elapsed: TimeInterval, simulated: Bool)
    case failure(message: String)

    var isFlashing: Bool {
        if case .flashing = self { return true }
        return false
    }
}
