import CoreGraphics
import ImageIO
import UIKit
import Vision

enum QuestionSegmentationEngine {
    static func detectBestQuestion(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        focusRect: CGRect
    ) -> DetectedQuestionBlock? {
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        request.minimumTextHeight = 0.014

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        let lines = (request.results ?? []).compactMap { RecognizedLine(observation: $0) }
        guard !lines.isEmpty else {
            return nil
        }

        let candidates = deduplicate(buildSequentialClusters(from: lines) + buildAnchoredClusters(from: lines))
        let ranked = candidates
            .map { candidate in
                (candidate, candidate.score(relativeTo: focusRect))
            }
            .filter { entry in
                entry.0.characterCount >= 6
                    && entry.0.rect.width >= 0.16
                    && entry.0.rect.height >= 0.05
                    && entry.1 >= 18
            }
            .sorted { lhs, rhs in
                if abs(lhs.1 - rhs.1) > 0.001 {
                    return lhs.1 > rhs.1
                }
                return lhs.0.characterCount > rhs.0.characterCount
            }

        guard let best = ranked.first?.0 else {
            return nil
        }

        let text = normalize(best.text)
        guard !text.isEmpty else {
            return nil
        }

        let rect = expanded(best.rect, padding: 0.06)
        let questionNumber = QuestionIntentRecognizer.extractQuestionNumber(from: text)
        let confidence = min(0.98, max(0.42, (ranked.first?.1 ?? 0) / 100))

        return DetectedQuestionBlock(
            normalizedRect: rect,
            previewText: text,
            lineCount: best.lines.count,
            confidence: confidence,
            questionNumber: questionNumber,
            blockID: blockID(for: rect, text: text)
        )
    }

    static func cropQuestion(from image: UIImage, normalizedRect: CGRect, padding: CGFloat = 0.08) -> UIImage? {
        let normalizedImage = normalized(image)
        guard let cgImage = normalizedImage.cgImage else {
            return nil
        }

        let paddedRect = expanded(normalizedRect, padding: padding)
        let imageBounds = CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        let cropRect = CGRect(
            x: paddedRect.minX * imageBounds.width,
            y: (1 - paddedRect.maxY) * imageBounds.height,
            width: paddedRect.width * imageBounds.width,
            height: paddedRect.height * imageBounds.height
        )
        .integral
        .intersection(imageBounds)

        guard !cropRect.isNull,
              cropRect.width > 24,
              cropRect.height > 24,
              let cropped = cgImage.cropping(to: cropRect)
        else {
            return nil
        }

        return UIImage(cgImage: cropped, scale: normalizedImage.scale, orientation: .up)
    }

    private static func buildSequentialClusters(from lines: [RecognizedLine]) -> [QuestionCluster] {
        let sorted = sortLines(lines)
        guard let first = sorted.first else {
            return []
        }

        var clusters: [QuestionCluster] = []
        var current = QuestionCluster(lines: [first])

        for line in sorted.dropFirst() {
            if current.canAppend(line) {
                current.lines.append(line)
            } else {
                clusters.append(current)
                current = QuestionCluster(lines: [line])
            }
        }

        clusters.append(current)
        return clusters
    }

    private static func buildAnchoredClusters(from lines: [RecognizedLine]) -> [QuestionCluster] {
        let sorted = sortLines(lines)
        var clusters: [QuestionCluster] = []

        for (index, line) in sorted.enumerated() where line.isQuestionAnchor || line.hasProblemSignal {
            var selection = [line]
            var last = line
            var cursor = index + 1

            while cursor < sorted.count && selection.count < 6 {
                let candidate = sorted[cursor]
                let gap = max(0, last.rect.minY - candidate.rect.maxY)
                if gap > max(0.08, last.rect.height * 2.6) {
                    break
                }

                if candidate.isQuestionAnchor && !selection.isEmpty {
                    break
                }

                selection.append(candidate)
                last = candidate
                cursor += 1
            }

            clusters.append(QuestionCluster(lines: selection))
        }

        return clusters
    }

    private static func sortLines(_ lines: [RecognizedLine]) -> [RecognizedLine] {
        lines.sorted { lhs, rhs in
            if abs(lhs.rect.midY - rhs.rect.midY) > 0.001 {
                return lhs.rect.midY > rhs.rect.midY
            }
            return lhs.rect.minX < rhs.rect.minX
        }
    }

    private static func deduplicate(_ clusters: [QuestionCluster]) -> [QuestionCluster] {
        var seen = Set<String>()
        var unique: [QuestionCluster] = []

        for cluster in clusters {
            let rect = cluster.rect
            let key = [
                Int((rect.minX * 1000).rounded()),
                Int((rect.minY * 1000).rounded()),
                Int((rect.width * 1000).rounded()),
                Int((rect.height * 1000).rounded())
            ]
            .map(String.init)
            .joined(separator: ":")

            if seen.insert(key).inserted {
                unique.append(cluster)
            }
        }

        return unique
    }

    private static func expanded(_ rect: CGRect, padding: CGFloat) -> CGRect {
        let dx = max(0.02, rect.width * padding)
        let dy = max(0.02, rect.height * padding)
        return rect.insetBy(dx: -dx, dy: -dy).clampedToUnitRect()
    }

    private static func normalize(_ text: String) -> String {
        text
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }

    private static func blockID(for rect: CGRect, text: String) -> String {
        let rectKey = [
            Int((rect.midX * 18).rounded()),
            Int((rect.midY * 18).rounded()),
            Int((rect.width * 18).rounded()),
            Int((rect.height * 18).rounded())
        ]
        .map(String.init)
        .joined(separator: ":")

        return "\(rectKey)|\(normalize(text).prefix(24))"
    }

    private static func normalized(_ image: UIImage) -> UIImage {
        if image.imageOrientation == .up {
            return resized(image, maxDimension: 2400)
        }

        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: image.size, format: format)
        let rendered = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: image.size))
        }
        return resized(rendered, maxDimension: 2400)
    }

    private static func resized(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
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
}

private struct RecognizedLine {
    let text: String
    let rect: CGRect
    let confidence: Float

    init?(observation: VNRecognizedTextObservation) {
        guard let candidate = observation.topCandidates(1).first else {
            return nil
        }

        let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let rect = observation.boundingBox.standardized

        guard !text.isEmpty,
              rect.width > 0.04,
              rect.height > 0.012
        else {
            return nil
        }

        self.text = text
        self.rect = rect
        self.confidence = candidate.confidence
    }

    var compactText: String {
        text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }

    var characterCount: Int {
        compactText.count
    }

    var isQuestionAnchor: Bool {
        matches(#"^\s*[（(]?\d{1,3}[）)]?\s*[\.、．]?"#)
    }

    var hasProblemSignal: Bool {
        matches(#"[0-9+\-×÷=]"#) || matches(#"(计算|求|解|填空|阅读|choose|translate)"#)
    }

    func matches(_ pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}

private struct QuestionCluster {
    var lines: [RecognizedLine]

    var rect: CGRect {
        lines.dropFirst().reduce(lines[0].rect) { partial, line in
            partial.union(line.rect)
        }
    }

    var text: String {
        lines.map(\.text).joined(separator: "\n")
    }

    var characterCount: Int {
        lines.map(\.characterCount).reduce(0, +)
    }

    var averageHeight: CGFloat {
        lines.map(\.rect.height).reduce(0, +) / CGFloat(max(lines.count, 1))
    }

    var averageConfidence: Double {
        Double(lines.map(\.confidence).reduce(0, +)) / Double(max(lines.count, 1))
    }

    func score(relativeTo focusRect: CGRect) -> Double {
        let area = rect.width * rect.height
        let anchorCount = lines.filter(\.isQuestionAnchor).count
        let overlap = rect.intersection(focusRect)
        let overlapArea = overlap.isNull ? 0 : overlap.width * overlap.height
        let focusArea = max(focusRect.width * focusRect.height, 0.001)
        let clusterArea = max(area, 0.001)
        let focusCoverage = overlapArea / focusArea
        let clusterFocusCoverage = overlapArea / clusterArea
        let centerDistance = hypot(rect.midX - focusRect.midX, rect.midY - focusRect.midY)
        let operatorCount = regexMatches(#"[+\-×÷=]"#, in: text)
        let linePenalty = max(0, lines.count - 6) * 8
        let oversizedPenalty = max(0, area - 0.40) * 180
        let multiAnchorPenalty = max(0, anchorCount - 1) * 18

        return Double(characterCount)
            + Double(lines.count * 18)
            + Double(anchorCount * 24)
            + Double(operatorCount * 3)
            + averageConfidence * 28
            + focusCoverage * 140
            + clusterFocusCoverage * 40
            + max(0, 1 - Double(centerDistance) * 3.2) * 18
            - Double(linePenalty)
            - Double(multiAnchorPenalty)
            - oversizedPenalty
    }

    func canAppend(_ line: RecognizedLine) -> Bool {
        guard let last = lines.last else {
            return true
        }

        if line.isQuestionAnchor {
            return false
        }

        let gap = max(0, last.rect.minY - line.rect.maxY)
        let overlap = rect.intersection(line.rect)
        let overlapWidth = overlap.isNull ? 0 : overlap.width
        let horizontalOverlap = overlapWidth / max(min(rect.width, line.rect.width), 0.001)
        let centerDistance = abs(rect.midX - line.rect.midX)

        return gap <= max(0.06, averageHeight * 2.1)
            && (horizontalOverlap > 0.1 || centerDistance < 0.26)
    }

    private func regexMatches(_ pattern: String, in text: String) -> Int {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return 0
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.numberOfMatches(in: text, range: range)
    }
}

private extension CGRect {
    func clampedToUnitRect() -> CGRect {
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        return intersection(unit)
    }
}
