import SwiftUI

/// The write is unrecoverable, so the confirmation names exactly what will
/// be destroyed and what replaces it — never a bare alert.
struct ConfirmSheet: View {
    @Environment(AppModel.self) private var model
    @Binding var verify: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: model.pendingSimulate
                  ? "wand.and.sparkles" : "exclamationmark.triangle.fill")
                .font(.system(size: 30))
                .foregroundStyle(model.pendingSimulate ? Color.indigo : Color.orange)

            Text(model.pendingSimulate ? "Simulate flash?" : "Erase this card?")
                .font(.title3.weight(.semibold))

            if let disk = model.selectedDisk, let url = model.imageURL {
                VStack(spacing: 8) {
                    detailRow(icon: "sdcard.fill",
                              title: disk.displayName,
                              subtitle: "\(disk.formattedSize) · \(disk.bsdName)")
                    Image(systemName: model.pendingSimulate ? "arrow.up.arrow.down" : "arrow.up")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                    detailRow(icon: "opticaldiscdrive",
                              title: url.lastPathComponent,
                              subtitle: imageSubtitle)
                }
                .padding(12)
                .frame(maxWidth: .infinity)
                .background(RoundedRectangle(cornerRadius: 10).fill(.quinary))

                if !model.pendingSimulate {
                    Text("Everything on “\(disk.displayName)” (\(disk.formattedSize)) will be permanently erased.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                } else {
                    Text("Safety checks run, the image is streamed to /dev/null — the card is untouched.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }

            Toggle("Verify after writing", isOn: $verify)
                .toggleStyle(.checkbox)
                .font(.system(size: 12))

            HStack(spacing: 10) {
                Button("Cancel") { model.showConfirmSheet = false }
                    .keyboardShortcut(.cancelAction)
                Button(model.pendingSimulate ? "Simulate" : "Erase and Flash") {
                    model.confirmFlash(verify: verify)
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(model.pendingSimulate ? .indigo : .red)
            }
        }
        .padding(24)
        .frame(width: 380)
    }

    private var imageSubtitle: String {
        var size = ByteCountFormatter.string(fromByteCount: model.imageSize, countStyle: .file)
        if let info = model.imageInfo, info.isCompressed {
            if let uncompressed = info.uncompressedSize {
                size += " → \(ByteCountFormatter.string(fromByteCount: uncompressed, countStyle: .file))"
            } else {
                size += " compressed"
            }
        }
        return size + (model.imageCompactSHA256.map { " · \($0)" } ?? "")
    }

    private func detailRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 11, design: subtitle.contains("…") ? .monospaced : .default))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
