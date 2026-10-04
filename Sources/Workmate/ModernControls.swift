import SwiftUI

extension View {
    func modernButtonStyle(prominent: Bool = false, shape: ControlShape = .capsule) -> some View {
        buttonStyle(ModernButtonAppearance(prominent: prominent, shape: shape))
    }
    func modernTextField(autofocus: Bool = false) -> some View { modifier(ModernTextFieldAppearance(autofocus: autofocus)) }
    func popoverSurface() -> some View {
        interactiveDismissDisabled()
            .background(PopoverKeyboard().frame(width: 0, height: 0))
            .background(Palette.background)
            .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.line).allowsHitTesting(false) }
            .foregroundStyle(Palette.foreground)
            .tint(Palette.accent).preferredColorScheme(.dark)
    }
    func focusOnEntry(_ focus: FocusState<Bool>.Binding, when enabled: Bool = true) -> some View {
        modifier(TextFieldEntryFocus(focus: focus, enabled: enabled))
    }
}

private struct TextFieldEntryFocus: ViewModifier {
    var focus: FocusState<Bool>.Binding
    var enabled: Bool
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content.task {
            guard enabled && isEnabled else { return }
            // Request focus after SwiftUI has attached the newly presented field.
            await Task.yield()
            guard !Task.isCancelled else { return }
            focus.wrappedValue = true
        }
    }
}

enum ControlShape { case capsule, circle }

private struct ModernButtonAppearance: ButtonStyle {
    var prominent: Bool
    var shape: ControlShape
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        surface(configuration.label
            .font(.system(size: 13, weight: .medium))
            .foregroundStyle(prominent ? Color.white : Color.white.opacity(0.85))
            .padding(.horizontal, shape == .circle ? 0 : 15)
            .frame(minWidth: shape == .circle ? 32 : nil, minHeight: 32)
        )
        .opacity(isEnabled ? 1 : 0.4)
        .scaleEffect(configuration.isPressed ? 0.97 : 1)
        .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }

    @ViewBuilder private func surface<Label: View>(_ label: Label) -> some View {
        if #available(macOS 26.0, *) {
            label.glassEffect(.regular.tint(prominent ? Palette.accent : Color.white.opacity(0.04)).interactive(), in: .capsule)
        } else {
            label.background(prominent ? Palette.accent : Color.white.opacity(0.08), in: Capsule())
                .overlay { Capsule().strokeBorder(Color.white.opacity(0.10)) }
        }
    }
}

private struct ModernTextFieldAppearance: ViewModifier {
    var autofocus: Bool
    @FocusState private var focused: Bool
    func body(content: Content) -> some View {
        content.textFieldStyle(.plain).font(.system(size: 14)).focused($focused)
            .padding(.horizontal, 14).padding(.vertical, 11)
            .background(Palette.field, in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .strokeBorder(focused ? Palette.accent.opacity(0.8) : Color.primary.opacity(0.08), lineWidth: 1)
            }
            .animation(.easeOut(duration: 0.15), value: focused)
            .focusOnEntry($focused, when: autofocus)
    }
}

struct PopoverCloseButton: View {
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 15, height: 15)
        }.modernButtonStyle(shape: .circle)
            .accessibilityLabel("Close").help("Close · Esc").keyboardShortcut(.cancelAction)
    }
}
