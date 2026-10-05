import SwiftUI
import PhotosUI
import UIKit

/// Bytes from a source, or a decoded image that still needs encoding (done off the main actor).
enum RawImage: Sendable {
    case data(Data)
    case photo(UIImage)

    fileprivate func bytes() -> Data? {
        switch self {
        case let .data(data): data
        case let .photo(image): image.jpegData(compressionQuality: 0.95)
        }
    }
}

/// Where new images come from (library, camera, pasteboard) and the processing that follows.
/// Each place that adds images owns one, and attaches `.imageIntake(_:onAdd:)` to a view that stays
/// on screen while the pickers are up (not the keyboard toolbar, which disappears with the keyboard).
@MainActor
@Observable
final class ImageIntake {
    var isPickingLibrary = false
    var isTakingPhoto = false
    var failed = false
    private(set) var pendingCount = 0

    @ObservationIgnored var onAdd: ([ImageDraft]) -> Void = { _ in }

    var isProcessing: Bool { pendingCount > 0 }
    var canTakePhoto: Bool { UIImagePickerController.isSourceTypeAvailable(.camera) }
    private(set) var canPaste = UIPasteboard.general.hasImages

    func refreshPasteAvailability() {
        canPaste = UIPasteboard.general.hasImages
    }

    func paste() {
        let board = UIPasteboard.general
        let types = [UTType.heic, .png, .jpeg]
        if let data = types.lazy.compactMap({ board.data(forPasteboardType: $0.identifier) }).first {
            ingest([.data(data)])
        } else if let image = board.image {
            ingest([.photo(image)])
        }
    }

    func beginLoading(_ count: Int) { pendingCount += count }

    func finishLoading(_ count: Int) { pendingCount -= count }

    func ingest(_ inputs: [RawImage]) {
        pendingCount += inputs.count
        Task {
            var added: [ImageDraft] = []
            for input in inputs {
                let processed = try? await Task.detached(priority: .userInitiated) {
                    guard let bytes = input.bytes() else { throw ImageProcessingError.undecodable }
                    return try ImageProcessor.process(bytes)
                }.value
                pendingCount -= 1
                if let processed {
                    added.append(ImageDraft(processed: processed))
                } else {
                    failed = true
                }
            }
            if !added.isEmpty { onAdd(added) }
        }
    }
}

/// The three image sources as menu items.
struct ImageSourceButtons: View {
    let intake: ImageIntake

    var body: some View {
        Button { intake.isPickingLibrary = true } label: {
            Label("Photo Library", systemImage: "photo.on.rectangle")
        }
        if intake.canTakePhoto {
            Button { intake.isTakingPhoto = true } label: {
                Label("Take Photo", systemImage: "camera")
            }
        }
        if intake.canPaste {
            Button { intake.paste() } label: {
                Label("Paste Image", systemImage: "doc.on.clipboard")
            }
        }
    }
}

/// Spinner shown while images are processed.
struct ImageProcessingIndicator: View {
    let intake: ImageIntake

    var body: some View {
        if intake.isProcessing {
            HStack(spacing: 8) {
                ProgressView()
                Text("Processing image…")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)
        }
    }
}

private struct ImageIntakeModifier: ViewModifier {
    @Bindable var intake: ImageIntake
    let onAdd: ([ImageDraft]) -> Void

    @State private var pickerItems: [PhotosPickerItem] = []

    func body(content: Content) -> some View {
        // Reassigned on every update so a finished image is delivered to the current handler.
        let _ = intake.onAdd = onAdd
        content
            .onReceive(NotificationCenter.default.publisher(for: UIPasteboard.changedNotification)) { _ in
                intake.refreshPasteAvailability()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                intake.refreshPasteAvailability()
            }
            .photosPicker(isPresented: $intake.isPickingLibrary, selection: $pickerItems, matching: .images)
            .fullScreenCover(isPresented: $intake.isTakingPhoto) {
                CameraPicker(
                    onCapture: { intake.ingest([.photo($0)]) },
                    onFinish: { intake.isTakingPhoto = false }
                )
                .ignoresSafeArea()
            }
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                pickerItems = []
                load(items)
            }
            .alert("Couldn't add image", isPresented: $intake.failed) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("That image couldn't be read.")
            }
    }

    private func load(_ items: [PhotosPickerItem]) {
        intake.beginLoading(items.count)
        Task {
            var inputs: [RawImage] = []
            for item in items {
                if let data = try? await item.loadTransferable(type: Data.self) {
                    inputs.append(.data(data))
                } else {
                    intake.failed = true
                }
            }
            intake.finishLoading(items.count)
            intake.ingest(inputs)
        }
    }
}

extension View {
    func imageIntake(_ intake: ImageIntake, onAdd: @escaping ([ImageDraft]) -> Void) -> some View {
        modifier(ImageIntakeModifier(intake: intake, onAdd: onAdd))
    }
}

/// System camera. Hands back the photo; `onFinish` fires after a capture or a cancel.
private struct CameraPicker: UIViewControllerRepresentable {
    let onCapture: (UIImage) -> Void
    let onFinish: () -> Void

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: UIImagePickerController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UIImagePickerControllerDelegate, UINavigationControllerDelegate {
        let parent: CameraPicker

        init(_ parent: CameraPicker) { self.parent = parent }

        func imagePickerController(_ picker: UIImagePickerController, didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]) {
            if let image = info[.originalImage] as? UIImage {
                parent.onCapture(image)
            }
            parent.onFinish()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.onFinish()
        }
    }
}

/// A square thumbnail with a remove button, for the editor.
struct RemovableThumbnail: View {
    let id: UUID
    /// 1-based position among `count` images, for VoiceOver.
    let index: Int
    let count: Int
    let data: @MainActor () -> Data?
    let remove: () -> Void

    var body: some View {
        DataImage(id: id, data: data)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Image \(index) of \(count)")
            .frame(width: 72, height: 72)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(alignment: .topTrailing) {
                Button(action: remove) {
                    Image(systemName: "xmark.circle.fill")
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, .black.opacity(0.65))
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove image \(index) of \(count)")
                .offset(x: 14, y: -14)
            }
            .padding(.top, 8)
            .padding(.trailing, 8)
    }
}
