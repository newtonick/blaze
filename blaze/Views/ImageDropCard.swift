import SwiftUI

/// Step 1: the image. Empty state is a large drop target; once an image is
/// chosen it shows name, size, modified date, and the SHA-256 (compacted to
/// first 7 … last 7 — click to copy the full digest).
struct ImageDropCard: View {
    @Environment(AppModel.self) private var model
    var dropTargeted: Bool
    @State private var copiedHash = false

    var body: some View {
        Group {
            if let url = model.imageURL {
                selectedView(url)
            } else {
                emptyView
            }
        }
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(.quinary)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(dropTargeted ? Color.blaze : Color.secondary.opacity(0.25),
                              style: StrokeStyle(lineWidth: dropTargeted ? 2 : 1,
                                                 dash: model.imageURL == nil ? [6, 4] : []))
        )
        .animation(.smooth(duration: 0.2), value: dropTargeted)
    }

    private var emptyView: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.document")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(dropTargeted ? Color.blaze : .secondary)
            Text("Drop an .img here, or ⌘O")
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 148)
        .contentShape(Rectangle())
        .onTapGesture { model.showImporter = true }
    }

    private func selectedView(_ url: URL) -> some View {
        HStack(spacing: 14) {
            Image(systemName: "opticaldiscdrive")
                .font(.system(size: 28, weight: .light))
                .foregroundStyle(Color.blaze)
                .frame(width: 44)

            VStack(alignment: .leading, spacing: 3) {
                Text(url.lastPathComponent)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                HStack(spacing: 6) {
                    Text(sizeLine)
                    if let modified = model.imageModified {
                        Text("·")
                        Text(modified, format: .dateTime.day().month().year())
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                hashLine
            }

            Spacer()

            Button("Change…") { model.showImporter = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(14)
    }

    /// "48 MB" for raw; "48 MB compressed → 200 MB image" when the container
    /// declares the size; just "48 MB compressed" when it can't (gzip > 4 GB).
    private var sizeLine: String {
        let fileSize = ByteCountFormatter.string(fromByteCount: model.imageSize, countStyle: .file)
        guard let info = model.imageInfo, info.isCompressed else { return fileSize }
        if let uncompressed = info.uncompressedSize {
            let big = ByteCountFormatter.string(fromByteCount: uncompressed, countStyle: .file)
            return "\(fileSize) compressed → \(big) image"
        }
        return "\(fileSize) compressed"
    }

    @ViewBuilder
    private var hashLine: some View {
        HStack(spacing: 5) {
            Text("SHA-256")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            if let compact = model.imageCompactSHA256 {
                Button {
                    if let full = model.imageSHA256 {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(full, forType: .string)
                        copiedHash = true
                        Task {
                            try? await Task.sleep(for: .seconds(1.5))
                            copiedHash = false
                        }
                    }
                } label: {
                    Text(copiedHash ? "Copied" : compact)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(copiedHash ? Color.blaze : .secondary)
                        .contentTransition(.opacity)
                }
                .buttonStyle(.plain)
                .help(model.imageSHA256 ?? "")
            } else {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    Text("computing…")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .animation(.smooth(duration: 0.2), value: copiedHash)
        .animation(.smooth(duration: 0.2), value: model.imageSHA256)
    }
}
