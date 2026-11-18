import Combine
import SwiftUI

/// Presentation state only; creating it never opens the config store or runtime.
@MainActor
final class CutWarningState: ObservableObject {
    static let shared = CutWarningState()
    @Published private(set) var message = ""
    @Published private(set) var requestID = 0

    func show(_ message: String) {
        self.message = message
        requestID &+= 1
    }
}

struct CutWarningView: View {
    static let windowID = "rclick-cut-warning"
    @ObservedObject var state: CutWarningState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label(AppLocalization.localized("Warning"), systemImage: "exclamationmark.triangle")
                .font(.headline)
            Text(state.message)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button(AppLocalization.localized("OK")) { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 420)
    }
}
