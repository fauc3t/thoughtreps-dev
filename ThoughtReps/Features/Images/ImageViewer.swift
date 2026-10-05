import SwiftUI

/// Identifies the image a viewer opens on.
struct ImageViewerStart: Identifiable {
    let id: UUID
}

/// Full-screen, swipeable viewer over a thought's images.
struct ImageViewer: View {
    let images: [ImageAsset]

    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID

    init(images: [ImageAsset], startID: UUID) {
        self.images = images
        _selection = State(initialValue: startID)
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Color.black.ignoresSafeArea()
            TabView(selection: $selection) {
                ForEach(Array(images.enumerated()), id: \.element.id) { index, image in
                    ZoomableImage(id: image.id, isCurrent: selection == image.id) { image.data }
                        .tag(image.id)
                        .accessibilityLabel("Image \(index + 1) of \(images.count)")
                }
            }
            .tabViewStyle(.page(indexDisplayMode: images.count > 1 ? .automatic : .never))
            .ignoresSafeArea()

            Button { dismiss() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(.white, .black.opacity(0.5))
                    .frame(width: 44, height: 44)
            }
            .accessibilityLabel("Close")
            .padding(8)
        }
        .preferredColorScheme(.dark)
    }
}

/// Pinch and double-tap to zoom; drag to pan while zoomed.
private struct ZoomableImage: View {
    let id: UUID
    let isCurrent: Bool
    let data: @MainActor () -> Data?

    @State private var size: CGSize = .zero
    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    private static let maxScale: CGFloat = 4

    var body: some View {
        DataImage(id: id, contentMode: .fit, maxPixel: nil, cache: nil, data: data)
            .background(Color.black)
            .onGeometryChange(for: CGSize.self, of: \.size) { size = $0 }
            .scaleEffect(scale)
            .offset(offset)
            .gesture(scale > 1 ? pan : nil)
            .gesture(pinch)
            .onTapGesture(count: 2) {
                withAnimation(.easeInOut(duration: 0.2)) {
                    if scale > 1 {
                        reset()
                    } else {
                        scale = 2
                        committedScale = 2
                    }
                }
            }
            .onChange(of: isCurrent) { _, current in
                if !current { reset() }
            }
            .accessibilityAddTraits(.isImage)
            .accessibilityValue(scale > 1 ? "Zoomed in" : "Not zoomed")
            .accessibilityAdjustableAction { direction in
                withAnimation(.easeInOut(duration: 0.2)) {
                    switch direction {
                    case .increment: setScale(min(scale + 1, Self.maxScale))
                    case .decrement: setScale(max(scale - 1, 1))
                    @unknown default: break
                    }
                }
            }
    }

    private func setScale(_ value: CGFloat) {
        scale = value
        committedScale = value
        offset = clamped(offset)
        committedOffset = offset
        if value <= 1 { reset() }
    }

    /// Keeps the zoomed image from being dragged past its edges.
    private func clamped(_ proposed: CGSize) -> CGSize {
        let limitX = size.width * (scale - 1) / 2
        let limitY = size.height * (scale - 1) / 2
        return CGSize(
            width: min(max(proposed.width, -limitX), limitX),
            height: min(max(proposed.height, -limitY), limitY)
        )
    }

    private var pinch: some Gesture {
        MagnifyGesture()
            .onChanged { scale = min(max(committedScale * $0.magnification, 1), Self.maxScale) }
            .onEnded { _ in
                committedScale = scale
                offset = clamped(offset)
                committedOffset = offset
                if scale <= 1 { reset() }
            }
    }

    private var pan: some Gesture {
        DragGesture()
            .onChanged {
                offset = clamped(CGSize(
                    width: committedOffset.width + $0.translation.width,
                    height: committedOffset.height + $0.translation.height
                ))
            }
            .onEnded { _ in committedOffset = offset }
    }

    private func reset() {
        scale = 1
        committedScale = 1
        offset = .zero
        committedOffset = .zero
    }
}

extension View {
    /// Presents the viewer full screen over `images`, starting at the tapped one.
    func imageViewer(item: Binding<ImageViewerStart?>, images: @escaping () -> [ImageAsset]) -> some View {
        fullScreenCover(item: item) { start in
            ImageViewer(images: images(), startID: start.id)
        }
    }
}
