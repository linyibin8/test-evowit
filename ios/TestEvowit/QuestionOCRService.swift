import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Vision

enum QuestionOCRService {
    private static let ciContext = CIContext(options: nil)

    static func recognizeQuestion(in image: UIImage) -> QuestionOCRResult {
        let normalized = normalizedImage(from: image)
        let candidates = preprocessCandidates(for: normalized)
        var bestText = ""
        var bestLineCount = 0
        var bestProfile = "original"
        var bestScore = Int.min

        for candidate in candidates {
            let result = recognizeText(in: candidate.image)
            let score = score(text: result.text, lineCount: result.lineCount)
            if score > bestScore {
                bestScore = score
                bestText = result.text
                bestLineCount = result.lineCount
                bestProfile = candidate.profile
            }
        }

        let quality = assessQuality(text: bestText, lineCount: bestLineCount)
        return QuestionOCRResult(
            text: bestText,
            lineCount: bestLineCount,
            quality: quality,
            preprocessProfile: bestProfile
        )
    }

    private static func recognizeText(in image: UIImage) -> (text: String, lineCount: Int) {
        guard let cgImage = image.cgImage else {
            return ("", 0)
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.012

        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return ("", 0)
        }

        let lines = (request.results ?? [])
            .compactMap { $0.topCandidates(1).first?.string }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        return (lines.joined(separator: "\n"), lines.count)
    }

    private static func preprocessCandidates(for image: UIImage) -> [(profile: String, image: UIImage)] {
        var candidates: [(String, UIImage)] = [("original", image)]
        if let contrast = contrastImage(from: image) {
            candidates.append(("contrast", contrast))
        }
        return candidates
    }

    private static func contrastImage(from image: UIImage) -> UIImage? {
        guard let ciImage = CIImage(image: image) else {
            return nil
        }

        let controls = CIFilter.colorControls()
        controls.inputImage = ciImage
        controls.saturation = 0
        controls.contrast = 1.25
        controls.brightness = 0.04

        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = controls.outputImage
        exposure.ev = 0.22

        guard let output = exposure.outputImage?.cropped(to: ciImage.extent),
              let cgImage = ciContext.createCGImage(output, from: output.extent)
        else {
            return nil
        }

        return UIImage(cgImage: cgImage)
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

    private static func score(text: String, lineCount: Int) -> Int {
        let compact = compactText(text)
        let chineseCount = regexMatches(#"[\p{Han}]"#, in: text)
        let digitCount = regexMatches(#"[0-9]"#, in: text)
        let choiceCount = regexMatches(#"(?m)^\s*[A-D][\.．、:：)]"#, in: text)
        let questionCount = regexMatches(#"(?m)^\s*[（(]?\s*\d{1,3}\s*[）)]?\s*[\.、．]?"#, in: text)
        let noisePenalty = compact.filter { "锟亂口囗".contains($0) }.count * 10
        let multiQuestionPenalty = max(0, lineCount - 8) * 6 + max(0, questionCount - 1) * 18

        return compact.count * 3
            + chineseCount * 2
            + digitCount * 2
            + choiceCount * 6
            - noisePenalty
            - multiQuestionPenalty
    }

    private static func assessQuality(text: String, lineCount: Int) -> QuestionOCRQuality {
        let compact = compactText(text)
        let questionCount = regexMatches(#"(?m)^\s*[（(]?\s*\d{1,3}\s*[）)]?\s*[\.、．]?"#, in: text)
        let noiseCount = compact.filter { "锟亂口囗".contains($0) }.count
        let noiseRatio = compact.isEmpty ? 1 : Double(noiseCount) / Double(max(compact.count, 1))

        if compact.count < 10 || noiseRatio > 0.14 {
            return .weak
        }

        if questionCount >= 2 || lineCount >= 9 {
            return .needsCrop
        }

        return .good
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
