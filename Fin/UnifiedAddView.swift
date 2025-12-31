import SwiftUI
import SwiftData
import PhotosUI
import Vision
import PDFKit
import UniformTypeIdentifiers
import UIKit

struct UnifiedAddView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \Expense.date, order: .reverse) private var expenses: [Expense]
    @Query private var categories: [Category]

    // Form state
    @State private var amount: String = ""
    @State private var notes: String = ""
    @State private var selectedFormCategory: Category?
    @FocusState private var amountFocused: Bool
    @FocusState private var notesFocused: Bool

    // Filter state
    @State private var selectedFilterCategory: Category?
    @State private var selectedMonth: Date = Date()

    // Attachment state
    @State private var pendingImage: UIImage?
    @State private var pendingPDFData: Data?
    @State private var isProcessingOCR = false

    // Sheet triggers
    @State private var showingCamera = false
    @State private var showingPDFPicker = false
    @State private var selectedPhotoItem: PhotosPickerItem?

    var availableMonths: [Date] {
        let calendar = Calendar.current
        var months: Set<DateComponents> = []
        for expense in expenses {
            let components = calendar.dateComponents([.year, .month], from: expense.date)
            months.insert(components)
        }
        // Add current month if not present
        let currentComponents = calendar.dateComponents([.year, .month], from: Date())
        months.insert(currentComponents)

        return months.compactMap { calendar.date(from: $0) }
            .sorted(by: >)
    }

    var filteredExpenses: [Expense] {
        let calendar = Calendar.current
        return expenses.filter {
            calendar.isDate($0.date, equalTo: selectedMonth, toGranularity: .month)
        }
    }

    var totalSpending: Double {
        filteredExpenses.reduce(0) { $0 + $1.amount }
    }

    var spendingByCategory: [(Category, Double)] {
        var result: [Category: Double] = [:]
        for expense in filteredExpenses {
            if let category = expense.category {
                result[category, default: 0] += expense.amount
            }
        }
        return result.sorted { $0.value > $1.value }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerView
            treemapSection
            Spacer(minLength: 12)
            expenseForm
        }
        .background(Color(.systemGroupedBackground))
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .sheet(isPresented: $showingCamera) {
            CameraCaptureSheet { image in
                handleCapturedImage(image)
            }
        }
        .sheet(isPresented: $showingPDFPicker) {
            DocumentPicker(pdfData: $pendingPDFData)
        }
        .sheet(item: $selectedFilterCategory) { category in
            CategoryExpensesSheet(category: category, expenses: expenses.filter { $0.category?.persistentModelID == category.persistentModelID })
        }
        .onChange(of: selectedPhotoItem) { _, newValue in
            Task {
                if let data = try? await newValue?.loadTransferable(type: Data.self),
                   let image = UIImage(data: data) {
                    handleCapturedImage(image)
                }
            }
        }
        .onChange(of: pendingPDFData) { _, newValue in
            if let data = newValue {
                handleCapturedPDF(data)
            }
        }
        .onAppear {
            amountFocused = true
        }
    }

    // MARK: - View Components

    private var headerView: some View {
        HStack(spacing: 0) {
            Text(totalSpending.currencyFormattedCompact)
                .font(.system(size: 26, weight: .bold))

            Text(" en ")
                .font(.system(size: 26, weight: .light))
                .foregroundStyle(.secondary)

            monthPicker
        }
        .padding(.leading, 16)
        .padding(.top, 8)
    }

    private var monthPicker: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(availableMonths, id: \.self) { month in
                        monthButton(for: month, proxy: proxy)
                            .id(month)
                    }
                }
                .padding(.trailing, UIScreen.main.bounds.width * 0.5)
            }
            .coordinateSpace(name: "monthScroll")
            .onPreferenceChange(MonthOffsetKey.self) { offsets in
                updateSelectedMonth(from: offsets)
            }
        }
    }

    private func monthButton(for month: Date, proxy: ScrollViewProxy) -> some View {
        let calendar = Calendar.current
        let isSelected = calendar.isDate(selectedMonth, equalTo: month, toGranularity: .month)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "es_AR")
        formatter.dateFormat = "MMMM"
        let monthName = formatter.string(from: month).capitalized

        return Text(monthName)
            .font(.system(size: 20, weight: isSelected ? .medium : .light))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation {
                    proxy.scrollTo(month, anchor: .leading)
                }
                selectedMonth = month
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            .background(
                GeometryReader { geo in
                    Color.clear
                        .preference(
                            key: MonthOffsetKey.self,
                            value: [month: geo.frame(in: .named("monthScroll")).midX]
                        )
                }
            )
    }

    private func updateSelectedMonth(from offsets: [Date: CGFloat]) {
        let focalPoint: CGFloat = 60 // roughly where "en" ends
        var closestMonth: Date?
        var closestDistance: CGFloat = .infinity

        for (month, midX) in offsets {
            let distance = abs(midX - focalPoint)
            if distance < closestDistance {
                closestMonth = month
                closestDistance = distance
            }
        }

        let calendar = Calendar.current
        if let closestMonth = closestMonth,
           !calendar.isDate(selectedMonth, equalTo: closestMonth, toGranularity: .month) {
            selectedMonth = closestMonth
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private var treemapSection: some View {
        TreemapView(
            data: spendingByCategory,
            selectedCategory: nil,
            onCategoryTap: { category in
                selectedFilterCategory = category
            }
        )
        .padding(.horizontal)
        .padding(.top, 8)
        .animation(nil, value: selectedFilterCategory)
    }

    private var expenseForm: some View {
        VStack(spacing: 16) {
            receiptIndicator
            inlineFormRow
            notesField
            captureButtonsRow
        }
        .padding(.vertical)
    }

    @ViewBuilder
    private var receiptIndicator: some View {
        if pendingImage != nil {
            HStack(spacing: 8) {
                if isProcessingOCR {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("Analizando recibo...")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(.secondary)
                    Text("Recibo adjunto")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button {
                        pendingImage = nil
                        pendingPDFData = nil
                    } label: {
                        Image(systemName: "xmark")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private var inlineFormRow: some View {
        HStack(spacing: 0) {
            Text("$")
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.primary)

            TextField("0", text: $amount)
                .font(.system(size: 24, weight: .medium))
                .keyboardType(.decimalPad)
                .focused($amountFocused)
                .fixedSize()
                .frame(minWidth: 40)
                .onChange(of: amount) { _, newValue in
                    // Strip leading zeros (except for "0." or "0," decimal input)
                    let stripped = newValue.replacingOccurrences(of: "^0+(?=[1-9])", with: "", options: .regularExpression)
                    if stripped != newValue {
                        amount = stripped
                    }
                }

            Text(" en ")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.secondary)

            categoryPicker
        }
        .padding(.leading, 16)
    }

    private var categoryPicker: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 16) {
                    ForEach(categories) { category in
                        categoryButton(for: category, proxy: proxy)
                            .id(category.persistentModelID)
                    }
                }
                .padding(.trailing, UIScreen.main.bounds.width * 0.5)
            }
            .coordinateSpace(name: "categoryScroll")
            .onPreferenceChange(CategoryOffsetKey.self) { offsets in
                updateSelectedCategory(from: offsets)
            }
        }
    }

    private func categoryButton(for category: Category, proxy: ScrollViewProxy) -> some View {
        let isSelected = selectedFormCategory?.persistentModelID == category.persistentModelID
        return Text(category.name)
            .font(.system(size: 24, weight: isSelected ? .medium : .light))
            .foregroundStyle(isSelected ? .primary : .secondary)
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation {
                    proxy.scrollTo(category.persistentModelID, anchor: .leading)
                }
                selectedFormCategory = category
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            }
            .background(
                GeometryReader { geo in
                    Color.clear
                        .preference(
                            key: CategoryOffsetKey.self,
                            value: [category.persistentModelID: geo.frame(in: .named("categoryScroll")).midX]
                        )
                }
            )
    }

    private func updateSelectedCategory(from offsets: [PersistentIdentifier: CGFloat]) {
        let focalPoint: CGFloat = 60
        var closestId: PersistentIdentifier?
        var closestDistance: CGFloat = .infinity

        for (id, midX) in offsets {
            let distance = abs(midX - focalPoint)
            if distance < closestDistance {
                closestId = id
                closestDistance = distance
            }
        }

        if let closestId = closestId,
           let category = categories.first(where: { $0.persistentModelID == closestId }),
           selectedFormCategory?.persistentModelID != closestId {
            selectedFormCategory = category
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }

    private var notesField: some View {
        TextField("Nota (opcional)", text: $notes)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .focused($notesFocused)
            .padding(.horizontal, 16)
    }

    private var captureButtonsRow: some View {
        HStack(spacing: 24) {
            Button {
                showingCamera = true
            } label: {
                Image(systemName: "camera")
                    .font(.system(size: 18))
                    .foregroundStyle(.primary)
            }

            PhotosPicker(selection: $selectedPhotoItem, matching: .images) {
                Image(systemName: "photo")
                    .font(.system(size: 18))
                    .foregroundStyle(.primary)
            }

            Button {
                showingPDFPicker = true
            } label: {
                Image(systemName: "doc")
                    .font(.system(size: 18))
                    .foregroundStyle(.primary)
            }

            Spacer()

            Button {
                saveExpense()
            } label: {
                Text("Guardar")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(isValid ? .primary : .secondary)
            }
            .disabled(!isValid)
        }
        .padding(.horizontal, 16)
    }

    // MARK: - Validation

    private var isValid: Bool {
        guard let parsed = parseAmount(amount), parsed > 0 else { return false }
        return selectedFormCategory != nil
    }

    private func parseAmount(_ string: String) -> Double? {
        let cleaned = string.replacingOccurrences(of: ",", with: ".")
        return Double(cleaned)
    }

    private func handleCapturedImage(_ image: UIImage) {
        pendingImage = image
        pendingPDFData = nil

        // Run OCR in background
        Task {
            isProcessingOCR = true
            await processImageOCR(image)
            isProcessingOCR = false
        }
    }

    private func handleCapturedPDF(_ data: Data) {
        pendingPDFData = data

        // Generate preview and run OCR
        Task {
            isProcessingOCR = true
            await processPDF(data)
            isProcessingOCR = false
        }
    }

    private func processImageOCR(_ image: UIImage) async {
        // Scale down large images to avoid timeout
        let scaledImage = scaleImageForOCR(image)
        guard let cgImage = scaledImage.cgImage else { return }

        // Run Vision OCR for fallback text
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.recognitionLanguages = ["es", "en"]
        request.usesLanguageCorrection = true

        let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        var ocrText = ""
        do {
            try handler.perform([request])
            if let observations = request.results {
                ocrText = observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
            }
        } catch {
            print("[OCR] Failed: \(error)")
        }

        print("[OCR] Extracted text (\(ocrText.count) chars):")
        print(ocrText.prefix(500))

        // Use unified parser with Donut + fallback
        let parsed = await ReceiptParser.parse(
            image: scaledImage,
            text: ocrText,
            categories: categories
        )

        await MainActor.run {
            applyParsedReceipt(parsed)
        }
    }

    private func scaleImageForOCR(_ image: UIImage) -> UIImage {
        // First, fix orientation (important for camera captures)
        let fixedImage = fixImageOrientation(image)

        let maxDimension: CGFloat = 2000
        let size = fixedImage.size

        guard size.width > maxDimension || size.height > maxDimension else {
            return fixedImage
        }

        let scale = maxDimension / max(size.width, size.height)
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)

        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            fixedImage.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    private func fixImageOrientation(_ image: UIImage) -> UIImage {
        guard image.imageOrientation != .up else { return image }

        UIGraphicsBeginImageContextWithOptions(image.size, false, image.scale)
        image.draw(in: CGRect(origin: .zero, size: image.size))
        let normalizedImage = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()

        return normalizedImage ?? image
    }

    private func processPDF(_ data: Data) async {
        guard let pdfDocument = PDFDocument(data: data) else { return }

        // Generate preview from first page
        if let page = pdfDocument.page(at: 0) {
            let pageRect = page.bounds(for: .mediaBox)
            let scale: CGFloat = 2.0
            let size = CGSize(width: pageRect.width * scale, height: pageRect.height * scale)

            let renderer = UIGraphicsImageRenderer(size: size)
            let previewImage = renderer.image { ctx in
                UIColor.white.setFill()
                ctx.fill(CGRect(origin: .zero, size: size))

                ctx.cgContext.translateBy(x: 0, y: size.height)
                ctx.cgContext.scaleBy(x: scale, y: -scale)

                page.draw(with: .mediaBox, to: ctx.cgContext)
            }

            await MainActor.run {
                pendingImage = previewImage
            }
        }

        // Extract text from pages
        var fullText = ""
        for i in 0..<min(pdfDocument.pageCount, 3) {
            if let page = pdfDocument.page(at: i), let pageContent = page.string {
                fullText += pageContent + "\n"
            }
        }

        // If no text, try OCR on preview
        if fullText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let previewImage = pendingImage {
                await processImageOCR(previewImage)
                return
            }
        }

        // Use unified parser with Donut + fallback
        let parsed = await ReceiptParser.parse(
            image: pendingImage,
            text: fullText,
            categories: categories
        )

        await MainActor.run {
            applyParsedReceipt(parsed)
        }
    }

    private func applyParsedReceipt(_ parsed: ParsedReceipt) {
        // Only fill empty fields to preserve user edits
        if amount.isEmpty, let parsedAmount = parsed.amount {
            amount = String(format: "%.2f", parsedAmount).replacingOccurrences(of: ".", with: ",")
        }

        if notes.isEmpty, let merchant = parsed.merchant {
            notes = merchant
        }

        if selectedFormCategory == nil {
            if let suggestedCategory = parsed.suggestedCategory {
                selectedFormCategory = suggestedCategory
            } else {
                selectedFormCategory = categories.first { $0.name == "Otros" }
            }
        }
    }

    private func saveExpense() {
        guard let parsedAmount = parseAmount(amount), let category = selectedFormCategory else { return }

        var imageData: Data?
        if let image = pendingImage {
            imageData = image.jpegData(compressionQuality: 0.7)
        }

        let expense = Expense(
            amount: parsedAmount,
            merchant: nil,
            category: category,
            date: Date(),
            notes: notes.isEmpty ? nil : notes,
            imageData: imageData
        )

        modelContext.insert(expense)

        // Reset form
        amount = ""
        notes = ""
        selectedFormCategory = nil
        pendingImage = nil
        pendingPDFData = nil
        amountFocused = false
    }
}

// Category expenses sheet
struct CategoryExpensesSheet: View {
    let category: Category
    let expenses: [Expense]
    @Environment(\.dismiss) private var dismiss

    var totalForCategory: Double {
        expenses.reduce(0) { $0 + $1.amount }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(expenses) { expense in
                    ExpenseRow(expense: expense)
                }
            }
            .listStyle(.plain)
            .navigationTitle(category.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Cerrar") {
                        dismiss()
                    }
                }
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 0) {
                        HStack(spacing: 6) {
                            Image(systemName: category.icon)
                                .font(.subheadline)
                            Text(category.name)
                                .font(.headline)
                        }
                        Text(totalForCategory.currencyFormatted)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

// ExpenseRow moved here since it's shared
struct ExpenseRow: View {
    let expense: Expense
    @Environment(\.modelContext) private var modelContext

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: expense.category?.icon ?? "shippingbox.fill")
                .font(.title2)
                .foregroundStyle(expense.category?.color ?? .secondary)

            VStack(alignment: .leading, spacing: 2) {
                Text(expense.merchant ?? expense.notes ?? expense.category?.name ?? "Gasto")
                    .font(.body)
                    .lineLimit(1)

                Text(expense.date.shortFormatted)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Text(expense.amount.currencyFormatted)
                .font(.body)
                .fontWeight(.medium)
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(role: .destructive) {
                modelContext.delete(expense)
            } label: {
                Label("Eliminar", systemImage: "trash")
            }
        }
    }
}

// PreferenceKey for tracking category scroll positions
struct CategoryOffsetKey: PreferenceKey {
    static var defaultValue: [PersistentIdentifier: CGFloat] = [:]
    static func reduce(value: inout [PersistentIdentifier: CGFloat], nextValue: () -> [PersistentIdentifier: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

// PreferenceKey for tracking month scroll positions
struct MonthOffsetKey: PreferenceKey {
    static var defaultValue: [Date: CGFloat] = [:]
    static func reduce(value: inout [Date: CGFloat], nextValue: () -> [Date: CGFloat]) {
        value.merge(nextValue()) { $1 }
    }
}

#Preview {
    UnifiedAddView()
        .modelContainer(for: [Expense.self, Category.self], inMemory: true)
}
