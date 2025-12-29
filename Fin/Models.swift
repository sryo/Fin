import Foundation
import SwiftData
import SwiftUI

@Model
final class Category {
    var name: String
    var emoji: String
    var colorHex: String
    var keywords: String

    @Relationship(deleteRule: .nullify, inverse: \Expense.category)
    var expenses: [Expense]?

    init(name: String, emoji: String, colorHex: String, keywords: String = "") {
        self.name = name
        self.emoji = emoji
        self.colorHex = colorHex
        self.keywords = keywords
    }

    var color: Color {
        Color(hex: colorHex)
    }

    var keywordList: [String] {
        keywords.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
    }
}

@Model
final class Expense {
    var amount: Double
    var merchant: String?
    var date: Date
    var notes: String?
    var imageData: Data?
    var createdAt: Date

    var category: Category?

    init(amount: Double, merchant: String? = nil, category: Category? = nil, date: Date = Date(), notes: String? = nil, imageData: Data? = nil) {
        self.amount = amount
        self.merchant = merchant
        self.category = category
        self.date = date
        self.notes = notes
        self.imageData = imageData
        self.createdAt = Date()
    }
}

// Color extension to parse hex
extension Color {
    init(hex: String) {
        let hex = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r, g, b: UInt64
        switch hex.count {
        case 6:
            (r, g, b) = ((int >> 16) & 0xFF, (int >> 8) & 0xFF, int & 0xFF)
        default:
            (r, g, b) = (128, 128, 128)
        }
        self.init(
            .sRGB,
            red: Double(r) / 255,
            green: Double(g) / 255,
            blue: Double(b) / 255,
            opacity: 1
        )
    }
}

// Currency formatting
extension Double {
    var currencyFormatted: String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "es_AR")
        return formatter.string(from: NSNumber(value: self)) ?? "$\(self)"
    }
}

// Date formatting
extension Date {
    var shortFormatted: String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.locale = Locale(identifier: "es_AR")
        return formatter.string(from: self)
    }
}
