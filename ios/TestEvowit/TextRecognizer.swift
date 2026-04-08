import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision

enum OCRQualityLevel: String {
    case good
    case needsCrop
    case poor
}

struct TextRecognitionResult {
    let text: String
    let durationMs: Int
    let lineCount: Int
    let qualityLevel: OCRQualityLevel
    let qualityMessage: String
    let preprocessProfile: String
}

enum TextRecognizer {
    private static let ciContext = CIContext(options: nil)

    static func recognizeText(in image: UIImage) async -> TextRecognitionResult {
        let startedAt = Date()
        let normalized = normalizedImage(from: image)
        let candidates = buildCandidates(from: normalized)
        var bestResult = OCRPassResult.empty

        for candidate in candidates {
            let pass = await performRecognition(on: candidate.image)
            let scored = OCRPassResult(
                text: pass.text,
                lineCount: pass.lineCount,
                score: scoreText(pass.text, lineCount: pass.lineCount),
                preprocessProfile: candidate.profile
            )

            if scored.score > bestResult.score {
                bestResult = scored
            }
        }

        let durationMs = Int(Date().timeIntervalSince(startedAt) * 1000)
        let assessment = assessQuality(text: bestResult.text, lineCount: bestResult.lineCount)

        return TextRecognitionResult(
            text: bestResult.text,
            durationMs: durationMs,
            lineCount: bestResult.lineCount,
            qualityLevel: assessment.level,
            qualityMessage: assessment.message,
            preprocessProfile: bestResult.preprocessProfile
        )
    }

    private static func performRecognition(on image: UIImage) async -> (text: String, lineCount: Int) {
        guard let cgImage = image.cgImage else {
            return ("", 0)
        }

        return await withCheckedContinuation { continuation in
            let request = VNRecognizeTextRequest { request, _ in
                let strings = (request.results as? [VNRecognizedTextObservation])?
                    .compactMap { $0.topCandidates(1).first?.string }
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty } ?? []

                continuation.resume(returning: (strings.joined(separator: "\n"), strings.count))
            }

            request.recognitionLanguages = ["zh-Hans", "en-US"]
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            request.minimumTextHeight = 0.014

            let handler = VNImageRequestHandler(cgImage: cgImage, options: [:])
            do {
                try handler.perform([request])
            } catch {
                continuation.resume(returning: ("", 0))
            }
        }
    }

    private static func buildCandidates(from image: UIImage) -> [(profile: String, image: UIImage)] {
        var items: [(String, UIImage)] = []
        if let enhanced = enhancedImage(from: image) {
            items.append(("grayscale-contrast", enhanced))
        }
        items.append(("original", resizedImage(image, maxDimension: 2400)))
        return items
    }

    private static func normalizedImage(from image: UIImage) -> UIImage {
        if image.imageOrientation == .up {
            return resizedImage(image, maxDimension: 2400)
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return resizedImage(rendered, maxDimension: 2400)
    }

    private static func resizedImage(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let longest = max(image.size.width, image.size.height)
        guard longest > maxDimension, longest > 0 else {
            return image
        }

        let scale = maxDimension / longest
        let targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)

        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private static func enhancedImage(from image: UIImage) -> UIImage? {
        guard let ciImage = CIImage(image: image) else {
            return nil
        }

        let controls = CIFilter.colorControls()
        controls.inputImage = ciImage
        controls.saturation = 0
        controls.contrast = 1.18
        controls.brightness = 0.03

        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = controls.outputImage
        exposure.ev = 0.25

        guard let output = exposure.outputImage?.cropped(to: ciImage.extent),
              let cgImage = ciContext.createCGImage(output, from: output.extent)
        else {
            return nil
        }

        return resizedImage(UIImage(cgImage: cgImage), maxDimension: 2400)
    }

    private static func scoreText(_ text: String, lineCount: Int) -> Int {
        let compact = compactText(text)
        let chineseCount = regexMatches("[\\u4e00-\\u9fff]", in: text)
        let digitCount = regexMatches("[0-9]", in: text)
        let numberedQuestionCount = regexMatches("(?:^|\\n)\\s*\\d+[.)、．]", in: text)
        let suspiciousCount = compact.filter { "�□".contains($0) }.count
        let suspiciousPenalty = compact.isEmpty ? 60 : Int((Double(suspiciousCount) / Double(compact.count)) * 100)
        let shortLineCount = text
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .filter { $0.count <= 4 }
            .count
        let shortLinePenalty = shortLineCount * 6
        let worksheetPenalty = max(0, lineCount - 8) * 7 + max(0, numberedQuestionCount - 1) * 18

        return compact.count * 3 + chineseCount * 2 + digitCount * 2 - suspiciousPenalty - shortLinePenalty - worksheetPenalty
    }

    private static func assessQuality(text: String, lineCount: Int) -> (level: OCRQualityLevel, message: String) {
        let compact = compactText(text)
        let numberedQuestionCount = regexMatches("(?:^|\\n)\\s*\\d+[.)、．]", in: text)
        let suspiciousCount = compact.filter { "�□".contains($0) }.count
        let suspiciousRatio = compact.isEmpty ? 1 : Double(suspiciousCount) / Double(compact.count)

        if compact.count < 8 {
            return (.poor, "识别到的题干太少，建议拍近一点，或者先裁剪到单题再继续。")
        }

        if lineCount >= 9 || numberedQuestionCount >= 2 {
            return (.needsCrop, "当前更像整页作业，建议先裁剪到单题，再提交给大模型。")
        }

        if suspiciousRatio >= 0.12 {
            return (.poor, "题干里噪声较多，建议重新拍清楚一点，或手动补充题干。")
        }

        return (.good, "已识别到较完整的单题题干，可以继续解析。")
    }

    private static func compactText(_ text: String) -> String {
        text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }

    private static func regexMatches(_ pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return 0
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, range: range)
    }
}

private struct OCRPassResult {
    let text: String
    let lineCount: Int
    let score: Int
    let preprocessProfile: String

    static let empty = OCRPassResult(text: "", lineCount: 0, score: Int.min, preprocessProfile: "original")
}
