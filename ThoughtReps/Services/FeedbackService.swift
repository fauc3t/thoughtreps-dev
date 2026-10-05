import Foundation

enum FeedbackKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case feature
    case bug

    var id: String { rawValue }
}

/// App and device details sent with feedback. Each value is clipped to the server's rule
/// (1 to 64 printable ASCII characters) so a message is never rejected over them.
struct FeedbackDiagnostics: Equatable, Sendable {
    let appVersion: String
    let osVersion: String
    let deviceModel: String

    init(appVersion: String, osVersion: String, deviceModel: String) {
        self.appVersion = Self.sanitize(appVersion)
        self.osVersion = Self.sanitize(osVersion)
        self.deviceModel = Self.sanitize(deviceModel)
    }

    static func current(bundle: Bundle = .main, processInfo: ProcessInfo = .processInfo) -> FeedbackDiagnostics {
        let os = processInfo.operatingSystemVersion
        return FeedbackDiagnostics(
            appVersion: bundle.versionString,
            osVersion: "iOS \(os.majorVersion).\(os.minorVersion)",
            deviceModel: machineIdentifier()
        )
    }

    static func sanitize(_ value: String) -> String {
        let printable = String(String.UnicodeScalarView(value.unicodeScalars.filter { (0x20...0x7E).contains($0.value) }))
        let clipped = String(printable.trimmingCharacters(in: .whitespaces).prefix(64))
        return clipped.isEmpty ? "unknown" : clipped
    }

    private static func machineIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafePointer(to: &info.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(_SYS_NAMELEN)) { String(cString: $0) }
        }
    }
}

struct FeedbackRequest: Encodable, Equatable {
    let challenge: String
    let kind: FeedbackKind
    let message: String
    let email: String
    let appVersion: String
    let osVersion: String
    let deviceModel: String
}

protocol FeedbackSending: Sendable {
    func send(kind: FeedbackKind, message: String, email: String, diagnostics: FeedbackDiagnostics) async throws
}

/// `POST /feedback`. Only what the form collects plus diagnostics is sent, never thought content.
struct FeedbackService: FeedbackSending {
    static let maxMessageLength = 5000

    var client: AppAttestClient = .shared

    func send(kind: FeedbackKind, message: String, email: String, diagnostics: FeedbackDiagnostics) async throws {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try await client.signedPost("feedback", body: { challenge in
            FeedbackRequest(
                challenge: challenge, kind: kind, message: trimmed, email: email,
                appVersion: diagnostics.appVersion, osVersion: diagnostics.osVersion,
                deviceModel: diagnostics.deviceModel
            )
        }, response: SentResponse.self)
    }

    private struct SentResponse: Decodable { let sent: Bool }
}
