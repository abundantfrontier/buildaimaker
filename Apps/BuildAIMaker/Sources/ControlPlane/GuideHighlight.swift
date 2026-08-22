import SwiftUI

private struct GuideHighlightIdKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var guideHighlightId: String? {
        get { self[GuideHighlightIdKey.self] }
        set { self[GuideHighlightIdKey.self] = newValue }
    }
}

/// Rings a control when the session highlight matches.
struct GuideHighlightModifier: ViewModifier {
    let id: String
    @Environment(\.guideHighlightId) private var active

    func body(content: Content) -> some View {
        let on = !id.isEmpty && active == id
        content
            .overlay {
                if on {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.accentColor, lineWidth: 3)
                }
            }
            .shadow(color: on ? Color.accentColor.opacity(0.45) : .clear, radius: 8)
    }
}

extension View {
    func guideHighlight(_ id: String) -> some View {
        modifier(GuideHighlightModifier(id: id))
    }
}
