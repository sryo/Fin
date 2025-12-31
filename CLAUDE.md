# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Fin is an iOS expense tracking app (iOS 17+) written in Swift/SwiftUI. Users can add expenses manually or by scanning receipts with the camera. Expenses are visualized in a treemap grouped by category.

## Build Commands

```bash
# Build for simulator
xcodebuild -project Fin.xcodeproj -scheme Fin -destination 'platform=iOS Simulator,name=iPhone 15' build

# Build for device
xcodebuild -project Fin.xcodeproj -scheme Fin -destination 'generic/platform=iOS' build
```

Open `Fin.xcodeproj` in Xcode for development. The project has no external dependencies (SPM/CocoaPods).

## Architecture

### Data Layer (SwiftData)
- **Models.swift**: Core data models using SwiftData's `@Model` macro
  - `Expense`: amount, merchant, date, notes, imageData, category relationship
  - `Category`: name, icon (SF Symbol), colorHex, keywords for auto-categorization
- Default categories are seeded on first launch in `FinApp.swift`

### Receipt Processing Pipeline
The app uses a two-tier approach for receipt parsing:

1. **Primary: Donut ML Model** - Vision transformer for document understanding
   - `DonutInferenceService.swift`: Actor managing CoreML encoder-decoder models
   - `DonutImagePreprocessor.swift`: Resizes to 720x960, ImageNet normalization
   - `DonutTokenizer.swift`: BPE tokenizer parsing CORD XML output format
   - Models: `DonutEncoder.mlpackage`, `DonutDecoder.mlpackage`

2. **Fallback: Regex Parser** - When Donut fails or returns empty
   - `ReceiptParser.swift`: Extracts amounts, merchants, dates using regex patterns
   - Uses NaturalLanguage NER for merchant detection
   - `merchants.json`: Known merchant patterns for fast matching

### Views
- **UnifiedAddView.swift**: Main screen - treemap + expense form + capture buttons
- **TreemapView.swift**: Squarified treemap algorithm for category visualization
- **CameraCaptureSheet.swift**: AVFoundation camera + PDF document picker

### Key Patterns
- Locale is Argentine Spanish (`es_AR`) for currency/date formatting
- Categories use keyword matching for auto-suggestion (keywords stored comma-separated)
- Donut models preload on app launch in background task
- OCR uses Vision framework with `.fast` recognition level
- Image orientation is fixed before processing (camera captures)

## Receipt Parser Flow
```
Image captured → Vision OCR (fallback text) → Donut inference → Parse XML output
                                           ↓ (on failure)
                                    Regex extraction from OCR text
```

## File Resources
- `donut_vocab.json`, `donut_special_tokens.json`: Tokenizer vocabulary
- `merchants.json`: Known merchant regex patterns and display names

## Commit Style
- Short, concise messages (no verbose descriptions)
- No co-authorship or AI attribution

## Working Style
- Only do what was requested - don't add unrequested "improvements"
- Ask before making optimizations or additions, even if they seem obvious
