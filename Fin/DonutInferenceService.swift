import CoreML
import UIKit

/// Error types for Donut inference
enum DonutError: Error, LocalizedError {
    case modelNotFound(String)
    case modelLoadFailed(String)
    case preprocessingFailed(String)
    case encoderFailed(String)
    case decoderFailed(String)
    case tokenizerFailed(String)
    case timeout
    case notInitialized

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let name): return "Model not found: \(name)"
        case .modelLoadFailed(let reason): return "Model load failed: \(reason)"
        case .preprocessingFailed(let reason): return "Preprocessing failed: \(reason)"
        case .encoderFailed(let reason): return "Encoder failed: \(reason)"
        case .decoderFailed(let reason): return "Decoder failed: \(reason)"
        case .tokenizerFailed(let reason): return "Tokenizer failed: \(reason)"
        case .timeout: return "Inference timeout"
        case .notInitialized: return "Service not initialized"
        }
    }
}

/// Result from Donut inference
struct DonutResult {
    let merchant: String?
    let total: Double?
    let date: Date?
    let rawOutput: String
    let processingTime: TimeInterval

    /// Check if result has meaningful extracted data
    var hasMeaningfulData: Bool {
        merchant != nil || total != nil
    }
}

/// Service for running Donut model inference on receipts
/// Uses encoder-decoder architecture with autoregressive generation
actor DonutInferenceService {
    private var encoder: MLModel?
    private var decoder: MLModel?
    private var tokenizer: DonutTokenizer?

    private let maxSequenceLength = 512
    private let inferenceTimeout: TimeInterval = 15.0

    // Singleton
    static let shared = DonutInferenceService()

    private init() {}

    /// Check if service is ready for inference
    var isReady: Bool {
        encoder != nil && decoder != nil && tokenizer != nil
    }

    /// Initialize models - call on app launch or before first use
    func initialize() async throws {
        // Load all components concurrently
        async let encoderTask = loadEncoder()
        async let decoderTask = loadDecoder()
        async let tokenizerTask: DonutTokenizer = try DonutTokenizer()

        encoder = try await encoderTask
        decoder = try await decoderTask
        tokenizer = try await tokenizerTask

        print("[DonutInferenceService] Initialized successfully")
    }

    /// Unload models to free memory (call when app enters background)
    func unloadModels() {
        encoder = nil
        decoder = nil
        tokenizer = nil
        print("[DonutInferenceService] Models unloaded")
    }

    /// Load encoder model
    private func loadEncoder() async throws -> MLModel {
        // Try .mlmodelc first (compiled by Xcode), then .mlpackage
        var modelURL = Bundle.main.url(forResource: "DonutEncoder", withExtension: "mlmodelc")
        if modelURL == nil {
            modelURL = Bundle.main.url(forResource: "DonutEncoder", withExtension: "mlpackage")
        }

        guard let url = modelURL else {
            throw DonutError.modelNotFound("DonutEncoder.mlmodelc or .mlpackage")
        }

        let config = MLModelConfiguration()
        config.computeUnits = .all // Use Neural Engine when available

        do {
            let model = try MLModel(contentsOf: url, configuration: config)
            print("[DonutInferenceService] Encoder loaded from \(url.lastPathComponent)")
            return model
        } catch {
            throw DonutError.modelLoadFailed("Encoder: \(error.localizedDescription)")
        }
    }

    /// Load decoder model
    private func loadDecoder() async throws -> MLModel {
        // Try .mlmodelc first (compiled by Xcode), then .mlpackage
        var modelURL = Bundle.main.url(forResource: "DonutDecoder", withExtension: "mlmodelc")
        if modelURL == nil {
            modelURL = Bundle.main.url(forResource: "DonutDecoder", withExtension: "mlpackage")
        }

        guard let url = modelURL else {
            throw DonutError.modelNotFound("DonutDecoder.mlmodelc or .mlpackage")
        }

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndGPU // Flexible shapes work better without ANE

        do {
            let model = try MLModel(contentsOf: url, configuration: config)
            print("[DonutInferenceService] Decoder loaded from \(url.lastPathComponent)")
            return model
        } catch {
            throw DonutError.modelLoadFailed("Decoder: \(error.localizedDescription)")
        }
    }

    /// Process receipt image and extract structured data
    /// - Parameter image: Receipt image to process
    /// - Returns: Extracted receipt data
    func processReceipt(_ image: UIImage) async throws -> DonutResult {
        guard let encoder = encoder,
              let decoder = decoder,
              let tokenizer = tokenizer else {
            throw DonutError.notInitialized
        }

        let startTime = Date()

        // 1. Preprocess image
        let pixelValues: MLMultiArray
        do {
            pixelValues = try DonutImagePreprocessor.preprocess(image)
        } catch {
            throw DonutError.preprocessingFailed(error.localizedDescription)
        }

        // 2. Run encoder
        let encoderHiddenStates: MLMultiArray
        do {
            let encoderInput = try MLDictionaryFeatureProvider(dictionary: [
                "pixel_values": pixelValues
            ])
            let encoderOutput = try await encoder.prediction(from: encoderInput)

            guard let hiddenStates = encoderOutput.featureValue(for: "encoder_hidden_states")?.multiArrayValue else {
                throw DonutError.encoderFailed("No hidden states in output")
            }
            encoderHiddenStates = hiddenStates
        } catch let error as DonutError {
            throw error
        } catch {
            throw DonutError.encoderFailed(error.localizedDescription)
        }

        // 3. Autoregressive decoding
        var generatedTokens = await tokenizer.encodeTaskPrompt()
        let eosTokenId = await tokenizer.eosTokenId
        var isFinished = false

        while !isFinished && generatedTokens.count < maxSequenceLength {
            // Check timeout
            if Date().timeIntervalSince(startTime) > inferenceTimeout {
                print("[DonutInferenceService] Timeout reached, stopping generation")
                break
            }

            do {
                // Create input_ids tensor
                let inputIds = try createInputIdsTensor(generatedTokens)

                // Run decoder
                let decoderInput = try MLDictionaryFeatureProvider(dictionary: [
                    "input_ids": inputIds,
                    "encoder_hidden_states": encoderHiddenStates
                ])

                let decoderOutput = try await decoder.prediction(from: decoderInput)

                guard let logits = decoderOutput.featureValue(for: "logits")?.multiArrayValue else {
                    throw DonutError.decoderFailed("No logits in output")
                }

                // Greedy decode: get argmax of last position
                let nextToken = greedyDecode(logits: logits, sequenceLength: generatedTokens.count)

                if nextToken == eosTokenId {
                    isFinished = true
                } else {
                    generatedTokens.append(nextToken)
                }
            } catch let error as DonutError {
                throw error
            } catch {
                throw DonutError.decoderFailed(error.localizedDescription)
            }
        }

        // 4. Decode tokens to text
        let rawOutput = await tokenizer.decode(generatedTokens)

        // 5. Parse structured output
        let parsed = await tokenizer.parseDonutOutput(rawOutput)

        let processingTime = Date().timeIntervalSince(startTime)
        print("[DonutInferenceService] Processing completed in \(String(format: "%.2f", processingTime))s")
        print("[DonutInferenceService] Generated \(generatedTokens.count) tokens")
        print("[DonutInferenceService] Raw output: \(rawOutput.prefix(500))")
        print("[DonutInferenceService] Parsed total: \(parsed.total ?? "nil"), merchant: \(parsed.merchant ?? "nil")")

        // 6. Convert to DonutResult
        return DonutResult(
            merchant: parsed.merchant,
            total: parseAmount(parsed.total),
            date: parseDate(parsed.date),
            rawOutput: rawOutput,
            processingTime: processingTime
        )
    }

    /// Process with timeout wrapper
    func processReceiptWithTimeout(_ image: UIImage) async throws -> DonutResult {
        try await withThrowingTaskGroup(of: DonutResult.self) { group in
            group.addTask {
                try await self.processReceipt(image)
            }

            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(self.inferenceTimeout * 1_000_000_000))
                throw DonutError.timeout
            }

            guard let result = try await group.next() else {
                throw DonutError.timeout
            }

            group.cancelAll()
            return result
        }
    }

    // MARK: - Helper Methods

    /// Create MLMultiArray for input_ids
    private func createInputIdsTensor(_ tokenIds: [Int]) throws -> MLMultiArray {
        let shape: [NSNumber] = [1, NSNumber(value: tokenIds.count)]
        let tensor = try MLMultiArray(shape: shape, dataType: .int32)

        for (index, tokenId) in tokenIds.enumerated() {
            tensor[index] = NSNumber(value: Int32(tokenId))
        }

        return tensor
    }

    /// Greedy decode: argmax of logits at last position
    private func greedyDecode(logits: MLMultiArray, sequenceLength: Int) -> Int {
        // logits shape: [1, seq_len, vocab_size]
        let vocabSize = logits.shape[2].intValue
        let lastPositionOffset = (sequenceLength - 1) * vocabSize

        var maxValue: Float = -.infinity
        var maxIndex = 0

        let pointer = logits.dataPointer.assumingMemoryBound(to: Float.self)

        for i in 0..<vocabSize {
            let value = pointer[lastPositionOffset + i]
            if value > maxValue {
                maxValue = value
                maxIndex = i
            }
        }

        return maxIndex
    }

    /// Parse amount string (handles Argentine and US formats)
    private func parseAmount(_ amountStr: String?) -> Double? {
        guard var cleaned = amountStr else { return nil }

        // Remove currency symbols and whitespace
        cleaned = cleaned
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: "ARS", with: "")
            .replacingOccurrences(of: " ", with: "")
            .trimmingCharacters(in: .whitespaces)

        guard !cleaned.isEmpty else { return nil }

        // Detect format by checking decimal separator pattern
        // Argentine: 9.776,97 (period = thousands, comma = decimal)
        // US: 9,776.97 (comma = thousands, period = decimal)

        if cleaned.range(of: #",\d{1,2}$"#, options: .regularExpression) != nil {
            // Argentine format: comma is decimal separator
            cleaned = cleaned.replacingOccurrences(of: ".", with: "") // Remove thousand separators
            cleaned = cleaned.replacingOccurrences(of: ",", with: ".") // Convert decimal
        } else if cleaned.range(of: #"\.\d{1,2}$"#, options: .regularExpression) != nil {
            // US format: period is decimal separator
            cleaned = cleaned.replacingOccurrences(of: ",", with: "") // Remove thousand separators
        } else {
            // No clear decimal - remove all separators
            cleaned = cleaned
                .replacingOccurrences(of: ",", with: "")
                .replacingOccurrences(of: ".", with: "")
        }

        return Double(cleaned)
    }

    /// Parse date string
    private func parseDate(_ dateStr: String?) -> Date? {
        guard let dateStr = dateStr else { return nil }

        let formats = [
            "yyyy-MM-dd",
            "dd/MM/yyyy",
            "MM/dd/yyyy",
            "dd-MM-yyyy",
            "yyyy/MM/dd",
            "dd/MM/yy",
            "MM/dd/yy"
        ]

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_AR")

        for format in formats {
            formatter.dateFormat = format
            if let date = formatter.date(from: dateStr) {
                return date
            }
        }

        return nil
    }
}
