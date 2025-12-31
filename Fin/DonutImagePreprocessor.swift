import UIKit
import CoreML
import Accelerate

/// Preprocesses images for Donut model input
/// Handles resizing, normalization, and conversion to MLMultiArray
enum DonutImagePreprocessor {
    // Donut model input dimensions
    static let targetHeight = 960
    static let targetWidth = 720

    // ImageNet normalization values (used by Donut/Swin)
    private static let mean: [Float] = [0.485, 0.456, 0.406]
    private static let std: [Float] = [0.229, 0.224, 0.225]

    /// Preprocessing errors
    enum PreprocessingError: Error {
        case resizeFailed
        case cgImageConversionFailed
        case contextCreationFailed
        case multiArrayCreationFailed
    }

    /// Preprocesses UIImage to MLMultiArray for encoder input
    /// - Parameter image: Source image (receipt photo)
    /// - Returns: Normalized pixel values as MLMultiArray [1, 3, H, W]
    static func preprocess(_ image: UIImage) throws -> MLMultiArray {
        // 1. Resize image maintaining aspect ratio with white padding
        guard let resizedImage = resizeWithPadding(image) else {
            throw PreprocessingError.resizeFailed
        }

        // 2. Convert to CGImage
        guard let cgImage = resizedImage.cgImage else {
            throw PreprocessingError.cgImageConversionFailed
        }

        // 3. Extract pixel data
        let width = cgImage.width
        let height = cgImage.height
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width

        var pixelData = [UInt8](repeating: 0, count: width * height * bytesPerPixel)

        guard let context = CGContext(
            data: &pixelData,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else {
            throw PreprocessingError.contextCreationFailed
        }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 4. Create MLMultiArray [1, 3, H, W] in NCHW format
        let shape: [NSNumber] = [1, 3, NSNumber(value: targetHeight), NSNumber(value: targetWidth)]
        guard let pixelValues = try? MLMultiArray(shape: shape, dataType: .float32) else {
            throw PreprocessingError.multiArrayCreationFailed
        }

        // 5. Normalize and fill array
        // Use pointer for faster access
        let pointer = pixelValues.dataPointer.assumingMemoryBound(to: Float.self)

        let channelStride = targetWidth * targetHeight

        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = (y * width + x) * bytesPerPixel
                let spatialIndex = y * width + x

                // Extract RGB values and normalize to [0, 1]
                let r = Float(pixelData[pixelIndex]) / 255.0
                let g = Float(pixelData[pixelIndex + 1]) / 255.0
                let b = Float(pixelData[pixelIndex + 2]) / 255.0

                // Apply ImageNet normalization: (x - mean) / std
                pointer[spatialIndex] = (r - mean[0]) / std[0]                      // R channel
                pointer[channelStride + spatialIndex] = (g - mean[1]) / std[1]      // G channel
                pointer[2 * channelStride + spatialIndex] = (b - mean[2]) / std[2]  // B channel
            }
        }

        return pixelValues
    }

    /// Resizes image to target dimensions with white padding to maintain aspect ratio
    private static func resizeWithPadding(_ image: UIImage) -> UIImage? {
        let targetSize = CGSize(width: targetWidth, height: targetHeight)
        let imageSize = image.size

        // Calculate scale to fit within target while maintaining aspect ratio
        let widthRatio = targetSize.width / imageSize.width
        let heightRatio = targetSize.height / imageSize.height
        let scale = min(widthRatio, heightRatio)

        let scaledWidth = imageSize.width * scale
        let scaledHeight = imageSize.height * scale

        // Center the image with padding
        let xOffset = (targetSize.width - scaledWidth) / 2
        let yOffset = (targetSize.height - scaledHeight) / 2

        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { context in
            // White background (typical for receipts)
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: targetSize))

            // Draw scaled image centered
            image.draw(in: CGRect(x: xOffset, y: yOffset, width: scaledWidth, height: scaledHeight))
        }
    }

    /// Preprocesses using Accelerate framework for better performance (alternative implementation)
    static func preprocessWithAccelerate(_ image: UIImage) throws -> MLMultiArray {
        guard let resizedImage = resizeWithPadding(image),
              let cgImage = resizedImage.cgImage else {
            throw PreprocessingError.resizeFailed
        }

        // Create vImage buffer
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var format = vImage_CGImageFormat(
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            colorSpace: Unmanaged.passRetained(colorSpace),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            version: 0,
            decode: nil,
            renderingIntent: .defaultIntent
        )

        var sourceBuffer = vImage_Buffer()
        defer { sourceBuffer.data?.deallocate() }

        var error = vImageBuffer_InitWithCGImage(
            &sourceBuffer,
            &format,
            nil,
            cgImage,
            vImage_Flags(kvImageNoFlags)
        )

        guard error == kvImageNoError else {
            throw PreprocessingError.contextCreationFailed
        }

        // Create MLMultiArray
        let shape: [NSNumber] = [1, 3, NSNumber(value: targetHeight), NSNumber(value: targetWidth)]
        guard let pixelValues = try? MLMultiArray(shape: shape, dataType: .float32) else {
            throw PreprocessingError.multiArrayCreationFailed
        }

        let pointer = pixelValues.dataPointer.assumingMemoryBound(to: Float.self)
        let channelStride = targetWidth * targetHeight
        let pixelData = sourceBuffer.data.assumingMemoryBound(to: UInt8.self)

        // Process pixels
        for y in 0..<targetHeight {
            for x in 0..<targetWidth {
                let pixelIndex = (y * targetWidth + x) * 4
                let spatialIndex = y * targetWidth + x

                let r = Float(pixelData[pixelIndex]) / 255.0
                let g = Float(pixelData[pixelIndex + 1]) / 255.0
                let b = Float(pixelData[pixelIndex + 2]) / 255.0

                pointer[spatialIndex] = (r - mean[0]) / std[0]
                pointer[channelStride + spatialIndex] = (g - mean[1]) / std[1]
                pointer[2 * channelStride + spatialIndex] = (b - mean[2]) / std[2]
            }
        }

        return pixelValues
    }
}
