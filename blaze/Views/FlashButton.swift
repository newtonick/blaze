import SwiftUI

/// Step 3. Prominent only when image + card are both set. Holding ⌥ turns
/// it into a dry run against /dev/null — the whole pipeline, nothing written.
struct FlashButton: View {
    @Environment(AppModel.self) private var model
    var optionHeld: Bool

    private var simulate: Bool { optionHeld }

    var body: some View {
        VStack(spacing: 6) {
            Button {
                model.requestFlash(simulate: simulate)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: simulate ? "wand.and.sparkles" : "flame.fill")
                    Text(simulate ? "Simulate (no write)" : "Flash")
                        .fontWeight(.semibold)
                }
                .font(.system(size: 15))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(simulate ? .indigo : .blaze)
            .controlSize(.large)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!model.canFlash)

            Text(model.canFlash ? "⌘↩ — hold ⌥ to simulate" : hint)
                .font(.system(size: 11))
                .foregroundStyle(model.fitProblem != nil ? AnyShapeStyle(.orange) : AnyShapeStyle(.tertiary))
        }
        .animation(.smooth(duration: 0.2), value: simulate)
        .animation(.smooth(duration: 0.2), value: model.canFlash)
    }

    private var hint: String {
        if model.imageURL == nil { return "Choose an image to begin" }
        if model.selectedDisk == nil { return "Select a card" }
        if let problem = model.fitProblem { return problem }
        return ""
    }
}
