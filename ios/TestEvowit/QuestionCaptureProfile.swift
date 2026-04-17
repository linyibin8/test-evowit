import CoreGraphics
import Foundation

struct QuestionCaptureProfile {
    let focusRect: CGRect
    let previewInterval: CFTimeInterval
    let accurateRefreshInterval: CFTimeInterval
    let stableFramesRequired: Int

    static let live = QuestionCaptureProfile(
        focusRect: CGRect(x: 0.06, y: 0.14, width: 0.88, height: 0.68),
        previewInterval: 0.24,
        accurateRefreshInterval: 0.8,
        stableFramesRequired: 2
    )
}
