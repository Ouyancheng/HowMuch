import SwiftUI

extension View {
    /// Liquid Glass on iOS 26 / macOS 26+, material fallback earlier.
    /// Use only on floating controls (banners, chips, prominent buttons)—not lists or column fills.
    @ViewBuilder
    func hmGlass<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    @ViewBuilder
    func hmGlassInteractive<S: Shape>(in shape: S) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular.interactive(), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }

    @ViewBuilder
    func hmGlassProminentButton() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
        } else {
            self.buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    func hmGlassRoundProminentButton() -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.buttonStyle(.glassProminent)
                .buttonBorderShape(.circle)
                .controlSize(.extraLarge)
        } else {
            self.buttonStyle(.borderedProminent)
                .buttonBorderShape(.circle)
                .controlSize(.large)
        }
    }

    @ViewBuilder
    func hmGlassChoiceButton(isSelected: Bool) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            if isSelected {
                self.buttonStyle(.glassProminent)
                    .buttonBorderShape(.capsule)
            } else {
                self.buttonStyle(.glass)
                    .buttonBorderShape(.capsule)
            }
        } else if isSelected {
            self.buttonStyle(.borderedProminent)
        } else {
            self.buttonStyle(.bordered)
        }
    }
}

struct HMGlassGroup<Content: View>: View {
    var spacing: CGFloat = 16
    @ViewBuilder var content: () -> Content

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) {
                content()
            }
        } else {
            content()
        }
    }
}
