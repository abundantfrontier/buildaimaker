import BAMControlPlane
import BAMResourcesUI
import SwiftUI

/// Authoritative human gate for MCP/CLI expensive and destructive actions.
struct ConfirmationBanner: View {
    @EnvironmentObject private var controlPlane: ControlPlaneEnvironment

    var body: some View {
        if let pending = controlPlane.pendingConfirmations.first {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("Agent needs approval")
                        .font(.headline)
                    Spacer()
                    if controlPlane.pendingConfirmations.count > 1 {
                        Text("+\(controlPlane.pendingConfirmations.count - 1) more")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Text(pending.summary)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Risk: \(pending.risk.rawValue) · \(pending.actionId)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Allow") {
                        Task { await controlPlane.allowPendingConfirmation(pending.token) }
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Deny", role: .destructive) {
                        Task { await controlPlane.denyPendingConfirmation(pending.token) }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BAMColors.detailBackground)
            .overlay {
                Color.orange.opacity(0.16)
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}
