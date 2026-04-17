import CoreGraphics
import UIKit

enum LiveQuestionSubject: String {
    case math = "数学"
    case chinese = "语文"
    case english = "英语"
    case science = "理科"
    case general = "通用"
}

enum LiveQuestionIntentKind: String {
    case calculation = "计算"
    case multipleChoice = "选择"
    case fillBlank = "填空"
    case explanation = "解答"
    case reading = "阅读"
    case unknown = "待定"
}

struct LiveQuestionIntentInfo {
    let questionNumber: String?
    let subject: LiveQuestionSubject
    let intent: LiveQuestionIntentKind
    let confidence: Double
    let signals: [String]
}

struct DetectedQuestionBlock {
    let normalizedRect: CGRect
    let previewText: String
    let lineCount: Int
    let confidence: Double
    let questionNumber: String?
    let blockID: String
}

enum QuestionOCRQuality: String {
    case good = "稳定"
    case needsCrop = "需重取景"
    case weak = "较弱"
}

struct QuestionOCRResult {
    let text: String
    let lineCount: Int
    let quality: QuestionOCRQuality
    let preprocessProfile: String
}

struct LiveQuestionSnapshot {
    let text: String
    let cropImage: UIImage?
    let intent: LiveQuestionIntentInfo?
    let ocrSummary: String
}
