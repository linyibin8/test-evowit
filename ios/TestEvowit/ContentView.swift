import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ProblemSolverViewModel()
    @State private var activePickerSource: PickerSource?

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.97, green: 0.94, blue: 0.89), Color(red: 0.98, green: 0.84, blue: 0.70)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        heroSection
                        imageSection
                        recognitionSection
                        optionsSection
                        actionSection

                        if let result = viewModel.latestResult {
                            resultSection(result)
                        }

                        if !viewModel.history.isEmpty {
                            historySection
                        }
                    }
                    .padding(20)
                }
            }
            .navigationTitle("test-evowit")
            .sheet(item: $activePickerSource) { source in
                switch source {
                case .camera:
                    QuestionCameraView(captureProfile: viewModel.captureProfile) { image, metadata in
                        viewModel.setImage(
                            image,
                            source: .camera,
                            cropApplied: metadata.cropApplied,
                            metadata: metadata,
                            autoSolve: true
                        )
                    }
                case .photoLibrary:
                    ImagePicker(source: source) { image, pickerSource, cropApplied in
                        viewModel.setImage(image, source: pickerSource, cropApplied: cropApplied)
                    }
                }
            }
        }
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("像拍题 APP 一样，先裁单题，再稳稳解答")
                .font(.system(size: 31, weight: .bold, design: .rounded))

            Text("这一版会先在本地做 OCR，再判断是否交给大模型。为了减少答错，建议每次只拍一道题，拍完先裁到单题。")
                .font(.headline)
                .foregroundStyle(.secondary)

            HStack(spacing: 10) {
                statPill(title: "本地先识别", subtitle: "OCR + 质量判断")
                statPill(title: "单题优先", subtitle: "避免整页混题")
                statPill(title: "Trace 可追踪", subtitle: "服务端可看全链路")
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var imageSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("第 1 步：拍题并裁成单题")
                .font(.title3.bold())

            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.74))
                    .frame(minHeight: 260)

                if let image = viewModel.selectedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .padding(12)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 36))
                        Text("先拍一题，尽量只保留一道题的题干")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Text("参考豆包爱学这类拍题产品的思路，先框选单题再识别，效果会比整页作业直接上传稳很多。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("Capture Strategy")
                    .font(.headline)

                Picker("Capture Strategy", selection: $viewModel.captureProfile) {
                    ForEach(QuestionCaptureProfile.allCases) { profile in
                        Text(profile.title).tag(profile)
                    }
                }
                .pickerStyle(.segmented)

                Text(viewModel.captureProfile.subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Button("拍照解题") {
                    activePickerSource = .camera
                }
                .buttonStyle(.borderedProminent)

                Button("从相册选择") {
                    activePickerSource = .photoLibrary
                }
                .buttonStyle(.bordered)

                Spacer()

                if viewModel.selectedImage != nil {
                    Button("清空") {
                        viewModel.reset()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var recognitionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("第 2 步：本地 OCR 识别")
                .font(.title3.bold())

            HStack(alignment: .center, spacing: 12) {
                Capsule()
                    .fill(viewModel.isRecognizing ? Color.orange.opacity(0.18) : Color.teal.opacity(0.18))
                    .overlay(
                        Text(viewModel.recognitionStatus)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(viewModel.isRecognizing ? .orange : .teal)
                            .padding(.horizontal, 14)
                    )
                    .frame(height: 38)

                if viewModel.isRecognizing {
                    ProgressView()
                }
            }

            Text(viewModel.recognitionHint)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                Text("识别出的题干")
                    .font(.headline)
                TextEditor(text: $viewModel.recognizedText)
                    .frame(minHeight: 140)
                    .padding(10)
                    .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("第 3 步：补充解题信息")
                .font(.title3.bold())

            Picker("学科", selection: $viewModel.selectedSubject) {
                ForEach(ProblemSubject.allCases) { subject in
                    Text(subject.title).tag(subject)
                }
            }
            .pickerStyle(.segmented)

            Picker("讲解风格", selection: $viewModel.answerStyle) {
                ForEach(AnswerStyle.allCases) { style in
                    Text(style.title).tag(style)
                }
            }
            .pickerStyle(.segmented)

            Picker("年级", selection: $viewModel.gradeBand) {
                ForEach(GradeBand.allCases) { band in
                    Text(band.rawValue).tag(band)
                }
            }
            .pickerStyle(.segmented)

            VStack(alignment: .leading, spacing: 8) {
                Text("手动补充题干或要求")
                    .font(.headline)
                TextEditor(text: $viewModel.questionHint)
                    .frame(minHeight: 110)
                    .padding(10)
                    .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                Task {
                    await viewModel.solve()
                }
            } label: {
                HStack {
                    if viewModel.isSubmitting {
                        ProgressView()
                            .tint(.white)
                    }
                    Text(viewModel.isSubmitting ? "正在解析..." : "开始解析")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(viewModel.isSubmitting || viewModel.selectedImage == nil || viewModel.isRecognizing)

            Text("如果 OCR 提示像整页作业，建议先裁到单题再提交，这比直接让大模型猜要稳得多。")
                .font(.subheadline)
                .foregroundStyle(.secondary)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .foregroundStyle(.red)
            }
        }
    }

    private func resultSection(_ result: SolveProblemResponse) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("解析结果")
                .font(.title2.bold())

            infoCard(
                title: "本次处理链路",
                body: """
                路由：\(result.pipelineRouteTitle)
                模型：\(result.usedModel)
                耗时：\(result.processingMs) ms
                Trace ID：\(result.traceId)
                """,
                accent: .brown
            )

            if result.shouldRetakePhoto {
                infoCard(title: "重拍建议", body: result.retakeReason, accent: .orange)
            }

            infoCard(title: "题干识别", body: result.cleanedQuestion, accent: .teal)
            infoCard(title: "答案", body: result.answer, accent: .blue)
            listCard(title: "分步讲解", items: result.keySteps)
            infoCard(title: "完整解析", body: result.fullExplanation, accent: .indigo)
            tagCard(title: "知识点", items: result.knowledgePoints)
            tagCard(title: "易错点", items: result.commonMistakes)
            infoCard(title: "继续练习", body: result.followUpPractice, accent: .green)
            infoCard(title: "鼓励语", body: result.encouragement, accent: .pink)
            infoCard(title: "最近会话摘要", body: result.sessionSummary, accent: .mint)
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("最近解题")
                .font(.title3.bold())

            ForEach(viewModel.history) { item in
                HStack(spacing: 12) {
                    if let image = UIImage(data: item.thumbnailData) {
                        Image(uiImage: image)
                            .resizable()
                            .scaledToFill()
                            .frame(width: 72, height: 72)
                            .clipped()
                            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text(item.problemText)
                            .font(.headline)
                            .lineLimit(2)
                        Text(item.answer)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                        Text(item.createdAt.formatted(date: .omitted, time: .shortened))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()
                }
                .padding(14)
                .background(Color.white.opacity(0.68), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private func statPill(title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.subheadline.weight(.semibold))
            Text(subtitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.white.opacity(0.62), in: Capsule())
    }

    private func infoCard(title: String, body: String, accent: Color) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "sparkles")
                .font(.headline)
                .foregroundStyle(accent)
            Text(body)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16)
        .background(Color.white.opacity(0.74), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func listCard(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.headline)

            if items.isEmpty {
                Text("暂无")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(index + 1).")
                            .fontWeight(.semibold)
                        Text(item)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.74), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func tagCard(title: String, items: [String]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            if items.isEmpty {
                Text("暂无")
                    .foregroundStyle(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                    ForEach(items, id: \.self) { item in
                        Text(item)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(Color.teal.opacity(0.12), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                    }
                }
            }
        }
        .padding(16)
        .background(Color.white.opacity(0.74), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
