import SwiftUI

/// Empty / placeholder detail pane used until feature UIs ship.
public struct PlaceholderDetailView: View {
    public let destination: SidebarDestination
    public let subtitle: String?

    public init(destination: SidebarDestination, subtitle: String? = nil) {
        self.destination = destination
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(spacing: 12) {
            Image(systemName: destination.systemImage)
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(BAMColors.secondaryLabel)
            Text(destination.title)
                .font(.title2.weight(.semibold))
            Text(subtitle ?? "Coming soon")
                .font(.body)
                .foregroundStyle(BAMColors.tertiaryLabel)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(BAMColors.detailBackground)
        .navigationTitle(destination.title)
    }
}
