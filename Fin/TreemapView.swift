import SwiftUI

struct TreemapView: View {
    let data: [(Category, Double)]
    var selectedCategory: Category?
    var onCategoryTap: ((Category?) -> Void)?

    @State private var cachedSize: CGSize = .zero
    @State private var cachedRects: [(category: Category, amount: Double, rect: CGRect)] = []

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .topLeading) {
                if cachedRects.isEmpty && data.isEmpty {
                    emptyState
                } else {
                    ForEach(cachedRects, id: \.category.name) { item in
                        TreemapCell(
                            category: item.category,
                            amount: item.amount,
                            rect: item.rect,
                            isSelected: selectedCategory?.persistentModelID == item.category.persistentModelID,
                            onTap: {
                                if selectedCategory?.persistentModelID == item.category.persistentModelID {
                                    onCategoryTap?(nil)
                                } else {
                                    onCategoryTap?(item.category)
                                }
                            }
                        )
                    }
                }
            }
            .onAppear {
                updateCache(size: geometry.size)
            }
            .onChange(of: geometry.size) { _, newSize in
                if abs(newSize.width - cachedSize.width) > 1 || abs(newSize.height - cachedSize.height) > 1 {
                    updateCache(size: newSize)
                }
            }
            .onChange(of: data.map { $0.1 }) { _, _ in
                updateCache(size: geometry.size)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private func updateCache(size: CGSize) {
        cachedSize = size
        cachedRects = calculateTreemap(
            data: data,
            bounds: CGRect(origin: .zero, size: size)
        )
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Text("Sin gastos")
                .font(.headline)
            Text("Agregá uno para empezar")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.secondarySystemGroupedBackground))
    }

    private func calculateTreemap(data: [(Category, Double)], bounds: CGRect) -> [(category: Category, amount: Double, rect: CGRect)] {
        guard !data.isEmpty else { return [] }

        let total = data.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return [] }

        var results: [(Category, Double, CGRect)] = []
        var remaining: [(Category, Double, Double)] = data.map { ($0.0, $0.1, $0.1 / total * Double(bounds.width * bounds.height)) }
        var currentBounds = bounds

        while !remaining.isEmpty {
            let isHorizontal = currentBounds.width >= currentBounds.height
            let side = Double(isHorizontal ? currentBounds.height : currentBounds.width)

            var row: [(Category, Double, Double)] = []
            var rowArea: Double = 0

            // Build row
            while !remaining.isEmpty {
                let item = remaining[0]
                let newRowArea = rowArea + item.2

                if row.isEmpty || worstRatio(row: row + [item], side: side, area: newRowArea) <= worstRatio(row: row, side: side, area: rowArea) {
                    row.append(remaining.removeFirst())
                    rowArea = newRowArea
                } else {
                    break
                }
            }

            // Layout row
            let rowWidth = rowArea / side
            var offset: Double = 0

            for item in row {
                let itemHeight = item.2 / rowWidth

                let rect: CGRect
                if isHorizontal {
                    rect = CGRect(
                        x: Double(currentBounds.minX),
                        y: Double(currentBounds.minY) + offset,
                        width: rowWidth,
                        height: itemHeight
                    )
                } else {
                    rect = CGRect(
                        x: Double(currentBounds.minX) + offset,
                        y: Double(currentBounds.minY),
                        width: itemHeight,
                        height: rowWidth
                    )
                }

                results.append((item.0, item.1, rect))
                offset += itemHeight
            }

            // Update bounds
            if isHorizontal {
                currentBounds.origin.x += CGFloat(rowWidth)
                currentBounds.size.width -= CGFloat(rowWidth)
            } else {
                currentBounds.origin.y += CGFloat(rowWidth)
                currentBounds.size.height -= CGFloat(rowWidth)
            }
        }

        return results
    }

    private func worstRatio(row: [(Category, Double, Double)], side: Double, area: Double) -> Double {
        guard !row.isEmpty, area > 0 else { return .infinity }

        let rowWidth = area / side
        var worst: Double = 0

        for item in row {
            let itemHeight = item.2 / rowWidth
            let ratio = max(rowWidth / itemHeight, itemHeight / rowWidth)
            worst = max(worst, ratio)
        }

        return worst
    }
}

struct TreemapCell: View {
    let category: Category
    let amount: Double
    let rect: CGRect
    var isSelected: Bool = false
    var onTap: (() -> Void)?

    private var showEmoji: Bool { rect.width > 40 && rect.height > 40 }
    private var showAmount: Bool { rect.width > 60 && rect.height > 60 }

    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .fill(category.color.opacity(isSelected ? 1.0 : 0.85))
            .frame(width: max(0, rect.width - 2), height: max(0, rect.height - 2))
            .overlay {
                if showEmoji {
                    VStack(spacing: 2) {
                        Text(category.emoji)
                            .font(.system(size: min(28, rect.width / 3)))

                        if showAmount {
                            Text(amount.currencyFormatted)
                                .font(.system(size: min(11, rect.width / 7), weight: .medium))
                                .foregroundStyle(contrastColor)
                                .opacity(0.9)
                        }
                    }
                }
            }
            .overlay {
                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(.white, lineWidth: 3)
                }
            }
            .offset(x: rect.minX + 1, y: rect.minY + 1)
            .onTapGesture {
                onTap?()
            }
    }

    private var contrastColor: Color {
        let hex = category.colorHex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var int: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&int)
        let r = Double((int >> 16) & 0xFF) / 255
        let g = Double((int >> 8) & 0xFF) / 255
        let b = Double(int & 0xFF) / 255
        let luminance = 0.299 * r + 0.587 * g + 0.114 * b
        return luminance > 0.5 ? .black : .white
    }
}

#Preview {
    TreemapView(data: [])
        .frame(height: 280)
        .padding()
}
