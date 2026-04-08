import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = ProblemSolverViewModel()
    @State private var activePickerSource: PickerSource?

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(
                    colors: [Color(red: 0.96, green: 0.93, blue: 0.87), Color(red: 0.98, green: 0.82, blue: 0.67)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        heroSection
                        imageSection
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
                ImagePicker(source: source) { image, pickerSource in
                    viewModel.setImage(image, source: pickerSource)
                }
            }
        }
    }

    private var heroSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("学生拍照解题")
                .font(.system(size: 34, weight: .bold, design: .rounded))
            Text("拍下题目，立刻拿到答案、分步解析、知识点和继续练习。")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
    }

    private var imageSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("题目图片")
                .font(.title3.bold())

            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(Color.white.opacity(0.72))
                    .frame(minHeight: 240)

                if let image = viewModel.selectedImage {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .padding(12)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "camera.viewfinder")
                            .font(.system(size: 34))
                        Text("先拍照或从相册导入题目")
                            .foregroundStyle(.secondary)
                    }
                }
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

    private var optionsSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("解题设置")
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
                Text("补充说明")
                    .font(.headline)
                TextEditor(text: $viewModel.questionHint)
                    .frame(minHeight: 100)
                    .padding(10)
                    .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("本地 OCR 识别的题干")
                    .font(.headline)
                TextEditor(text: $viewModel.recognizedText)
                    .frame(minHeight: 120)
                    .padding(10)
                    .background(Color.white.opacity(0.7), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
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
            .disabled(viewModel.isSubmitting || viewModel.selectedImage == nil)

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

            infoCard(title: "题目识别", body: result.cleanedQuestion, accent: .teal)
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
                .background(Color.white.opacity(0.66), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .padding(20)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
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
        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
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
        .background(Color.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
