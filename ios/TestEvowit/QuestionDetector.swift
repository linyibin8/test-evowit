import AVFoundation
import CoreGraphics
import ImageIO
import UIKit
import Vision

struct QuestionDetection {
    let normalizedRect: CGRect
    let confidence: Double
    let lineCount: Int
    let recognizedText: String
    let source: QuestionDetectionSource
    let coverage: Double?
}

enum QuestionDetector {
    static let suggestedFocusRect = CGRect(x: 0.12, y: 0.38, width: 0.76, height: 0.24)

    static func detectQuestion(
        in pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        focusRect: CGRect? = nil,
        recognitionLevel: VNRequestTextRecognitionLevel = .fast
    ) -> QuestionDetection? {
        let request = makeRequest(recognitionLevel: recognitionLevel)
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: orientation, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        let observations = request.results as? [VNRecognizedTextObservation] ?? []
        return bestDetection(from: observations, focusRect: focusRect)
    }

    static func detectQuestion(
        in image: UIImage,
        focusRect: CGRect? = nil,
        recognitionLevel: VNRequestTextRecognitionLevel = .accurate
    ) -> QuestionDetection? {
        let normalized = normalizedImage(from: image)
        guard let cgImage = normalized.cgImage else {
            return nil
        }

        let request = makeRequest(recognitionLevel: recognitionLevel)
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: .up, options: [:])

        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        let observations = request.results as? [VNRecognizedTextObservation] ?? []
        return bestDetection(from: observations, focusRect: focusRect)
    }

    static func cropQuestion(
        from image: UIImage,
        using detection: QuestionDetection,
        padding: CGFloat = 0.12
    ) -> UIImage? {
        cropQuestion(from: image, normalizedRect: detection.normalizedRect, padding: padding)
    }

    static func cropQuestion(
        from image: UIImage,
        normalizedRect: CGRect,
        padding: CGFloat = 0.06
    ) -> UIImage? {
        let normalized = normalizedImage(from: image)
        guard let cgImage = normalized.cgImage else {
            return nil
        }

        let padded = expandedRect(normalizedRect, padding: padding)
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(cgImage.width), height: CGFloat(cgImage.height))
        let cropRect = CGRect(
            x: padded.minX * bounds.width,
            y: (1 - padded.maxY) * bounds.height,
            width: padded.width * bounds.width,
            height: padded.height * bounds.height
        )
        .integral
        .intersection(bounds)

        guard !cropRect.isNull,
              cropRect.width > 20,
              cropRect.height > 20,
              let cropped = cgImage.cropping(to: cropRect)
        else {
            return nil
        }

        return UIImage(cgImage: cropped, scale: normalized.scale, orientation: .up)
    }

    static func detectQuestion(from response: ServerQuestionDetectionResponse) -> QuestionDetection? {
        guard let questionBox = response.questionBox else {
            return nil
        }

        let visionRect = CGRect(
            x: questionBox.normalized.x,
            y: 1 - questionBox.normalized.y - questionBox.normalized.height,
            width: questionBox.normalized.width,
            height: questionBox.normalized.height
        )
        .clampedToUnitRect()

        guard visionRect.width > 0.12, visionRect.height > 0.06 else {
            return nil
        }

        let source: QuestionDetectionSource = response.focusRect == nil ? .serverLayout : .serverFocusedLayout

        return QuestionDetection(
            normalizedRect: visionRect,
            confidence: min(0.99, max(0.48, questionBox.score / 150)),
            lineCount: max(1, questionBox.boxCount),
            recognizedText: questionBox.labels.joined(separator: " "),
            source: source,
            coverage: response.coverage
        )
    }

    static func toServerRect(_ visionRect: CGRect?) -> ServerNormalizedRect? {
        guard let rect = visionRect?.clampedToUnitRect(),
              rect.width > 0,
              rect.height > 0
        else {
            return nil
        }

        return ServerNormalizedRect(
            x: Double(rect.minX),
            y: Double(1 - rect.maxY),
            width: Double(rect.width),
            height: Double(rect.height)
        )
    }

    private static func makeRequest(
        recognitionLevel: VNRequestTextRecognitionLevel
    ) -> VNRecognizeTextRequest {
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["zh-Hans", "en-US"]
        request.recognitionLevel = recognitionLevel
        request.usesLanguageCorrection = false
        request.minimumTextHeight = recognitionLevel == .fast ? 0.014 : 0.01
        return request
    }

    private static func bestDetection(
        from observations: [VNRecognizedTextObservation],
        focusRect: CGRect?
    ) -> QuestionDetection? {
        let lines = observations.compactMap(makeLine(from:))
        guard !lines.isEmpty else {
            return nil
        }

        var candidates: [QuestionDetection] = []

        if let focusRect,
           let focused = detectCandidate(from: lines, focusRect: focusRect, preferFocus: true, source: .localGuideVision) {
            candidates.append(focused)
        }

        if let global = detectCandidate(from: lines, focusRect: focusRect, preferFocus: false, source: .localVision) {
            candidates.append(global)
        }

        return candidates.max(by: isWorse(_:than:))
    }

    private static func detectCandidate(
        from lines: [QuestionLine],
        focusRect: CGRect?,
        preferFocus: Bool,
        source: QuestionDetectionSource
    ) -> QuestionDetection? {
        let effectiveLines: [QuestionLine]
        if preferFocus, let focusRect {
            let expandedFocus = expandedRect(focusRect, padding: 0.08)
            effectiveLines = lines.filter { line in
                expandedFocus.intersects(line.rect) || expandedFocus.contains(line.rect.center)
            }
        } else {
            effectiveLines = lines
        }

        guard !effectiveLines.isEmpty else {
            return nil
        }

        let allCandidates = deduplicateCandidates(
            buildClusters(from: effectiveLines) + buildAnchoredClusters(from: effectiveLines)
        )

        let ranked = allCandidates
            .filter { candidate in
                candidate.characterCount >= (preferFocus ? 4 : 6)
                    && candidate.rect.width >= (preferFocus ? 0.14 : 0.18)
                    && candidate.rect.height >= 0.045
            }
            .map { candidate in
                (candidate, candidate.score(focusRect: focusRect, preferFocus: preferFocus))
            }
            .sorted { lhs, rhs in
                if abs(lhs.1 - rhs.1) > 0.001 {
                    return lhs.1 > rhs.1
                }
                return lhs.0.characterCount > rhs.0.characterCount
            }

        guard let best = ranked.first else {
            return nil
        }

        let minimumScore = preferFocus ? 18.0 : 15.0
        guard best.1 >= minimumScore else {
            return nil
        }

        if preferFocus, let focusRect {
            let expandedFocus = focusRect.insetBy(dx: -0.03, dy: -0.03)
            let bestCoverage = best.0.focusCoverage(with: focusRect)
            let centerInsideFocus = focusRect.contains(best.0.rect.center)
            let centerInsideExpandedFocus = expandedFocus.contains(best.0.rect.center)
            let hasStrongFocus = bestCoverage >= 0.1 || (centerInsideFocus && bestCoverage >= 0.06)

            guard hasStrongFocus || (centerInsideExpandedFocus && bestCoverage >= 0.08) else {
                return nil
            }

            if ranked.count > 1 {
                let runnerUp = ranked[1]
                let runnerCoverage = runnerUp.0.focusCoverage(with: focusRect)
                let runnerCenterInside = expandedFocus.contains(runnerUp.0.rect.center)
                let ambiguous = runnerCenterInside
                    && runnerCoverage >= max(0.08, bestCoverage * 0.78)
                    && abs(best.1 - runnerUp.1) < 10
                if ambiguous {
                    return nil
                }
            }
        }

        return QuestionDetection(
            normalizedRect: expandedRect(best.0.rect, padding: preferFocus ? 0.06 : 0.08),
            confidence: min(0.98, max(preferFocus ? 0.42 : 0.28, best.1 / 210)),
            lineCount: best.0.lines.count,
            recognizedText: best.0.text,
            source: source,
            coverage: nil
        )
    }

    private static func makeLine(from observation: VNRecognizedTextObservation) -> QuestionLine? {
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

        return QuestionLine(
            text: text,
            rect: rect,
            confidence: candidate.confidence
        )
    }

    private static func buildClusters(from lines: [QuestionLine]) -> [QuestionCluster] {
        let sorted = lines.sorted { lhs, rhs in
            if abs(lhs.rect.midY - rhs.rect.midY) > 0.001 {
                return lhs.rect.midY > rhs.rect.midY
            }
            return lhs.rect.minX < rhs.rect.minX
        }

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

    private static func buildAnchoredClusters(from lines: [QuestionLine]) -> [QuestionCluster] {
        let sorted = lines.sorted { lhs, rhs in
            if abs(lhs.rect.midY - rhs.rect.midY) > 0.001 {
                return lhs.rect.midY > rhs.rect.midY
            }
            return lhs.rect.minX < rhs.rect.minX
        }

        var clusters: [QuestionCluster] = []

        for (index, line) in sorted.enumerated() where line.isQuestionAnchor || line.hasMathSignal {
            var selected = [line]
            var previous = line
            var cursor = index + 1

            while cursor < sorted.count && selected.count < 6 {
                let candidate = sorted[cursor]
                let verticalGap = max(0, previous.rect.minY - candidate.rect.maxY)
                let gapThreshold = max(0.07, previous.rect.height * 2.8)

                if verticalGap > gapThreshold {
                    break
                }

                if candidate.isQuestionAnchor && !selected.isEmpty {
                    break
                }

                selected.append(candidate)
                previous = candidate
                cursor += 1
            }

            clusters.append(QuestionCluster(lines: selected))
        }

        return clusters
    }

    private static func deduplicateCandidates(_ candidates: [QuestionCluster]) -> [QuestionCluster] {
        var seen = Set<String>()
        var unique: [QuestionCluster] = []

        for candidate in candidates {
            let rect = candidate.rect
            let key = [
                Int((rect.minX * 1000).rounded()),
                Int((rect.minY * 1000).rounded()),
                Int((rect.width * 1000).rounded()),
                Int((rect.height * 1000).rounded())
            ]
            .map(String.init)
            .joined(separator: ":")

            if seen.insert(key).inserted {
                unique.append(candidate)
            }
        }

        return unique
    }

    private static func expandedRect(_ rect: CGRect, padding: CGFloat) -> CGRect {
        let dx = max(0.02, rect.width * padding)
        let dy = max(0.02, rect.height * padding)
        return rect.insetBy(dx: -dx, dy: -dy).clampedToUnitRect()
    }

    private static func normalizedImage(from image: UIImage) -> UIImage {
        if image.imageOrientation == .up {
            return resizedImage(image, maxDimension: 2400)
        }

        let renderer = UIGraphicsImageRenderer(size: image.size)
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
        let renderer = UIGraphicsImageRenderer(size: targetSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }

    private static func isWorse(_ lhs: QuestionDetection, than rhs: QuestionDetection) -> Bool {
        if abs(lhs.confidence - rhs.confidence) > 0.02 {
            return lhs.confidence < rhs.confidence
        }

        if lhs.source == .localGuideVision, rhs.source != .localGuideVision {
            return false
        }

        if rhs.source == .localGuideVision, lhs.source != .localGuideVision {
            return true
        }

        return lhs.lineCount < rhs.lineCount
    }
}

private struct QuestionLine {
    let text: String
    let rect: CGRect
    let confidence: Float

    var compactText: String {
        text.replacingOccurrences(of: "\\s+", with: "", options: .regularExpression)
    }

    var characterCount: Int {
        compactText.count
    }

    var isQuestionAnchor: Bool {
        matches(pattern: #"^\s*\(?\d+\)?[.)、:]?"#)
    }

    var hasMathSignal: Bool {
        matches(pattern: #"[0-9=+\-xX*/()]"#)
    }

    func matches(pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }

        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.firstMatch(in: text, range: range) != nil
    }
}

private struct QuestionCluster {
    var lines: [QuestionLine]

    var rect: CGRect {
        lines.reduce(lines[0].rect) { partialResult, line in
            partialResult.union(line.rect)
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

    func clusterOverlapRatio(with rect: CGRect) -> CGFloat {
        let intersection = self.rect.intersection(rect)
        guard !intersection.isNull else {
            return 0
        }

        let clusterArea = max(self.rect.width * self.rect.height, 0.001)
        return (intersection.width * intersection.height) / clusterArea
    }

    func focusCoverage(with rect: CGRect) -> CGFloat {
        let intersection = self.rect.intersection(rect)
        guard !intersection.isNull else {
            return 0
        }

        let focusArea = max(rect.width * rect.height, 0.001)
        return (intersection.width * intersection.height) / focusArea
    }

    func score(focusRect: CGRect?, preferFocus: Bool) -> Double {
        let area = rect.width * rect.height
        let charScore = min(characterCount, 120)
        let anchorBonus = Double(lines.filter(\.isQuestionAnchor).count * 24)
        let mathBonus = Double(lines.filter(\.hasMathSignal).count * 10)
        let operatorCount = regexMatches(#"[=+\-xX*/()]"#, in: text)
        let confidenceScore = averageConfidence * 26
        let linePenalty = Double(max(0, lines.count - 6) * 10)
        let oversizePenalty = max(0, area - (preferFocus ? 0.34 : 0.56)) * 220
        let narrowPenalty = rect.width < (preferFocus ? 0.14 : 0.18) ? 16.0 : 0.0
        let shortPenalty = rect.height < 0.05 ? 16.0 : 0.0

        let focusBonus: Double
        let focusPenalty: Double
        let fallbackCenterPenalty: Double

        if let focusRect {
            let clusterOverlap = Double(clusterOverlapRatio(with: focusRect))
            let focusCoverage = Double(focusCoverage(with: focusRect))
            let expandedFocus = focusRect.insetBy(dx: -0.04, dy: -0.04)
            let centerInsideExpandedFocus = expandedFocus.contains(rect.center)
            let distance = hypot(rect.midX - focusRect.midX, rect.midY - focusRect.midY)
            focusBonus = clusterOverlap * (preferFocus ? 28 : 14)
                + focusCoverage * (preferFocus ? 132 : 68)
                + max(0, 1 - Double(distance) * 3.2) * (preferFocus ? 18 : 10)
                + (centerInsideExpandedFocus ? (preferFocus ? 16 : 8) : 0)
            focusPenalty = preferFocus && focusCoverage < 0.12 && !centerInsideExpandedFocus ? 28 : 0
            fallbackCenterPenalty = 0
        } else {
            focusBonus = 0
            focusPenalty = 0
            fallbackCenterPenalty = Double(abs(rect.midX - 0.5) * 24 + abs(rect.midY - 0.52) * 18)
        }

        return Double(charScore)
            + Double(lines.count * 20)
            + anchorBonus
            + mathBonus
            + Double(operatorCount * 2)
            + confidenceScore
            + focusBonus
            - linePenalty
            - oversizePenalty
            - narrowPenalty
            - shortPenalty
            - focusPenalty
            - fallbackCenterPenalty
    }

    func canAppend(_ line: QuestionLine) -> Bool {
        guard let last = lines.last else {
            return true
        }

        if line.isQuestionAnchor {
            return false
        }

        let verticalGap = max(0, last.rect.minY - line.rect.maxY)
        let overlapRect = rect.intersection(line.rect)
        let overlapWidth = overlapRect.isNull ? 0 : overlapRect.width
        let horizontalOverlap = overlapWidth / max(min(rect.width, line.rect.width), 0.001)
        let centerDistance = abs(rect.midX - line.rect.midX)
        let gapThreshold = max(0.06, averageHeight * 2.2)

        return verticalGap <= gapThreshold && (horizontalOverlap > 0.1 || centerDistance < 0.24)
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

    var center: CGPoint {
        CGPoint(x: midX, y: midY)
    }
}
