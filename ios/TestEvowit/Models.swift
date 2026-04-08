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
        case .guided: return "启发式"
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

struct SolveClientTrace: Codable {
    let source: String?
    let recognizer: String?
    let ocrDurationMs: Int?
    let recognizedLineCount: Int?
    let recognizedTextLength: Int?
    let imageWidth: Int?
    let imageHeight: Int?
    let imageBytes: Int?
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
