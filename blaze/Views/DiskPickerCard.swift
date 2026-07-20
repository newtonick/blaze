import SwiftUI

/// Step 2: the card. Rows lead with the volume name — what a person
/// actually recognizes — then size and device node.
struct DiskPickerCard: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Card")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    Task { await model.rescanDisks() }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                        Text("⌘R")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Rescan cards (⌘R)")
            }

            if !model.hasFullDiskAccess {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "externaldrive.badge.exclamationmark")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("Full Disk Access needed to detect cards")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Button("Open System Settings") { FullDiskAccess.openSettings() }
                            .controlSize(.small)
                    }
                    Spacer()
                }
                .padding(.vertical, 16)
            } else if model.disks.isEmpty {
                HStack {
                    Spacer()
                    VStack(spacing: 6) {
                        Image(systemName: "sdcard")
                            .font(.system(size: 22, weight: .light))
                            .foregroundStyle(.tertiary)
                        Text("No external disks — insert an SD card")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.vertical, 18)
            } else {
                VStack(spacing: 4) {
                    ForEach(model.disks) { disk in
                        row(disk)
                    }
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 12).fill(.quinary))
        .overlay(RoundedRectangle(cornerRadius: 12)
            .strokeBorder(Color.secondary.opacity(0.25), lineWidth: 1))
    }

    private func row(_ disk: Disk) -> some View {
        let selected = model.selectedDiskID == disk.bsdName
        return Button {
            model.selectedDiskID = disk.bsdName
        } label: {
            HStack(spacing: 10) {
                Image(systemName: disk.score > 0 ? "sdcard.fill" : "externaldrive")
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? Color.blaze : .secondary)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 1) {
                    Text(disk.displayName)
                        .font(.system(size: 13, weight: .medium))
                        .lineLimit(1)
                    Text("\(disk.formattedSize) · \(disk.bsdName)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.blaze)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(selected ? Color.blaze.opacity(0.12) : .clear)
            )
        }
        .buttonStyle(.plain)
    }
}
