import Foundation
import NaturalLanguage

struct ParsedReceipt {
    var amount: Double?
    var merchant: String?
    var date: Date?
    var suggestedCategory: Category?
}

enum ReceiptParser {
    static func parse(text: String, categories: [Category]) -> ParsedReceipt {
        var result = ParsedReceipt()

        result.amount = extractAmount(from: text)
        result.merchant = extractMerchant(from: text)
        result.date = extractDate(from: text) ?? Date()
        result.suggestedCategory = suggestCategory(from: text.lowercased(), categories: categories)

        return result
    }

    private static func extractAmount(from text: String) -> Double? {
        // Clean OCR artifacts
        let cleaned = cleanOCRArtifacts(text)

        // Patterns for currency formats - ordered by priority (most specific first)
        let patterns = [
            // Explicit total labels (Spanish variations)
            #"(?:tu\s*)?total\s*(?:a\s*pagar|final|es)?[:\s]*\$?\s*([\d\s.,]+)"#,
            #"monto\s*total\s*(?:recibido|enviado)?[:\s]*\$?\s*([\d\s.,]+)"#,
            #"(?:importe|monto)\s*(?:total|a\s*pagar|enviado)?[:\s]*\$?\s*([\d\s.,]+)"#,
            #"(?:total|subtotal|a\s*pagar|pagado|cobrado|presupuesto)[:\s]*\$?\s*([\d\s.,]+)"#,
            #"(?:valor\s*de\s*la\s*factura|total\s*pagado)[:\s]*\$?\s*([\d\s.,]+)"#,
            #"cargo\s*(?:por\s*envío?|total)?[:\s]*\$?\s*([\d\s.,]+)"#,
            // Large currency amounts with $ prefix
            #"\$\s*([\d]{1,3}(?:[.,]\d{3})+(?:[.,]\d{2})?)"#,
            // Simple currency prefix
            #"\$\s*([\d\s.,]+)"#,
            #"(?:ars|ar\$|pesos)\s*([\d\s.,]+)"#,
        ]

        // Try each pattern
        for pattern in patterns {
            let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
            let range = NSRange(cleaned.startIndex..., in: cleaned)

            // Get all matches and pick the last one (usually the final total)
            var lastMatch: Double?
            regex?.enumerateMatches(in: cleaned, options: [], range: range) { match, _, _ in
                if let match = match,
                   match.numberOfRanges > 1,
                   let numRange = Range(match.range(at: 1), in: cleaned) {
                    let numStr = String(cleaned[numRange])
                    if let value = parseNumber(numStr), value > 0 {
                        lastMatch = value
                    }
                }
            }

            if let value = lastMatch {
                return value
            }
        }

        // Fallback: find all numbers and pick the largest reasonable one
        let numberPattern = #"\$?\s*([\d\s]{1,3}(?:[.,\s]\d{3})*(?:[.,]\d{1,2})?)"#
        let regex = try? NSRegularExpression(pattern: numberPattern, options: [])
        let range = NSRange(cleaned.startIndex..., in: cleaned)

        var values: [Double] = []
        regex?.enumerateMatches(in: cleaned, options: [], range: range) { match, _, _ in
            if let match = match, let range = Range(match.range, in: cleaned) {
                var numStr = String(cleaned[range])
                numStr = numStr.replacingOccurrences(of: "$", with: "")
                numStr = numStr.trimmingCharacters(in: .whitespaces)

                if let value = parseNumber(numStr), value > 0 && value < 10_000_000 {
                    values.append(value)
                }
            }
        }

        // Return the largest value (likely the total)
        return values.max()
    }

    // Fix common OCR misreads
    private static func cleanOCRArtifacts(_ text: String) -> String {
        // Common OCR substitutions in number contexts
        // Only apply near currency symbols or keywords to avoid breaking text
        let lines = text.components(separatedBy: .newlines)
        var cleanedLines: [String] = []

        for line in lines {
            var cleanedLine = line

            // If line contains price indicators, clean up number-like characters
            let priceIndicators = ["$", "total", "importe", "monto", "pagar", "ars"]
            let hasPriceContext = priceIndicators.contains { line.lowercased().contains($0) }

            if hasPriceContext {
                // Fix O/0 confusion in numbers (e.g., "1O0" -> "100")
                cleanedLine = cleanedLine.replacingOccurrences(of: "O", with: "0")
                cleanedLine = cleanedLine.replacingOccurrences(of: "o", with: "0")
                // Fix l/1 confusion
                cleanedLine = cleanedLine.replacingOccurrences(of: "l", with: "1")
                cleanedLine = cleanedLine.replacingOccurrences(of: "I", with: "1")
            }

            cleanedLines.append(cleanedLine)
        }

        return cleanedLines.joined(separator: "\n")
    }

    // Detect format and parse number correctly
    private static func parseNumber(_ str: String) -> Double? {
        // Remove spaces (some formats use spaces as thousand separators)
        var trimmed = str.trimmingCharacters(in: .whitespaces)
        trimmed = trimmed.replacingOccurrences(of: " ", with: "")

        // Skip if empty or just punctuation
        guard !trimmed.isEmpty, trimmed.contains(where: { $0.isNumber }) else {
            return nil
        }

        // Check if it ends with .XX or .X (US format: 8500.00 or 8500.5)
        if trimmed.range(of: #"\.\d{1,2}$"#, options: .regularExpression) != nil {
            // US format: period is decimal separator
            let cleaned = trimmed.replacingOccurrences(of: ",", with: "")
            return Double(cleaned)
        }

        // Check if it ends with ,XX or ,X (Argentine format: 8500,00 or 8500,5)
        if trimmed.range(of: #",\d{1,2}$"#, options: .regularExpression) != nil {
            // Argentine format: comma is decimal, periods are thousands
            var cleaned = trimmed.replacingOccurrences(of: ".", with: "")
            cleaned = cleaned.replacingOccurrences(of: ",", with: ".")
            return Double(cleaned)
        }

        // No clear decimal part - remove all separators and parse as integer
        let cleaned = trimmed
            .replacingOccurrences(of: ",", with: "")
            .replacingOccurrences(of: ".", with: "")
        return Double(cleaned)
    }

    private static func extractMerchant(from text: String) -> String? {
        // 1. Try known merchants first (fast path)
        if let known = findKnownMerchant(in: text) {
            return known
        }

        // 2. Use NaturalLanguage NER to find organization names
        if let nerResult = extractMerchantWithNER(from: text) {
            return nerResult
        }

        // 3. Fallback: first non-empty line that looks like a name
        return extractMerchantFromFirstLine(from: text)
    }

    private static var cachedMerchants: [(pattern: String, name: String)]?

    private static func loadMerchants() -> [(pattern: String, name: String)] {
        if let cached = cachedMerchants {
            return cached
        }

        guard let url = Bundle.main.url(forResource: "merchants", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let merchants = json["merchants"] as? [[String: String]] else {
            return []
        }

        let result = merchants.compactMap { dict -> (String, String)? in
            guard let pattern = dict["pattern"], let name = dict["name"] else { return nil }
            return (pattern, name)
        }

        cachedMerchants = result
        return result
    }

    private static func findKnownMerchant(in text: String) -> String? {
        let lowercased = text.lowercased()
        let merchants = loadMerchants()

        for (pattern, name) in merchants {
            if lowercased.range(of: pattern, options: .regularExpression) != nil {
                return name
            }
        }
        return nil
    }

    private static func extractMerchantWithNER(from text: String) -> String? {
        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text

        var organizationNames: [(name: String, position: Int)] = []
        var currentPosition = 0

        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitPunctuation, .omitWhitespace, .joinNames]
        ) { tag, range in
            if tag == .organizationName {
                let name = String(text[range]).trimmingCharacters(in: .whitespaces)
                if name.count > 2 && name.count < 50 {
                    organizationNames.append((name, currentPosition))
                }
            }
            currentPosition += 1
            return true
        }

        // Prefer organization names that appear early in the text (likely header)
        return organizationNames.first?.name
    }

    private static func extractMerchantFromFirstLine(from text: String) -> String? {
        let lines = text.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }

        let skipPatterns = [
            #"^\d{1,2}[\/\-]\d{1,2}"#,
            #"^[\d$.,\s]+$"#,
            #"^hoja\s*\d"#,
            #"^comprobante"#,
            #"^resumen"#,
            #"^factura"#,
            #"^ticket"#,
        ]

        for line in lines.prefix(5) {
            let shouldSkip = skipPatterns.contains { pattern in
                line.lowercased().range(of: pattern, options: .regularExpression) != nil
            }

            if !shouldSkip && line.count > 3 && line.count < 50 {
                let cleaned = line
                    .replacingOccurrences(of: #"[^\w\s\-&áéíóúñÁÉÍÓÚÑ]"#, with: "", options: .regularExpression)
                    .trimmingCharacters(in: .whitespaces)

                if cleaned.count > 2 {
                    return String(cleaned.prefix(50))
                }
            }
        }
        return nil
    }

    private static func extractDate(from text: String) -> Date? {
        let datePatterns: [(pattern: String, format: String)] = [
            (#"(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{4})"#, "dd/MM/yyyy"),
            (#"(\d{1,2})[\/\-](\d{1,2})[\/\-](\d{2})"#, "dd/MM/yy"),
            (#"(\d{4})[\/\-](\d{1,2})[\/\-](\d{1,2})"#, "yyyy/MM/dd"),
        ]

        for (pattern, _) in datePatterns {
            if let match = text.range(of: pattern, options: .regularExpression) {
                let dateStr = String(text[match])

                // Parse components
                let components = dateStr.components(separatedBy: CharacterSet(charactersIn: "/-"))
                guard components.count == 3 else { continue }

                var day, month, year: Int

                if components[0].count == 4 {
                    // yyyy/mm/dd format
                    year = Int(components[0]) ?? 0
                    month = Int(components[1]) ?? 0
                    day = Int(components[2]) ?? 0
                } else {
                    // dd/mm/yyyy format
                    day = Int(components[0]) ?? 0
                    month = Int(components[1]) ?? 0
                    year = Int(components[2]) ?? 0
                    if year < 100 { year += 2000 }
                }

                if day >= 1 && day <= 31 && month >= 1 && month <= 12 {
                    var dateComponents = DateComponents()
                    dateComponents.year = year
                    dateComponents.month = month
                    dateComponents.day = day

                    return Calendar.current.date(from: dateComponents)
                }
            }
        }

        return nil
    }

    private static func suggestCategory(from text: String, categories: [Category]) -> Category? {
        for category in categories {
            for keyword in category.keywordList {
                if !keyword.isEmpty && text.contains(keyword) {
                    return category
                }
            }
        }
        return nil
    }
}
