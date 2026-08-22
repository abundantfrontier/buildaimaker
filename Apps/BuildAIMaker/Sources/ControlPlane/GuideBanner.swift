import BAMControlPlane
import BAMResourcesUI
import SwiftUI

/// Confirmation + coach chrome. Intrinsic height only (empty when unused).
struct AgentChrome: View {
    @EnvironmentObject private var controlPlane: ControlPlaneEnvironment

    var body: some View {
        if controlPlane.guide != nil || !controlPlane.pendingConfirmations.isEmpty {
            VStack(spacing: 0) {
                ConfirmationBanner()
                GuideBanner()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BAMColors.detailBackground)
        } else {
            Color.clear.frame(height: 0).allowsHitTesting(false)
        }
    }
}

/// Coach banner: agent is showing a result or a by-hand path.
struct GuideBanner: View {
    @EnvironmentObject private var controlPlane: ControlPlaneEnvironment

    var body: some View {
        if let guide = controlPlane.guide {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.tint)
                    Text(guide.title)
                        .font(.headline)
                    Spacer(minLength: 8)
                    Button("Dismiss") {
                        Task { await controlPlane.dismissGuide() }
                    }
                    .controlSize(.small)
                }
                ForEach(Array(guide.steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .top, spacing: 8) {
                        Text("\(index + 1).")
                            .font(.caption.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .frame(width: 18, alignment: .trailing)
                        Text(step)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(BAMColors.detailBackground)
            .overlay(alignment: .bottom) { Divider() }
        }
    }
}
