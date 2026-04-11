import CoreGraphics
import Foundation

enum ProblemSubject: String, CaseIterable, Identifiable, Codable {
    case math
    case chinese
    case english
    case science
    case general

    var id: String { rawValue }

    var title: String {
        switch self {
        case .math: return "数学"
        case .chinese: return "语文"
        case .english: return "英语"
        case .science: return "科学"
        case .general: return "通用"
        }
    }
}

enum AnswerStyle: String, CaseIterable, Identifiable, Codable {
    case guided
    case detailed
    case direct

    var id: String { rawValue }

    var title: String {
        switch self {
        case .guided: return "启发讲解"
        case .detailed: return "详细解析"
        case .direct: return "直接答案"
        }
    }
}

enum GradeBand: String, CaseIterable, Identifiable, Codable {
    case primary = "小学"
    case middleSchool = "初中"
    case highSchool = "高中"
    case college = "大学"

    var id: String { rawValue }
}

enum QuestionCaptureProfile: String, CaseIterable, Identifiable, Codable {
    case fast
    case balanced
    case precise

    var id: String { rawValue }

    var title: String {
        switch self {
        case .fast:
            return "Fast"
        case .balanced:
            return "Balanced"
        case .precise:
            return "Precise"
        }
    }

    var subtitle: String {
        switch self {
        case .fast:
            return "Locks quickly for simple, clean questions."
        case .balanced:
            return "Best default for everyday homework shots."
        case .precise:
            return "Stricter locking for dense or messy worksheets."
        }
    }

    var focusRect: CGRect {
        switch self {
        case .fast:
            return CGRect(x: 0.14, y: 0.4, width: 0.72, height: 0.22)
        case .balanced:
            return CGRect(x: 0.12, y: 0.38, width: 0.76, height: 0.24)
        case .precise:
            return CGRect(x: 0.1, y: 0.34, width: 0.8, height: 0.3)
        }
    }

    var previewAnalysisIntervalMs: Int {
        switch self {
        case .fast:
            return 180
        case .balanced:
            return 250
        case .precise:
            return 320
        }
    }

    var lockFramesRequired: Int {
        switch self {
        case .fast:
            return 1
        case .balanced:
            return 2
        case .precise:
            return 3
        }
    }

    var serverRequestIntervalMs: Int {
        switch self {
        case .fast:
            return 1200
        case .balanced:
            return 900
        case .precise:
            return 700
        }
    }

    var previewJpegMaxDimension: CGFloat {
        switch self {
        case .fast:
            return 1080
        case .balanced:
            return 1280
        case .precise:
            return 1440
        }
    }

    var previewJpegCompression: CGFloat {
        switch self {
        case .fast:
            return 0.56
        case .balanced:
            return 0.62
        case .precise:
            return 0.72
        }
    }
}

enum QuestionDetectionSource: String, Codable {
    case guideFrame = "guide_frame"
    case localGuideVision = "local_guide_vision"
    case localVision = "local_vision"
    case serverLayout = "server_layout"
    case serverFocusedLayout = "server_focused_layout"
}

struct QuestionCaptureMetadata {
    let captureProfile: QuestionCaptureProfile
    let cropApplied: Bool
    let cropSource: QuestionDetectionSource?
    let cropCoverage: Double?
    let focusRect: ServerNormalizedRect?
    let lockFramesRequired: Int
    let previewAnalysisIntervalMs: Int
    let serverRequestIntervalMs: Int
    let originalImageWidth: Int?
    let originalImageHeight: Int?
    let previewDetectionSource: QuestionDetectionSource?
    let warnings: [String]
}

struct SolveClientTrace: Codable {
    let source: String?
    let recognizer: String?
    let preprocessProfile: String?
    let cropApplied: Bool?
    let ocrQuality: String?
    let ocrQualityReason: String?
    let ocrDurationMs: Int?
    let recognizedLineCount: Int?
    let recognizedTextLength: Int?
    let imageWidth: Int?
    let imageHeight: Int?
    let imageBytes: Int?
    let originalImageWidth: Int?
    let originalImageHeight: Int?
    let ocrAverageConfidence: Double?
    let ocrPass: String?
    let autoCropApplied: Bool?
    let autoCropSource: String?
    let autoCropCoverage: Double?
    let ocrWarnings: [String]?
    let captureProfile: String?
    let lockFramesRequired: Int?
    let previewAnalysisIntervalMs: Int?
    let serverRequestIntervalMs: Int?
    let focusRect: ServerNormalizedRect?
    let appVersion: String?
    let buildNumber: String?
    let clientStartedAt: String?
}

struct SolveProblemRequest {
    let sessionId: String?
    let subject: String
    let gradeBand: String
    let answerStyle: String
    let questionHint: String?
    let recognizedText: String?
    let clientTrace: SolveClientTrace?
}

struct SolveProblemResponse: Codable, Identifiable {
    let traceId: String
    let sessionId: String
    let problemText: String
    let cleanedQuestion: String
    let inferredSubject: String
    let problemType: String
    let difficulty: String
    let answer: String
    let keySteps: [String]
    let fullExplanation: String
    let knowledgePoints: [String]
    let commonMistakes: [String]
    let followUpPractice: String
    let encouragement: String
    let confidence: Double
    let shouldRetakePhoto: Bool
    let retakeReason: String
    let sessionSummary: String
    let turnCount: Int
    let pipelineRoute: String
    let usedModel: String
    let processingMs: Int

    var id: String { "\(sessionId)-\(turnCount)-\(traceId)" }

    var pipelineRouteTitle: String {
        switch pipelineRoute {
        case "local": return "本地快速求解"
        case "model_text_only": return "OCR 文本直解"
        case "model_vision": return "图片视觉解题"
        case "heuristic_fallback": return "本地兜底模式"
        default: return pipelineRoute
        }
    }
}

struct SolveHistoryItem: Identifiable {
    let id = UUID()
    let createdAt = Date()
    let thumbnailData: Data
    let problemText: String
    let answer: String
}

struct ServerQuestionDetectionResponse: Codable {
    let ok: Bool
    let model: String
    let device: String
    let imageWidth: Int
    let imageHeight: Int
    let boxCount: Int
    let boxes: [ServerQuestionDetectionBox]
    let questionBox: ServerQuestionBox?
    let cropApplied: Bool
    let croppedWidth: Int?
    let croppedHeight: Int?
    let croppedBytes: Int?
    let cropCoordinate: [Int]?
    let coverage: Double?
    let focusRect: ServerNormalizedRect?
}

struct ServerQuestionDetectionBox: Codable {
    let label: String
    let score: Double
    let coordinate: [Double]
    let normalized: ServerNormalizedRect
    let order: Int
}

struct ServerQuestionBox: Codable {
    let score: Double
    let coordinate: [Double]
    let normalized: ServerNormalizedRect
    let labels: [String]
    let boxCount: Int
    let areaRatio: Double
}

struct ServerNormalizedRect: Codable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double
}
