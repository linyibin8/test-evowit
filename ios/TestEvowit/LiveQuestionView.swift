import PhotosUI
import SwiftUI
import UIKit

struct LiveQuestionView: View {
    @StateObject private var viewModel = LiveQuestionViewModel()
    @State private var selectedPhotoItem: PhotosPickerItem?

    var body: some View {
        ZStack {
            LinearGradient(
                colors: [Color(red: 0.05, green: 0.08, blue: 0.15), Color(red: 0.08, green: 0.17, blue: 0.24)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()

            if viewModel.permissionDenied {
                permissionView
            } else {
                ScrollView(showsIndicators: false) {
                    VStack(alignment: .leading, spacing: 18) {
                        header
                        previewCard
                        actionPanel
                        resultPanel
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 18)
                    .padding(.bottom, 28)
                }
            }
        }
        .task(id: selectedPhotoItem) {
            await handleSelectedPhoto()
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
            Text("单题拍照识别")
                .font(.system(size: 30, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text("实时跟踪镜头里的题目，同时支持拍照精识别、当前画面识别和相册导入。先把一道完整题目放进框内，再点按钮锁定单题。")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.82))

            HStack(spacing: 10) {
                chip(viewModel.statusBadge, color: .green)
                chip("实时 OCR", color: .cyan)
                chip("单题裁切", color: .yellow)
                chip("意图识别", color: .orange)
            }
        }
    }

    private var previewCard: some View {
        ZStack(alignment: .topLeading) {
            CameraPreviewView(
                session: viewModel.session,
                detectedRect: viewModel.detectedRect,
                fallbackRect: viewModel.previewFocusRect
            )
            .frame(height: 320)
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
            .background(
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(Color.black.opacity(0.24))
            )

            VStack(alignment: .leading, spacing: 10) {
                Text(viewModel.statusText)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.black.opacity(0.58), in: Capsule())

                Text(viewModel.hintText)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.82))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            .padding(16)
        }
    }

    private var actionPanel: some View {
        VStack(spacing: 12) {
            Button(action: viewModel.capturePhoto) {
                Label(viewModel.isRefreshing ? "正在拍照/识别" : "拍照识别", systemImage: "camera.circle.fill")
                    .font(.headline.weight(.semibold))
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(PrimaryActionButtonStyle())
            .disabled(viewModel.isRefreshing)

            HStack(spacing: 10) {
                PhotosPicker(
                    selection: $selectedPhotoItem,
                    matching: .images,
                    preferredItemEncoding: .automatic
                ) {
                    Label("相册导入", systemImage: "photo.on.rectangle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .disabled(viewModel.isRefreshing)

                Button(action: viewModel.analyzeCurrentFrame) {
                    Label("识别当前画面", systemImage: "viewfinder.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(SecondaryActionButtonStyle())
                .disabled(viewModel.isRefreshing)
            }

            Button(action: viewModel.resetRecognition) {
                Label("重新扫描", systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(TertiaryActionButtonStyle())
        }
    }

    private var resultPanel: some View {
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

            Text(viewModel.currentText.isEmpty ? "还没有拿到清晰的单题结果。你可以直接点“拍照识别”或“识别当前画面”，不要只等自动锁题。" : viewModel.currentText)
                .font(.body)
                .foregroundStyle(viewModel.currentText.isEmpty ? .white.opacity(0.72) : .white)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .padding(16)
                .background(Color.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 22, style: .continuous))

            Text(intentSummary)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            Text(viewModel.ocrSummary)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.76))

            Text(viewModel.hintText)
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.68))
        }
        .padding(18)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.06), lineWidth: 1)
        )
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
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .fill(Color.white.opacity(0.08))

                        VStack(spacing: 8) {
                            Image(systemName: "viewfinder")
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.82))

                            Text("单题切图")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.white.opacity(0.68))
                        }
                    }
                }
            }
            .frame(width: 110, height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))

            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        chip(viewModel.resultSourceLabel, color: .mint)

                        if let number = viewModel.currentIntent?.questionNumber {
                            chip("第 \(number) 题", color: .yellow)
                        }
                        if let subject = viewModel.currentIntent?.subject {
                            chip(subject.rawValue, color: .cyan)
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
    }

    private var permissionView: some View {
        VStack(spacing: 16) {
            Image(systemName: "camera.fill")
                .font(.system(size: 40))
                .foregroundStyle(.white)

            Text("需要相机权限")
                .font(.title3.bold())
                .foregroundStyle(.white)

            Text("开启权限后才能实时识别镜头中的题目。你也可以先从相册导入一张题目图片测试单题识别。")
                .font(.body)
                .multilineTextAlignment(.center)
                .foregroundStyle(.white.opacity(0.82))

            Button("打开系统设置") {
                guard let url = URL(string: UIApplication.openSettingsURLString) else {
                    return
                }
                UIApplication.shared.open(url)
            }
            .buttonStyle(PrimaryActionButtonStyle())

            PhotosPicker(
                selection: $selectedPhotoItem,
                matching: .images,
                preferredItemEncoding: .automatic
            ) {
                Label("先从相册导入", systemImage: "photo.on.rectangle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SecondaryActionButtonStyle())
        }
        .padding(24)
    }

    private var detailSummary: String {
        guard let intent = viewModel.currentIntent else {
            return "题目已进入识别流程，正在等待更稳定的 OCR 和题型判断。"
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
            return "意图识别待命中。先让单题更靠近镜头，或者直接点拍照识别。"
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

    @MainActor
    private func handleSelectedPhoto() async {
        guard let selectedPhotoItem else {
            return
        }

        defer {
            self.selectedPhotoItem = nil
        }

        guard let data = try? await selectedPhotoItem.loadTransferable(type: Data.self),
              let image = UIImage(data: data)
        else {
            viewModel.reportImportFailure()
            return
        }

        viewModel.importPhoto(image)
    }
}

private struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
            .background(
                LinearGradient(
                    colors: [Color(red: 0.13, green: 0.73, blue: 0.51), Color(red: 0.10, green: 0.57, blue: 0.90)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.15), value: configuration.isPressed)
    }
}

private struct SecondaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 14)
            .background(Color.white.opacity(configuration.isPressed ? 0.18 : 0.10), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}

private struct TertiaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(.white.opacity(0.88))
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .background(Color.black.opacity(configuration.isPressed ? 0.32 : 0.22), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(Color.white.opacity(0.08), lineWidth: 1)
            )
    }
}
