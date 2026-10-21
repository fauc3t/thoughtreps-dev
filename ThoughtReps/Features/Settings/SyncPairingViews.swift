#if DEBUG
import AVFoundation
import CoreImage.CIFilterBuiltins
import SwiftUI
import VisionKit

/// A QR code as a crisp, unsmoothed image.
enum QRCodeImage {
    static func make(_ text: String) -> UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(text.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cgImage = CIContext().createCGImage(output, from: output.extent)
        else { return nil }
        return UIImage(cgImage: cgImage)
    }
}

/// "Add a device": shows the invitation's QR code and how long it has left.
struct SyncInviteSheet: View {
    var model: SyncLabModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if let invitation = model.invitation, let image = QRCodeImage.make(invitation.invite.payload) {
                    Image(uiImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 280)
                        .padding(12)
                        .background(.white)
                        .accessibilityLabel("Pairing QR code")
                        .accessibilityIdentifier(SyncLabID.inviteQR)
                        .accessibilityValue(invitation.invite.payload)
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        let left = max(0, Int(invitation.expiresAt.timeIntervalSince(context.date)))
                        Text(left > 0 ? "Expires in \(left / 60):\(String(format: "%02d", left % 60))" : "Expired. Close this and try again.")
                            .monospacedDigit()
                            .foregroundStyle(left > 0 ? Color.primary : Color.red)
                    }
                    Text("Only scan this with your own devices.")
                        .font(.footnote.weight(.semibold))
                } else if let message = model.inviteMessage {
                    Text(message).foregroundStyle(.secondary)
                } else {
                    ProgressView()
                }
            }
            .padding()
            .navigationTitle("Add a device")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .task { await model.openInvitation() }
        .onDisappear { model.closeInvitation() }
    }
}

/// Scans the pairing QR code with the camera and hands back what it parsed.
struct SyncScanSheet: View {
    var onInvite: (SyncPairingInvite) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var access = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var message: String?

    var body: some View {
        NavigationStack {
            Group {
                if !DataScannerViewController.isSupported {
                    notice("This device can't scan QR codes. Use a recovery code instead.")
                } else if access == .denied || access == .restricted {
                    notice("Camera access is off. Turn it on for Thought Reps in iOS Settings, or use a recovery code.")
                } else if access == .notDetermined {
                    ProgressView()
                } else {
                    ZStack(alignment: .bottom) {
                        QRScanner { code in
                            do {
                                let invite = try SyncPairingInvite(parsing: code)
                                dismiss()
                                onInvite(invite)
                            } catch {
                                message = SyncPairingInvite.Failure.malformed.message
                            }
                        }
                        .ignoresSafeArea()
                        if let message {
                            Text(message).padding().background(.regularMaterial, in: .rect(cornerRadius: 12)).padding()
                        }
                    }
                }
            }
            .navigationTitle("Scan pairing code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .task {
            if access == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .video)
                access = AVCaptureDevice.authorizationStatus(for: .video)
            }
        }
    }

    private func notice(_ text: String) -> some View {
        Text(text).multilineTextAlignment(.center).foregroundStyle(.secondary).padding()
    }
}

private struct QRScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])], qualityLevel: .balanced, isHighlightingEnabled: true
        )
        scanner.delegate = context.coordinator
        return scanner
    }

    func updateUIViewController(_ scanner: DataScannerViewController, context: Context) {
        context.coordinator.onCode = onCode
        if !scanner.isScanning { try? scanner.startScanning() }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        var onCode: (String) -> Void

        init(onCode: @escaping (String) -> Void) { self.onCode = onCode }

        func dataScanner(_ scanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for case .barcode(let barcode) in addedItems {
                if let payload = barcode.payloadStringValue {
                    onCode(payload)
                    return
                }
            }
        }
    }
}
#endif
