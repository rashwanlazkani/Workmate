import SwiftUI
// Keep native text editing and keyboard behavior without the legacy AppKit bezel.
struct NativeSearchField: View {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void = {}

    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary).accessibilityHidden(true)
            TextField(placeholder, text: $text)
                .textFieldStyle(.plain).font(.system(size: 14))
                .focused($focused).onSubmit(onSubmit).accessibilityLabel(placeholder)
            if !text.isEmpty {
                Button { text = ""; focused = true } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14)).foregroundStyle(.tertiary)
                }.buttonStyle(FullHitButtonStyle()).accessibilityLabel("Clear search").help("Clear search")
            }
        }
        .padding(.horizontal, 15).frame(height: 42)
        .background(Palette.field, in: Capsule())
        .overlay { Capsule().strokeBorder(focused ? Palette.accent.opacity(0.8) : Color.primary.opacity(0.08), lineWidth: 1) }
        .animation(.easeOut(duration: 0.15), value: focused)
        .focusOnEntry($focused)
    }
}
