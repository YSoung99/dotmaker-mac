import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Stage: String, CaseIterable, Identifiable {
    case dot = "도트화"

    var id: Self { self }
    var instruction: String { "머리와 몸통을 구분해 검은 윤곽과 몸통 경계색을 적용합니다." }
}

private struct Product: Sendable {
    let settings: DotSettings
    let original: CGImage
    let subject: Raster
    let reduced: Reduced
    let dotted: Dotted
    let reducedImage: CGImage
    let dottedImage: CGImage

    init(original: CGImage, subject: Raster, size: Grid, settings: DotSettings,
         cachedReduction: Reduced? = nil, jevResult: Dotted? = nil) throws {
        self.settings = settings
        self.original = original
        self.subject = subject
        let direct = settings.method.samplesOriginal
        if let cachedReduction, cachedReduction.direct == direct, cachedReduction.image.grid.w == size.w,
           cachedReduction.image.grid.h == size.h {
            reduced = cachedReduction
        } else {
            reduced = try Reduced(subject: subject, w: size.w, h: size.h, direct: direct)
        }
        switch settings.method {
        case .faithful:
            var cleaned = settings.cleanBlends ? Dotting.cleanBlends(reduced.image) : reduced.image
            if settings.preserveMouth { FaceDetail.preserveMouth(&cleaned, source: reduced) }
            dotted = try jevResult ?? Dotting.preserve(image: settings.crispOutline ? Dotting.crispOutline(cleaned) : cleaned)
        case .berry:
            dotted = try LegacyDot.render(subject: subject, w: size.w, h: size.h, settings: settings)
        case .basic, .direct:
            dotted = try Dotting.render(reduced, settings: settings)
        }
        reducedImage = try reduced.image.image()
        dottedImage = try dotted.image.image()
    }
}

@MainActor
final class DotMakerModel: ObservableObject {
    @Published var stage: Stage = .dot
    @Published var showJevSettings = false
    @Published var showJevDetails = false
    @Published private(set) var jevDetails: [JevDetailRow] = []
    /// 항목별로 고른 후보(없으면 안 바꿈). JEV가 확실히 고른 것으로 미리 채운다.
    @Published var jevPicks: [String: Int] = [:]
    private var jevBase: Raster?
    var jevChanges: [String] {
        guard let jevBase else { return [] }
        return JevDetails.apply(jevDetails, picks: jevPicks, to: jevBase).1
    }
    @Published private(set) var jevFocus = JevFocus.details
    var jevTitle: String { jevFocus == .blends ? "JEV 섞인 색 판정" : "JEV 부위별 진단" }
    @Published var keyDraft = ""
    @Published var keyStatus = ""
    /// 결과 캔버스 한 변(정사각형). 바꾸면 바로 다시 그린다.
    @Published var size = 100 { didSet { if oldValue != size { resize() } } }
    static let sizes = Array(stride(from: 100, through: 200, by: 10))
    @Published var settings = DotSettings(method: .faithful)
    @Published private(set) var busy: String?
    @Published private(set) var error: String?
    @Published private(set) var file: URL?
    @Published private(set) var colorStatus: String?
    @Published private var product: Product?
    /// 도트화에 쓴 원본(AI 업스케일을 거쳤으면 4배로 키운 그림)과 쓴 모델. 모델이 그대로면 다시 만들지 않는다.
    private var prepared: (image: CGImage, model: String?)?
    /// 도트 그림 저장 배율(1·2·4·8배). 다음에 앱을 열어도 기억한다.
    @Published var exportScale = max(1, UserDefaults.standard.integer(forKey: "exportScale")) {
        didSet { UserDefaults.standard.set(exportScale, forKey: "exportScale") }
    }
    private var generation = UUID()
    private var cancel: (() -> Void)?

    var original: CGImage? { product?.original }
    var dotted: CGImage? { product?.dottedImage }
    var reduced: CGImage? { product?.reducedImage }
    var result: CGImage? { result(for: stage) }

    func result(for stage: Stage) -> CGImage? {
        switch stage {
        case .dot: dotted
        }
    }
    var dotStatus: String? {
        guard let product else { return nil }
        let sharpened = prepared?.model.map { "  ·  AI 업스케일 \(Upscaler.label($0))" } ?? ""
        if product.settings.method == .faithful {
            return "원본 보존  ·  \(product.dottedImage.width)×\(product.dottedImage.height) px  ·  투명 PNG" + sharpened
        }
        let dotted = product.dotted
        guard product.settings.method == .basic else {
            return "\(product.settings.method.rawValue)  ·  실제 \(ColorReducer.count(dotted.image))색"
        }
        let head = dotted.headCount > 0 ? "분홍 머리 영역 감지" : "분홍 머리 영역 미감지"
        let body = dotted.bodyCount > 0 ? "밝은 몸통 영역 감지" : "밝은 몸통 영역 미감지"
        return "\(head)  ·  \(body)  ·  실제 \(ColorReducer.count(dotted.image))색"
    }

    func choose() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url { self?.open(url) }
        }
    }

    func open(_ url: URL) {
        guard let (w, h) = dimensions() else { return }
        let options = settings
        run("원본에서 캐릭터 분리 중", work: {
            let original = try Raster.load(url, originalResolution: true)
            let model = Upscaler.model(for: original, mode: options.upscale, target: max(w, h))
            let source = try model.map { try Upscaler.upscale(original, model: $0) } ?? original
            let subject = try Subject.extract(source, preserveTransparentArt: options.method == .faithful)
            return (try Product(original: original, subject: subject, size: Grid(w: w, h: h), settings: options), source, model)
        }) { product, source, model in
            self.product = product
            self.prepared = (source, model)
            self.file = url
            self.colorStatus = nil
        }
    }

    func resize() {
        guard let product, let (w, h) = dimensions() else { return }
        let options = settings
        colorStatus = nil
        let model = Upscaler.model(for: product.original, mode: options.upscale, target: max(w, h))
        let reuse = prepared?.model == model ? prepared : nil
        run(reuse == nil ? "AI가 원본을 4배로 키우는 중" : "캐릭터 축소 중", work: {
            let source = try reuse?.image ?? (model.map { try Upscaler.upscale(product.original, model: $0) } ?? product.original)
            let subject = reuse != nil ? product.subject
                : try Subject.extract(source, preserveTransparentArt: options.method == .faithful)
            return (try Product(original: product.original, subject: subject, size: Grid(w: w, h: h), settings: options), source, model)
        }) { product, source, model in
            self.product = product
            self.prepared = (source, model)
        }
    }

    func redot() {
        guard let product, product.settings != settings else { return }
        let options = settings
        colorStatus = nil
        let faithful = options.method == .faithful
        let model = Upscaler.model(for: product.original, mode: options.upscale, target: product.reduced.image.grid.w)
        let reuse = prepared?.model == model ? prepared : nil
        let sameSubject = reuse != nil && faithful == (product.settings.method == .faithful)
        run(reuse == nil ? "AI가 원본을 4배로 키우는 중" : faithful ? "원본의 선과 색을 맞추는 중" : "외곽선 정리 중", work: {
            let source = try reuse?.image ?? (model.map { try Upscaler.upscale(product.original, model: $0) } ?? product.original)
            let subject = sameSubject ? product.subject
                : try Subject.extract(source, preserveTransparentArt: faithful)
            return (try Product(original: product.original, subject: subject, size: product.reduced.image.grid,
                                settings: options, cachedReduction: sameSubject ? product.reduced : nil), source, model)
        }) { product, source, model in
            self.product = product
            self.prepared = (source, model)
        }
    }

    func optimizeColors() {
        guard let product, busy == nil, settings.method != .faithful else { return }
        let options = JevColors.variants(settings)
        run("JEV가 도트화 후보를 나란히 비교 중", work: {
            let key = try GatewayKey.load()
            let candidates = try options.map {
                try Product(original: product.original, subject: product.subject,
                            size: product.reduced.image.grid, settings: $0, cachedReduction: product.reduced)
            }
            let verdict = try await JevColors.choose(original: product.original,
                                                     images: candidates.map(\.dottedImage), key: key)
            return (candidates[verdict.index], verdict)
        }) { chosen, verdict in
            self.product = chosen
            self.settings = chosen.settings
            let share = Int((verdict.scores[verdict.index] * 100).rounded())
            self.colorStatus = "JEV가 후보 \(verdict.scores.count)개를 나란히 비교해 ‘\(JevColors.label(chosen.settings))’을 골랐습니다 (확률 \(share)%)."
        }
    }

    func judgeFaithful() {
        guard let product, busy == nil, product.settings.method == .faithful else { return }
        run("JEV가 선 굵기와 채색을 차례로 비교 중", work: {
            let key = try GatewayKey.load()
            let reference = try product.subject.image()
            let strokes = try JevColors.strokeCandidates(product.reduced)
            let stroke = try await JevColors.choose(original: reference, candidates: strokes, criterion: .strokes, key: key)
            let fills = try JevColors.fillCandidates(stroke.dotted, source: product.reduced)
            let fill = try await JevColors.choose(original: reference, candidates: fills, criterion: .colors, key: key)
            let chosen = try Product(original: product.original, subject: product.subject, size: product.reduced.image.grid,
                                     settings: product.settings, cachedReduction: product.reduced, jevResult: fill.dotted)
            return (chosen, stroke.label, fill.label)
        }) { chosen, stroke, fill in
            self.product = chosen
            self.colorStatus = "JEV 선택 · \(stroke) · \(fill)"
        }
    }

    func diagnoseDetails() { diagnose(.details) }
    func judgeBlends() { diagnose(.blends) }

    private func diagnose(_ focus: JevFocus) {
        guard let product, busy == nil, product.settings.method == .faithful else { return }
        let label = focus == .blends ? "JEV가 경계의 섞인 색을 부분별로 확인 중"
            : "JEV가 선, 색, 투명 테두리와 빠진 디테일을 확인 중"
        run(label, work: {
            try await JevDetails.judge(subject: product.subject, reduced: product.reduced,
                                       current: product.dotted.image, focus: focus, key: GatewayKey.load())
        }) {
            self.jevFocus = focus
            self.jevDetails = $0.rows
            self.jevBase = $0.base
            self.jevPicks = Dictionary(uniqueKeysWithValues: $0.rows.compactMap { row in row.suggested.map { (row.id, $0) } })
            self.showJevDetails = true
        }
    }

    func applyDetails() {
        guard let product, let base = jevBase, busy == nil, product.settings.method == .faithful else { return }
        let (applied, changes) = JevDetails.apply(jevDetails, picks: jevPicks, to: base)
        guard !changes.isEmpty else { return }
        do {
            self.product = try Product(original: product.original, subject: product.subject, size: product.reduced.image.grid,
                                       settings: product.settings, cachedReduction: product.reduced,
                                       jevResult: Dotting.preserve(image: applied))
            colorStatus = "\(jevTitle) 적용 · " + changes.joined(separator: " · ")
            jevBase = nil
            jevPicks = [:]
            showJevDetails = false
        } catch {
            self.error = error.localizedDescription
        }
    }

    func resetFaithful() {
        guard let product, busy == nil, product.settings.method == .faithful else { return }
        do {
            self.product = try Product(original: product.original, subject: product.subject, size: product.reduced.image.grid,
                                       settings: product.settings, cachedReduction: product.reduced)
            colorStatus = nil
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func save() {
        guard let result else { return }
        save(result, label: stage.rawValue.replacingOccurrences(of: " ", with: "-"))
    }

    /// label은 파일 이름에 들어간다. 도트 그림은 저장 배율만큼 정수배로 키운다.
    func save(_ image: CGImage, label: String) {
        guard busy == nil else { return }
        let scale = exportScale
        let output: CGImage
        do { output = scale > 1 ? try Raster(image).scaled(by: scale).image() : image } catch {
            self.error = error.localizedDescription
            return
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        // 마지막으로 저장한 폴더에서 연다.
        if let folder = UserDefaults.standard.url(forKey: "saveFolder") { panel.directoryURL = folder }
        let base = file?.deletingPathExtension().lastPathComponent ?? "도트그림"
        let suffix = scale > 1 ? "-\(scale)배" : ""
        panel.nameFieldStringValue = "\(base)-\(label)-\(image.width)x\(image.height)\(suffix).png"
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            UserDefaults.standard.set(url.deletingLastPathComponent(), forKey: "saveFolder")
            do {
                try Raster.save(output, to: url)
                self?.error = nil
            } catch {
                self?.error = error.localizedDescription
            }
        }
    }

    private func dimensions() -> (Int, Int)? {
        let w = size, h = size
        guard (16...512).contains(w) else {
            error = DotError.dimensions.localizedDescription
            return nil
        }
        return (w, h)
    }

    private func run<T: Sendable>(_ label: String, work: @escaping @Sendable () async throws -> T,
                                  apply: @escaping (T) -> Void) {
        cancel?()
        let id = UUID()
        generation = id
        error = nil
        busy = label
        let worker = Task.detached(priority: .userInitiated, operation: work)
        cancel = { worker.cancel() }
        Task {
            let result = await worker.result
            guard generation == id else { return }
            busy = nil
            cancel = nil
            switch result {
            case .success(let value): apply(value)
            case .failure(let failure): error = failure.localizedDescription
            }
        }
    }
}

@main
struct DotMakerApp: App {
    @StateObject private var model = DotMakerModel()
    var body: some Scene {
        Window("도트메이커", id: "main") {
            ContentView(model: model)
                .frame(minWidth: 740, minHeight: 550)
        }
        .defaultSize(width: 920, height: 660)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("이미지 열기…", action: model.choose)
                    .keyboardShortcut("o")
                Button("PNG 저장…", action: model.save)
                    .keyboardShortcut("s")
                    .disabled(model.result == nil || model.busy != nil)
            }
        }
    }
}

private struct ContentView: View {
    @ObservedObject var model: DotMakerModel

    var body: some View {
        VStack(spacing: 15) {
            HStack(spacing: 12) {
                Button("이미지 열기…", systemImage: "folder", action: model.choose)
                if let file = model.file {
                    Text(file.lastPathComponent)
                        .lineLimit(1).truncationMode(.middle)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("저장 배율", selection: $model.exportScale) {
                    ForEach([1, 2, 4, 8], id: \.self) { Text("\($0)배").tag($0) }
                }
                .fixedSize()
                .help("도트 그림을 정수배로 키워 저장합니다(번짐 없음).")
                Button("PNG 저장…", systemImage: "square.and.arrow.down", action: model.save)
                    .disabled(model.result == nil || model.busy != nil)
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)

            screen(.dot)
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let first = urls.first, first.isFileURL else { return false }
            model.open(first)
            return true
        }
        .sheet(isPresented: $model.showJevDetails) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text(model.jevTitle).font(.title2)
                    Spacer()
                    Button("닫기") { model.showJevDetails = false }
                }
                VStack(alignment: .leading, spacing: 4) {
                    let changes = model.jevChanges
                    Text(changes.isEmpty ? "적용할 변경 없음" : "적용할 변경").font(.headline)
                    Text("JEV가 확실하게 고른 후보는 미리 선택돼 있습니다. 항목마다 아래 버튼으로 직접 바꿀 수 있습니다.")
                        .foregroundStyle(.secondary)
                    ForEach(changes, id: \.self) { Text("• " + $0) }
                    Button("선택 적용", action: model.applyDetails)
                        .buttonStyle(.borderedProminent)
                        .disabled(changes.isEmpty)
                }
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(model.jevDetails) { row in
                            VStack(alignment: .leading, spacing: 5) {
                                Text(row.title).font(.headline)
                                if !row.result.isEmpty { Text("JEV: " + row.result).textSelection(.enabled) }
                                if !row.options.isEmpty {
                                    Picker("고르기", selection: Binding(
                                        get: { model.jevPicks[row.id] ?? -1 },
                                        set: { model.jevPicks[row.id] = $0 < 0 ? nil : $0 })) {
                                        Text("안 바꿈").tag(-1)
                                        ForEach(row.options) { Text($0.label).tag($0.index) }
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    .fixedSize()
                                }
                                if !row.images.isEmpty {
                                    HStack(alignment: .top, spacing: 12) {
                                        ForEach(row.images.indices, id: \.self) { i in
                                            VStack {
                                                Text(row.labels[i]).font(.caption)
                                                Image(decorative: row.images[i], scale: 1)
                                                    .resizable()
                                                    .interpolation(i == 0 ? .high : .none)
                                                    .scaledToFit()
                                                    .frame(width: 156, height: 156)
                                                    .background(.white)
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(18)
            .frame(width: 720, height: 620)
        }
        .sheet(isPresented: $model.showJevSettings) {
            VStack(alignment: .leading, spacing: 14) {
                Text("JEV 연결 설정").font(.title2)
                Text("LLM Gateway API 키를 Mac 키체인에 저장합니다. 이전 도트메이커에 저장한 키도 사용할 수 있습니다.")
                SecureField("LLM Gateway API 키", text: $model.keyDraft)
                if !model.keyStatus.isEmpty { Text(model.keyStatus).foregroundStyle(.secondary) }
                HStack {
                    Button("닫기") { model.showJevSettings = false }
                    Spacer()
                    Button("키 저장") {
                        do {
                            try GatewayKey.save(model.keyDraft)
                            model.keyDraft = ""
                            model.keyStatus = "키체인에 저장했습니다."
                        } catch { model.keyStatus = error.localizedDescription }
                    }
                    .disabled(model.keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .padding(24)
            .frame(width: 440)
        }
        .onChange(of: model.showJevSettings) { _, visible in
            if !visible { model.keyDraft = ""; model.keyStatus = "" }
        }
        .onChange(of: model.settings) { _, _ in model.redot() }
    }

    private func screen(_ stage: Stage) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            let direct = stage == .dot && model.settings.method.samplesOriginal
            let faithful = direct && model.settings.method == .faithful
            let instruction = faithful ? "원본 한 장을 열면 선 굵기와 명암을 살려 투명 PNG 크기에 맞춥니다."
                : direct ? "원본에서 배경을 분리한 뒤 최종 격자 칸마다 색과 선을 바로 읽습니다."
                : stage.instruction
            Text(instruction).foregroundStyle(.secondary)
            controls(stage)
            if let original = model.original {
                HStack(spacing: 12) {
                    preview(direct ? "원본" : "축소 이미지",
                            image: direct ? original : model.reduced,
                            pixelated: !direct)
                    preview("결과", image: model.result(for: stage), pixelated: true)
                }
            } else {
                ContentUnavailableView("원본 이미지를 여기에 놓으십시오", systemImage: "photo",
                                       description: Text("PNG, JPEG, WebP 등 이미지 파일"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if stage == .dot, let status = model.colorStatus {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
            if let busy = model.busy {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(busy)
                }
                .font(.callout)
            } else if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            } else if stage == .dot, let status = model.dotStatus {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func controls(_ stage: Stage) -> some View {
        Group {
            switch stage {
            case .dot:
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 16) {
                        Picker("결과 크기", selection: $model.size) {
                            ForEach(DotMakerModel.sizes, id: \.self) { Text("\($0)×\($0)").tag($0) }
                        }
                        .fixedSize()
                        Picker("AI 업스케일", selection: $model.settings.upscale) {
                            ForEach(UpscaleMode.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 330)
                        .help("도트화하기 전에 원본을 AI(Real-ESRGAN)로 4배 키워 흐린 선과 잡티를 정리합니다. 자동은 원본이 결과 크기의 4배보다 작을 때만 켭니다. 6B는 더 깔끔하고, v3는 더 빠릅니다.")
                    }
                    Picker("도트화 방식", selection: $model.settings.method) {
                        ForEach(DotMethod.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 470)
                    if model.settings.method == .faithful {
                        HStack {
                            Button("JEV 부위별 진단", action: model.diagnoseDetails)
                                .disabled(model.original == nil)
                            Button("JEV 섞인 색 판정", action: model.judgeBlends)
                                .disabled(model.original == nil)
                            Button("JEV 선·색 비교", action: model.judgeFaithful)
                                .disabled(model.original == nil)
                            Button("JEV 설정") { model.showJevSettings = true }
                            if model.colorStatus != nil {
                                Button("비교 전으로", action: model.resetFaithful)
                            }
                        }
                        HStack(spacing: 16) {
                            Toggle("바깥 외곽선 1픽셀 검정", isOn: $model.settings.crispOutline)
                            Toggle("경계 섞인 색 정리", isOn: $model.settings.cleanBlends)
                            Toggle("작은 입선 보존", isOn: $model.settings.preserveMouth)
                        }
                        Text("JEV를 실행하면 배경을 분리한 원본과 후보를 LLM Gateway로 보냅니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Group {
                            HStack(spacing: 12) {
                                Stepper("최대 \(model.settings.colors)색", value: $model.settings.colors, in: 6...32)
                                    .fixedSize()
                                Picker("색 정리", selection: $model.settings.cleanup) {
                                    Text("끄기").tag(0)
                                    Text("보통").tag(1)
                                    Text("강하게").tag(2)
                                }
                                .frame(width: 180)
                                .disabled(model.settings.method == .berry)
                                Spacer()
                                Button("JEV 자동 선택", action: model.optimizeColors)
                                Button("JEV 설정") { model.showJevSettings = true }
                            }
                            Text("JEV 실행 시 원본과 후보 이미지를 LLM Gateway로 전송합니다.")
                                .font(.caption).foregroundStyle(.secondary)
                            Picker("검은 외곽선", selection: $model.settings.width) {
                                Text("1줄").tag(1)
                                Text("2줄").tag(2)
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 245)
                            HStack(spacing: 12) {
                                Toggle("몸통 경계색", isOn: $model.settings.boundary)
                                Stepper("투명도 \(model.settings.transparency)%", value: $model.settings.transparency,
                                        in: 0...100, step: 5)
                                    .fixedSize()
                                    .disabled(!model.settings.boundary)
                            }
                        }
                        .disabled(model.original == nil)
                    }
                }
            }
        }
        .disabled(model.busy != nil)
    }

    private func preview(_ title: String, image: CGImage?, pixelated: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if let image {
                    Text("\(image.width) × \(image.height) px")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            ZStack {
                Canvas { context, size in
                    let cell = 12.0
                    for row in 0..<Int(ceil(size.height / cell)) {
                        for column in 0..<Int(ceil(size.width / cell)) where (row + column).isMultiple(of: 2) {
                            let tile = CGRect(x: Double(column) * cell, y: Double(row) * cell, width: cell, height: cell)
                            context.fill(Path(tile), with: .color(.gray.opacity(0.19)))
                        }
                    }
                }
                .background(.gray.opacity(0.08))
                if let image {
                    Image(decorative: image, scale: 1)
                        .interpolation(pixelated ? .none : .high)
                        .resizable()
                        .scaledToFit()
                        .padding(15)
                }
            }
            .clipShape(.rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.gray.opacity(0.24)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
