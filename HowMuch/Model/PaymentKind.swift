import Foundation

enum PaymentKind: Int16, CaseIterable, Identifiable, Sendable {
    case cash = 0
    case creditCard = 1
    case debitCard = 2
    case alipay = 3
    case wechat = 4
    case bankTransfer = 5
    case other = 6

    var id: Int16 { rawValue }

    var title: String {
        switch self {
        case .cash:
            String(localized: "Cash", comment: "Payment method kind")
        case .creditCard:
            String(localized: "Credit Card", comment: "Payment method kind")
        case .debitCard:
            String(localized: "Debit Card", comment: "Payment method kind")
        case .alipay:
            String(localized: "Alipay", comment: "Payment method kind")
        case .wechat:
            String(localized: "WeChat", comment: "Payment method kind")
        case .bankTransfer:
            String(localized: "Bank Transfer", comment: "Payment method kind")
        case .other:
            String(localized: "Other", comment: "Payment method kind")
        }
    }

    var symbolName: String {
        switch self {
        case .cash: "banknote"
        case .creditCard: "creditcard"
        case .debitCard: "creditcard.fill"
        case .alipay: "qrcode"
        case .wechat: "message"
        case .bankTransfer: "building.columns"
        case .other: "wallet.pass"
        }
    }
}
