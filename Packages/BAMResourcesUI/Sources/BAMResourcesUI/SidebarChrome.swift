import SwiftUI
import BAMCore

/// Shared sidebar list chrome for the main navigation split view.
public struct SidebarChrome: View {
    @Binding public var selection: SidebarDestination?

    public init(selection: Binding<SidebarDestination?>) {
        self._selection = selection
    }

    public var body: some View {
        List(selection: $selection) {
            Section("Studio") {
                ForEach(SidebarDestination.allCases.filter { !$0.isAdvanced }) { destination in
                    Label(destination.title, systemImage: destination.systemImage)
                        .tag(destination)
                }
            }
            Section("Advanced") {
                ForEach(SidebarDestination.allCases.filter(\.isAdvanced)) { destination in
                    Label(destination.title, systemImage: destination.systemImage)
                        .tag(destination)
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(AppIdentity.displayName)
    }
}
