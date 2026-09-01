import SwiftUI

struct CurrencyPicker: View {
    @Binding var code: String
    var featuredOnly: Bool = false

    private var codes: [String] {
        featuredOnly ? CurrencyCatalog.featured : CurrencyCatalog.allCodes
    }

    var body: some View {
        Picker(String(localized: "Currency", comment: "Field"), selection: $code) {
            ForEach(codes, id: \.self) { item in
                Text(item).tag(item)
            }
        }
        .labelsHidden()
        .accessibilityLabel(String(localized: "Currency", comment: "Field"))
        .accessibilityValue(CurrencyCatalog.displayName(for: code))
    }
}
