import Foundation
import CoreGraphics

struct QuestionCaptureProfile {
    let focusRect: CGRect
    let previewInterval: CFTimeInterval
    let accurateRefreshInterval: CFTimeInterval
    let stableFramesRequired: Int

    static let live = QuestionCaptureProfile(
        focusRect: CGRect(x: 0.08, y: 0.18, width: 0.84, height: 0.62),
        previewInterval: 0.32,
        accurateRefreshInterval: 1.0,
        stableFramesRequired: 2
    )
}
