import Foundation

/// Tokenizer for Donut model - handles vocabulary and output parsing
actor DonutTokenizer {
    private var vocab: [String: Int] = [:]
    private var reverseVocab: [Int: String] = [:]

    // Special tokens
    private(set) var bosTokenId: Int = 0
    private(set) var eosTokenId: Int = 2
    private(set) var padTokenId: Int = 1
    private(set) var decoderStartTokenId: Int = 2
    private(set) var vocabSize: Int = 0

    /// Tokenizer errors
    enum TokenizerError: Error {
        case vocabLoadFailed(String)
        case specialTokensLoadFailed(String)
    }

    init() async throws {
        try await loadVocabulary()
        try await loadSpecialTokens()
    }

    /// Load vocabulary from bundled JSON
    private func loadVocabulary() async throws {
        guard let url = Bundle.main.url(forResource: "donut_vocab", withExtension: "json") else {
            throw TokenizerError.vocabLoadFailed("donut_vocab.json not found in bundle")
        }

        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Int] else {
            throw TokenizerError.vocabLoadFailed("Failed to parse donut_vocab.json")
        }

        vocab = json
        reverseVocab = Dictionary(uniqueKeysWithValues: json.map { ($1, $0) })
    }

    /// Load special tokens from bundled JSON
    private func loadSpecialTokens() async throws {
        guard let url = Bundle.main.url(forResource: "donut_special_tokens", withExtension: "json") else {
            throw TokenizerError.specialTokensLoadFailed("donut_special_tokens.json not found in bundle")
        }

        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TokenizerError.specialTokensLoadFailed("Failed to parse donut_special_tokens.json")
        }

        bosTokenId = json["bos_token_id"] as? Int ?? 0
        eosTokenId = json["eos_token_id"] as? Int ?? 2
        padTokenId = json["pad_token_id"] as? Int ?? 1
        // decoder_start_token_id may be null - use bos_token_id as fallback
        decoderStartTokenId = json["decoder_start_token_id"] as? Int ?? bosTokenId
        vocabSize = json["vocab_size"] as? Int ?? vocab.count
    }

    /// Encode task prompt to initial token IDs for decoder
    func encodeTaskPrompt() -> [Int] {
        // Start with decoder start token
        // The task prompt (<s_cord-v2>) tells the model to extract receipt info
        var tokens = [decoderStartTokenId]

        // Add task prompt token if available
        if let taskTokenId = vocab["<s_cord-v2>"] {
            tokens.append(taskTokenId)
        }

        return tokens
    }

    /// Decode token IDs to text string
    func decode(_ tokenIds: [Int]) -> String {
        var result = ""

        for tokenId in tokenIds {
            // Skip special tokens
            if tokenId == eosTokenId || tokenId == padTokenId || tokenId == bosTokenId {
                continue
            }

            if let token = reverseVocab[tokenId] {
                var cleanToken = token

                // Handle subword tokens (BPE with Ġ prefix for space)
                if cleanToken.hasPrefix("Ġ") {
                    cleanToken = " " + String(cleanToken.dropFirst())
                }

                // Handle special XML-like tokens
                if cleanToken.hasPrefix("<") && cleanToken.hasSuffix(">") {
                    result += cleanToken
                } else {
                    result += cleanToken
                }
            }
        }

        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Parse Donut output to structured dictionary
    /// CORD format uses nested structure like <s_total><s_total_price>value</s_total_price></s_total>
    func parseDonutOutput(_ text: String) -> DonutParsedOutput {
        var output = DonutParsedOutput()

        // Store raw output for debugging
        output.rawText = text

        // Pattern to extract key-value pairs from Donut XML-like output
        // Format: <s_fieldname>value</s_fieldname>
        let pattern = #"<s_(\w+)>(.*?)</s_\1>"#

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return output
        }

        let range = NSRange(text.startIndex..., in: text)
        let matches = regex.matches(in: text, options: [], range: range)

        for match in matches {
            guard match.numberOfRanges >= 3,
                  let keyRange = Range(match.range(at: 1), in: text),
                  let valueRange = Range(match.range(at: 2), in: text) else {
                continue
            }

            let key = String(text[keyRange])
            let value = String(text[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)

            // Map known fields (handle both direct and CORD nested formats)
            switch key {
            // Merchant/store fields
            case "merchant", "store_name", "store", "vendor":
                output.merchant = value
            // Total fields - CORD uses nested total_price inside total
            case "total_price", "total_etc", "total":
                // Extract total_price from nested structure if present
                if let totalPrice = extractNestedValue(from: value, key: "total_price") {
                    output.total = totalPrice
                } else if output.total == nil && !value.contains("<s_") {
                    output.total = value
                }
            // Date fields
            case "date", "transaction_date":
                output.date = value
            // Subtotal
            case "subtotal", "sub_total", "subtotal_price":
                if let subPrice = extractNestedValue(from: value, key: "subtotal_price") {
                    output.subtotal = subPrice
                } else if !value.contains("<s_") {
                    output.subtotal = value
                }
            // Tax
            case "tax", "vat", "tax_price":
                output.tax = value
            // Address
            case "address":
                output.address = value
            // Menu items - skip for now (too complex)
            case "menu", "nm", "cnt", "price", "unitprice", "itemsubtotal", "discountprice", "sub_nm", "sub_cnt", "sub_price", "sub_unitprice", "etc":
                // Skip menu item details
                break
            default:
                // Store unknown fields
                output.additionalFields[key] = value
            }
        }

        return output
    }

    /// Extract a nested value from CORD format like <s_key>value</s_key>
    private func extractNestedValue(from text: String, key: String) -> String? {
        let pattern = "<s_\(key)>(.*?)</s_\(key)>"
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }

        let range = NSRange(text.startIndex..., in: text)
        if let match = regex.firstMatch(in: text, options: [], range: range),
           match.numberOfRanges >= 2,
           let valueRange = Range(match.range(at: 1), in: text) {
            return String(text[valueRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return nil
    }
}

/// Structured output from Donut model
struct DonutParsedOutput {
    var merchant: String?
    var total: String?
    var subtotal: String?
    var tax: String?
    var date: String?
    var address: String?
    var additionalFields: [String: String] = [:]
    var rawText: String = ""

    /// Check if we got meaningful data
    var hasMeaningfulData: Bool {
        merchant != nil || total != nil || date != nil
    }
}
