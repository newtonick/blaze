import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(Prefs.verifyKey) private var verifyAfterWrite = true
    @AppStorage(Prefs.onboardedKey) private var hasOnboarded = false
    @State private var optionHeld = false
    @State private var dropTargeted = false

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 16) {
            WindowChrome()

            VStack(spacing: 14) {
                ImageDropCard(dropTargeted: dropTargeted)

                DiskPickerCard()
                    .opacity(model.imageURL == nil ? 0.45 : 1)
                    .disabled(model.imageURL == nil || model.flashState.isFlashing)

                Spacer(minLength: 0)

                bottomPane
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(width: 560, height: 620)
        .background(.background)
        .animation(.smooth(duration: 0.3), value: model.flashState)
        .animation(.smooth(duration: 0.3), value: model.imageURL)
        .animation(.smooth(duration: 0.3), value: model.disks)
        .onModifierKeysChanged(mask: .option) { _, new in
            optionHeld = new.contains(.option)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first(where: { Self.isAcceptedImage($0) }) else {
                return false
            }
            model.setImage(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .fileImporter(isPresented: $model.showImporter,
                      allowedContentTypes: imageTypes) { result in
            if case .success(let url) = result { model.setImage(url) }
        }
        .sheet(isPresented: $model.showConfirmSheet) {
            ConfirmSheet(verify: $verifyAfterWrite)
        }
        .sheet(isPresented: $model.showFDAGate) {
            FullDiskAccessSheet()
        }
        .sheet(isPresented: .constant(!hasOnboarded)) {
            OnboardingSheet(done: $hasOnboarded)
        }
    }

    @ViewBuilder
    private var bottomPane: some View {
        switch model.flashState {
        case .idle:
            FlashButton(optionHeld: optionHeld)
        case .flashing, .success, .failure:
            ProgressPane()
        }
    }

    private var imageTypes: [UTType] {
        let types = ["img", "xz", "gz"].compactMap { UTType(filenameExtension: $0) }
        return types.isEmpty ? [.data] : types
    }

    static func isAcceptedImage(_ url: URL) -> Bool {
        ["img", "xz", "gz"].contains(url.pathExtension.lowercased())
    }
}
