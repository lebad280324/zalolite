import AppKit
import SwiftUI

// Fallbacks for the macOS 13 edition. Each helper calls the macOS 14 API unchanged in the default
// build; only a `LEGACY_MACOS13` build takes the older path.

/// Whether this binary is the macOS 13 edition; the updater uses it to stay on the matching download.
let isLegacyMacOS13Edition: Bool = {
    #if LEGACY_MACOS13
    return true
    #else
    return false
    #endif
}()

/// Opens Settings through the app menu's own ⌘, item, which works on every supported macOS.
@MainActor func openSettingsFromMenu() {
    if let item = NSApp.mainMenu?.items.first?.submenu?.items.first(where: { $0.keyEquivalent == "," }),
       let menu = item.menu, let index = menu.items.firstIndex(of: item) { menu.performActionForItem(at: index) }
}

#if LEGACY_MACOS13
struct LegacySettingsOpener { @MainActor func callAsFunction() { openSettingsFromMenu() } }
#endif

/// Stands in for `@Environment(\.openSettings)`.
@propertyWrapper struct OpenSettingsCompat: DynamicProperty {
    #if LEGACY_MACOS13
    var wrappedValue: LegacySettingsOpener { LegacySettingsOpener() }
    #else
    @Environment(\.openSettings) private var action
    var wrappedValue: OpenSettingsAction { action }
    #endif
    init() {}
}

/// Stands in for `SettingsLink`.
struct SettingsLinkCompat<Label: View>: View {
    @ViewBuilder var label: () -> Label
    var body: some View {
        #if LEGACY_MACOS13
        Button(action: openSettingsFromMenu, label: label)
        #else
        SettingsLink(label: label)
        #endif
    }
}

/// Stands in for `ContentUnavailableView`.
struct EmptyState<Actions: View>: View {
    let title: String
    let systemImage: String
    let description: Text?
    let actions: Actions

    init(_ title: String, systemImage: String, description: Text? = nil) where Actions == EmptyView {
        self.title = title; self.systemImage = systemImage; self.description = description; actions = EmptyView()
    }

    init(_ title: String, systemImage: String, description: Text? = nil, @ViewBuilder actions: () -> Actions) {
        self.title = title; self.systemImage = systemImage; self.description = description; self.actions = actions()
    }

    var body: some View {
        #if LEGACY_MACOS13
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.system(size: 38, weight: .regular)).foregroundStyle(.secondary)
            Text(title).font(.title3.weight(.semibold))
            if let description { description.font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center) }
            actions
        }
        .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
        #else
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            if let description { description }
        } actions: { actions }
        #endif
    }
}

#if LEGACY_MACOS13
/// Replays `onChange(of:initial:_:)` with the old value on macOS 13.
private struct LegacyValueChange<V: Equatable>: ViewModifier {
    let value: V
    let initial: Bool
    let action: (V, V) -> Void
    @State private var previous: V?

    func body(content: Content) -> some View {
        content
            .onAppear { previous = value; if initial { action(value, value) } }
            .onChange(of: value) { new in action(previous ?? new, new); previous = new }
    }
}
#endif

extension View {
    /// Stands in for `onChange(of:initial:_:)`.
    func onValueChange<V: Equatable>(of value: V, initial: Bool = false, _ action: @escaping (V, V) -> Void) -> some View {
        #if LEGACY_MACOS13
        modifier(LegacyValueChange(value: value, initial: initial, action: action))
        #else
        onChange(of: value, initial: initial, action)
        #endif
    }

    @ViewBuilder func capsuleButtonShape() -> some View {
        #if LEGACY_MACOS13
        buttonBorderShape(.roundedRectangle)
        #else
        buttonBorderShape(.capsule)
        #endif
    }

    @ViewBuilder func replaceSymbolTransition() -> some View {
        #if LEGACY_MACOS13
        self
        #else
        contentTransition(.symbolEffect(.replace))
        #endif
    }

    @ViewBuilder func materialPresentationBackground() -> some View {
        #if LEGACY_MACOS13
        if #available(macOS 13.3, *) { presentationBackground(.ultraThinMaterial) } else { self }
        #else
        presentationBackground(.ultraThinMaterial)
        #endif
    }

    @ViewBuilder func removingSidebarToggle() -> some View {
        #if LEGACY_MACOS13
        self
        #else
        toolbar(removing: .sidebarToggle)
        #endif
    }

    /// The reaction pill's pop; macOS 13 has no keyframe animator, so it stays still there.
    @ViewBuilder func reactionPop<T: Equatable>(trigger: T, reducedMotion: Bool) -> some View {
        #if LEGACY_MACOS13
        self
        #else
        keyframeAnimator(initialValue: 1.0, trigger: trigger) { content, scale in
            content.scaleEffect(reducedMotion ? 1 : scale)
        } keyframes: { _ in
            SpringKeyframe(1.28, duration: 0.12)
            SpringKeyframe(1.0, duration: 0.35, spring: .bouncy)
        }
        #endif
    }
}

extension Text {
    /// `Text`-returning tint, so tinted pieces can still be joined with `+`.
    func tinted(_ color: Color) -> Text {
        #if LEGACY_MACOS13
        foregroundColor(color)
        #else
        foregroundStyle(color)
        #endif
    }
}
