import SwiftUI

struct LiveQuestionView: View {
    @StateObject private var viewModel = LiveQuestionViewModel()

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.06, green: 0.08, blue: 0.14), Color(red: 0.10, green: 0.19, blue: 0.26)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if viewModel.permissionDenied {
                permissionView
            } else {
                VStack(spacing: 0) {
                    header
                    preview
                    footer
                }
            }
        }
        .onAppear {
            viewModel.start()
        }
        .onDisappear {
            viewModel.stop()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("单题实时识别")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("对准一道题，系统会实时 OCR、判断当前是哪道题，并输出裁切后的单题快照。")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.82))

            HStack(spacing: 10) {
                chip(viewModel.statusBadge, color: .green)
                chip("Vision 端侧 OCR", color: .cyan)
                chip("单题裁切", color: .yellow)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 14)
        .background(Color.black.opacity(0.18))
    }

    private var preview: some View {
        ZStack(alignment: .topLeading) {
            CameraPreviewView(
                session: viewModel.session,
                detectedRect: viewModel.detectedRect,
                fallbackRect: viewModel.previewFocusRect
            )
            .background(Color.black)

            Text(viewModel.statusText)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.black.opacity(0.55), in: Capsule())
                .padding(20)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("当前题目")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(.white)

                Spacer()

                if viewModel.isRefreshing {
                    ProgressView()
                        .tint(.white)
                        .controlSize(.small)
                }
            }

            cropCard

            ScrollView {
                Text(viewModel.currentText.isEmpty ? "还没有锁定到稳定单题。请让一道完整题目尽量填满取景框。" : viewModel.currentText)
                    .font(.body)
                    .foregroundStyle(viewModel.currentText.isEmpty ? .white.opacity(0.7) : .white)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(minHeight: 120, maxHeight: 220)

            Text(intentSummary)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            Text(viewModel.ocrSummary)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.72))

            Text(viewModel.hintText)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.68))
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 28)
        .background(Color.black.opacity(0.28))
    }

    private var cropCard: some View {
        HStack(alignment: .top, spacing: 14) {
            Group {
                if let image = viewModel.currentCropImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(Color.white.opacity(0.08))

                        VStack(spacing: 8) {
                            Image(systemName: "viewfinder")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.8))

                            Text("单题切图")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.68))
                        }
                    }
                }
            }
            .frame(width: 96, height: 96)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if let number = viewModel.currentIntent?.questionNumber {
                            chip("第 \(number) 题", color: .yellow)
                        }
                        if let subject = viewModel.currentIntent?.subject {
                            chip(subject.rawValue, color: .mint)
                        }
                        if let intent = viewModel.currentIntent?.intent {
                            chip(intent.rawValue, color: .orange)
                        }
                    }
                }

                Text(detailSummary)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(Color.white.opacity(0.08), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private var permissionView: some View {
        VStack(spacing: 18) {
            Image(systemName: "camera.fill")
                .font(.system(size: 42))
                .foregroundStyle(.white)

            Text("需要相机权限")
                .font(.title3.bold())
                .foregroundStyle(.white)

            Text("开启权限后，应用才能实时识别当前画面中的单题并输出裁切结果。")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.82))
        }
        .padding(28)
    }

    private var detailSummary: String {
        guard let intent = viewModel.currentIntent else {
            return "已锁定当前题目，正在等待更稳定的 OCR 和题型判断。"
        }

        var parts: [String] = []

        if let number = intent.questionNumber {
            parts.append("第 \(number) 题")
        }

        parts.append(intent.subject.rawValue)
        parts.append(intent.intent.rawValue)
        parts.append("置信 \(Int((intent.confidence * 100).rounded()))%")

        if !intent.signals.isEmpty {
            parts.append(intent.signals.joined(separator: " / "))
        }

        return parts.joined(separator: " | ")
    }

    private var intentSummary: String {
        guard let intent = viewModel.currentIntent else {
            return "意图识别等待中"
        }

        return "识别意图：\(intent.subject.rawValue) · \(intent.intent.rawValue)"
    }

    private func chip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.white.opacity(0.08), in: Capsule())
    }
}
