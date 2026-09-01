import SwiftUI

extension Text {
    func hmWrappingFooter() -> some View {
        self
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HMSettingsValueRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(title)
            Spacer(minLength: 12)
            Text(value)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }
}

extension View {
    func hmWrappingText() -> some View {
        self
            .multilineTextAlignment(.leading)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    func hmFormSheetFrame() -> some View {
        #if os(macOS)
        self.frame(minWidth: 440, idealWidth: 480, minHeight: 360, idealHeight: 440)
        #else
        self
        #endif
    }

    @ViewBuilder
    func hmSettingsSheetFrame() -> some View {
        #if os(macOS)
        self.frame(minWidth: 400, idealWidth: 440, minHeight: 280, idealHeight: 360)
        #else
        self
        #endif
    }

    @ViewBuilder
    func hmPaymentEditorFrame() -> some View {
        #if os(macOS)
        self.frame(minWidth: 460, idealWidth: 500, minHeight: 540, idealHeight: 600)
        #else
        self
        #endif
    }
}
