import Foundation
import Observation
import SwiftUI

/// App-wide channel for failed saves; the root view presents `message` as an alert.
@MainActor
@Observable
final class SaveErrorCenter {
    static let shared = SaveErrorCenter()

    private(set) var message: String?
    /// Shown above the error's own description when set.
    var note: String?

    func report(_ error: Error) {
        message = [note, error.localizedDescription].compactMap { $0 }.joined(separator: "\n")
    }

    func dismiss() {
        message = nil
    }
}

extension View {
    /// Presents `center`'s message as an alert. A sheet needs its own center: the root's alert doesn't show over it.
    func saveErrorAlert(_ center: SaveErrorCenter) -> some View {
        alert("Couldn't save your change", isPresented: Binding(
            get: { center.message != nil },
            set: { if !$0 { center.dismiss() } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(center.message ?? "")
        }
    }
}
