import Foundation
import NaturalLanguage
import UIKit

struct ParsedReceipt {
    var amount: Double?
    var merchant: String?
    var date: Date?
    var suggestedCategory: Category?
    var confidence: ParseConfidence = .low
}

enum ParseConfidence: Int, Comparable {
    case low = 0
    case medium = 1
    case high = 2  // Found near strong keywords like "TOTAL", "SU PAGO"

    static func < (lhs: ParseConfidence, rhs: ParseConfidence) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

enum ReceiptParser {
    // Strong keywords that indicate high confidence for amount extraction
    private static let strongKeywords = [
        "total", "su pago", "a pagar", "importe total", "monto total",
        "total a pagar", "tu total", "pagado", "cobrado"
    ]

    // MARK: - Primary Parser (Parallel Donut + Regex)

    /// Parse receipt using both Donut ML and regex in parallel, then merge results
    /// - Parameters:
    ///   - image: Receipt image for Donut processing (optional)
    ///   - text: OCR text for regex parsing
    ///   - categories: Available categories for suggestion
    /// - Returns: Merged parsed receipt data
    static func parse(
        image: UIImage?,
        text: String,
        categories: [Category]
    ) async -> ParsedReceipt {
        print("[ReceiptParser] Starting parallel parse, image: \(image != nil), text length: \(text.count)")

        // Run regex immediately (fast)
        let regexResult = parseWithRegex(text: text, categories: categories)
        print("[ReceiptParser] Regex - amount: \(regexResult.amount ?? 0), confidence: \(regexResult.confidence), merchant: \(regexResult.merchant ?? "nil")")

        // Run Donut in parallel if image available
        var donutResult: ParsedReceipt?
        if let image = image {
            do {
                donutResult = try await parseWithDonut(image: image, text: text, categories: categories)
                print("[ReceiptParser] Donut - amount: \(donutResult?.amount ?? 0), merchant: \(donutResult?.merchant ?? "nil")")
            } catch {
                print("[ReceiptParser] Donut FAILED: \(error.localizedDescription)")
            }
        }

        // Merge results
        let merged = mergeResults(regex: regexResult, donut: donutResult, text: text, categories: categories)
        print("[ReceiptParser] Merged - amount: \(merged.amount ?? 0), merchant: \(merged.merchant ?? "nil"), source: \(merged.confidence)")
        return merged
    }

    // MARK: - Result Merging

    private static func mergeResults(
        regex: ParsedReceipt,
        donut: ParsedReceipt?,
        text: String,
        categories: [Category]
    ) -> ParsedReceipt {
        var result = ParsedReceipt()

        // Amount: prefer high-confidence regex, otherwise use Donut if available
        if regex.confidence >= .high, let regexAmount = regex.amount {
            result.amount = regexAmount
            result.confidence = .high
        } else if let donutAmount = donut?.amount, donutAmount > 0 {
            // Validate Donut amount against regex if both exist
            if let regexAmount = regex.amount, regex.confidence >= .medium {
                // If they're close (within 10%), trust regex with keywords
                let ratio = regexAmount / donutAmount
                if ratio > 0.9 && ratio < 1.1 {
                    result.amount = regexAmount
                    result.confidence = .high
                } else {
                    // Significant difference - prefer regex if it has keyword context
                    result.amount = regex.confidence >= .medium ? regexAmount : donutAmount
                    result.confidence = regex.confidence >= .medium ? regex.confidence : .medium
                }
            } else {
                result.amount = donutAmount
                result.confidence = .medium
            }
        } else {
            result.amount = regex.amount
            result.confidence = regex.confidence
        }

        // Merchant: prefer known merchant (regex), then Donut, then regex fallback
        if let regexMerchant = regex.merchant, isKnownMerchant(regexMerchant) {
            result.merchant = regexMerchant
        } else if let donutMerchant = donut?.merchant, !donutMerchant.isEmpty {
            result.merchant = donutMerchant
        } else {
            result.merchant = regex.merchant
        }

        // Date: prefer Donut (structured), fall back to regex
        result.date = donut?.date ?? regex.date ?? Date()

        // Category: merge search text from both sources
        let searchText = [result.merchant, donut?.merchant, regex.merchant, text]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()
        result.suggestedCategory = suggestCategory(from: searchText, categories: categories)

        return result
    }

    private static func isKnownMerchant(_ name: String) -> Bool {
        let merchants = loadMerchants()
        let lowercased = name.lowercased()
        return merchants.contains { $0.name.lowercased() == lowercased }
    }

    /// Legacy synchronous method for backward compatibility
    static func parse(text: String, categories: [Category]) -> ParsedReceipt {
        return parseWithRegex(text: text, categories: categories)
    }

    // MARK: - Donut-based Parsing

    private static func parseWithDonut(
        image: UIImage,
        text: String,
        categories: [Category]
    ) async throws -> ParsedReceipt {
        let service = DonutInferenceService.shared

        // Initialize if needed
        if await !service.isReady {
            try await service.initialize()
        }

        // Run inference with timeout
        let donutResult = try await service.processReceiptWithTimeout(image)

        var result = ParsedReceipt()

        // Use Donut extracted values
        result.amount = donutResult.total
        result.merchant = donutResult.merchant
        result.date = donutResult.date ?? Date()

        // Suggest category based on extracted text
        let searchText = [donutResult.merchant, donutResult.rawOutput, text]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        result.suggestedCategory = suggestCategory(from: searchText, categories: categories)

        return result
    }

    // MARK: - Regex-based Parsing

    private static func parseWithRegex(text: String, categories: [Category]) -> ParsedReceipt {
        var result = ParsedReceipt()

        let (amount, confidence) = extractAmountWithConfidence(from: text)
        result.amount = amount
        result.confidence = confidence
        result.merchant = extractMerchant(from: text)
        result.date = extractDate(from: text) ?? Date()
        result.suggestedCategory = suggestCategory(from: text.lowercased(), categories: categories)

        return result
    }

    private static func extractAmountWithConfidence(from text: String) -> (Double?, ParseConfidence) {
        // Clean OCR artifacts
        let cleaned = cleanOCRArtifacts(text)

        // High-confidence patterns (explicit total labels)
        let highConfidencePatterns = [
            // Standard totals (various formats seen in receipts)
            #"total[:\s]+\$?\s*([\d\s.,]+)"#,
            #"(?:tu\s*)?total\s*(?:a\s*pagar|final|es)?[:\s]*\$?\s*([\d\s.,]+)"#,
            #"su\s*pago[:\s]*\$?\s*([\d\s.,]+)"#,
            #"suma\s*de\s*sus\s*pagos[:\s]*\$?\s*([\d\s.,]+)"#,
            // Transfer/remittance (Western Union, etc.)
            #"monto\s*total\s*recibido[:\s]*\$?\s*([\d\s.,]+)"#,
            #"monto\s*(?:a\s*)?enviar[:\s]*\$?\s*([\d\s.,]+)"#,
            #"monto\s*(?:de\s*)?env[ií]o[:\s]*\$?\s*([\d\s.,]+)"#,
            #"monto\s*enviado[:\s]*\$?\s*([\d\s.,]+)"#,
            #"cargo\s*por\s*env[ií]o[:\s]*\$?\s*([\d\s.,]+)"#,
            // Digital wallets (Brubank, MercadoPago, etc.)
            #"(?:enviaste|transferiste)[:\s]*\$?\s*([\d\s.,]+)"#,
            #"(?:recibiste|te\s*transfirieron)[:\s]*\$?\s*([\d\s.,]+)"#,
            #"transferencia\s*(?:exitosa|realizada)?[:\s]*\$?\s*([\d\s.,]+)"#,
            // Bills / fines
            #"importe\s*(?:de\s*la\s*multa)?[:\s]*\$?\s*([\d\s.,]+)"#,
            #"total\s*facturado[:\s]*\$?\s*([\d\s.,]+)"#,
            #"saldo\s*(?:total|actual|a\s*pagar)[:\s]*\$?\s*([\d\s.,]+)"#,
            #"pago\s*m[ií]nimo[:\s]*\$?\s*([\d\s.,]+)"#,
            // Generic
            #"monto\s*(?:total|a\s*pagar)?[:\s]*\$?\s*([\d\s.,]+)"#,
        ]

        // Medium-confidence patterns
        let mediumConfidencePatterns = [
            #"(?:total|subtotal|a\s*pagar|pagado|cobrado|presupuesto)[:\s]*\$?\s*([\d\s.,]+)"#,
            #"cargo\s*(?:por\s*envío?|total)?[:\s]*\$?\s*([\d\s.,]+)"#,
            #"\$\s*([\d]{1,3}(?:[.,]\d{3})+(?:[.,]\d{2})?)"#,
        ]

        // Low-confidence patterns (just currency symbol)
        let lowConfidencePatterns = [
            #"\$\s*([\d\s.,]+)"#,
            #"(?:ars|ar\$|pesos)\s*([\d\s.,]+)"#,
        ]

        // Try high-confidence patterns first
        for pattern in highConfidencePatterns {
            if let value = extractLastMatch(pattern: pattern, from: cleaned) {
                return (value, .high)
            }
        }

        // Try medium-confidence patterns
        for pattern in mediumConfidencePatterns {
            if let value = extractLastMatch(pattern: pattern, from: cleaned) {
                return (value, .medium)
            }
        }

        // Try low-confidence patterns
        for pattern in lowConfidencePatterns {
            if let value = extractLastMatch(pattern: pattern, from: cleaned) {
                return (value, .low)
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

        return (values.max(), .low)
    }

    private static func extractLastMatch(pattern: String, from text: String) -> Double? {
        let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
        let range = NSRange(text.startIndex..., in: text)

        var lastMatch: Double?
        regex?.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            if let match = match,
               match.numberOfRanges > 1,
               let numRange = Range(match.range(at: 1), in: text) {
                let numStr = String(text[numRange])
                if let value = parseNumber(numStr), value > 0 {
                    lastMatch = value
                }
            }
        }
        return lastMatch
    }

    private static func extractAmount(from text: String) -> Double? {
        return extractAmountWithConfidence(from: text).0
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
