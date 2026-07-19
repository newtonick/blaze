import SwiftUI

/// Replaces the flash button while a run is active: phase label, determinate
/// bar with MB/s and ETA, then an animated success or failure state.
struct ProgressPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.flashState {
            case .flashing(let progress, let simulated):
                flashingView(progress, simulated: simulated)
            case .success(let elapsed, let simulated):
                successView(elapsed: elapsed, simulated: simulated)
            case .failure(let message):
                failureView(message)
            case .idle:
                EmptyView()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quinary))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1))
    }

    private func flashingView(_ p: FlashProgress, simulated: Bool) -> some View {
        VStack(spacing: 10) {
            HStack {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(FlashPhase(rawValue: p.phase.rawValue)?.label ?? "Working")
                        .font(.system(size: 13, weight: .semibold))
                        .contentTransition(.numericText())
                    if simulated {
                        Text("SIMULATED")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(Capsule().fill(Color.indigo.opacity(0.2)))
                            .foregroundStyle(.indigo)
                    }
                }
                Spacer()
                Button("Cancel") { model.cancelFlash() }
                    .controlSize(.small)
                    .keyboardShortcut(.cancelAction)
            }

            if p.isDeterminate {
                ProgressView(value: p.fraction)
                    .progressViewStyle(.linear)
                    .animation(.spring(duration: 0.35), value: p.fraction)
                HStack {
                    Text("\(Int(p.fraction * 100))% · \(speedText(p))")
                    Spacer()
                    if let eta = p.etaSeconds {
                        Text("about \(etaText(eta)) left")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .monospacedDigit()
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                if (p.phase == .writing || p.phase == .verifying) && p.bytesDone > 0 {
                    HStack {
                        Text("\(ByteCountFormatter.string(fromByteCount: p.bytesDone, countStyle: .file)) \(p.phase == .writing ? "written" : "checked") · \(speedText(p))")
                        Spacer()
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
            }
        }
    }

    private func successView(elapsed: TimeInterval, simulated: Bool) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 34))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: model.flashState)
            Text(simulated ? "Simulation complete" : "Flash complete")
                .font(.system(size: 14, weight: .semibold))
            Text("Finished in \(etaText(elapsed))\(simulated ? "" : " — card ejected, safe to remove")")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Button("Done") { model.dismissResult() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
        }
    }

    private func failureView(_ message: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "xmark.octagon.fill")
                .font(.system(size: 30))
                .foregroundStyle(.red)
            Text("Flash failed")
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
            Button("OK") { model.dismissResult() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.small)
        }
    }

    private func speedText(_ p: FlashProgress) -> String {
        guard p.bytesPerSecond > 0 else { return "—" }
        return ByteCountFormatter.string(fromByteCount: Int64(p.bytesPerSecond), countStyle: .file) + "/s"
    }

    private func etaText(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }
}
