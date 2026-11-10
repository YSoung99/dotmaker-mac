import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum Stage: String, CaseIterable, Identifiable {
    case dot = "도트화"
    case repair = "AI 보정"
    case help = "설명서"

    var id: Self { self }
    var instruction: String {
        switch self {
        case .dot: "머리와 몸통을 구분해 검은 윤곽과 몸통 경계색을 적용합니다."
        case .repair: "클라우드 AI(PixelLab·Gemini·OpenAI)에 캐릭터를 보내 도트 그림으로 다시 그립니다. 쓰려면 그 서비스의 내 API 키가 필요합니다."
        case .help: ""
        }
    }
}

/// AI 보정 결과: ai = 받은 그림(또는 다듬기 전), final = 저장할 결과
struct CloudResult: Sendable {
    let ai: CGImage
    let final: CGImage
    let pixel: Bool
    let corrected: Bool
    let status: String
}

private struct Product: Sendable {
    let settings: DotSettings
    let original: CGImage
    let subject: Raster
    let reduced: Reduced
    let dotted: Dotted
    let reducedImage: CGImage
    let dottedImage: CGImage
    /// 선 추출 AI가 읽은 선 지도(캐릭터와 같은 크기). 켜지 않았으면 nil.
    let lines: Raster?

    init(original: CGImage, subject: Raster, size: Grid, settings: DotSettings,
         cachedReduction: Reduced? = nil, jevResult: Dotted? = nil, lines: Raster? = nil) throws {
        self.settings = settings
        self.original = original
        self.subject = subject
        self.lines = lines
        let guide = settings.aiLines ? lines : nil
        let direct = settings.method.samplesOriginal
        if let cachedReduction, cachedReduction.direct == direct, cachedReduction.image.grid.w == size.w,
           cachedReduction.image.grid.h == size.h {
            reduced = cachedReduction
        } else {
            reduced = try Reduced(subject: subject, w: size.w, h: size.h, direct: direct)
        }
        switch settings.method {
        case .faithful:
            var cleaned = settings.snapColors ? Dotting.snapColors(reduced.image, reduced: reduced, subject: subject) : reduced.image
            if settings.cleanBlends { cleaned = Dotting.cleanBlends(cleaned) }
            if settings.preserveMouth { FaceDetail.preserveMouth(&cleaned, source: reduced) }
            dotted = try jevResult ?? Dotting.preserve(image: settings.crispOutline
                ? Dotting.crispOutline(cleaned, cells: reduced.cells) : cleaned)
        case .soft:
            dotted = try SoftDot.render(subject: subject, w: size.w, h: size.h, settings: settings)
        case .berry:
            dotted = try LegacyDot.render(subject: subject, w: size.w, h: size.h, settings: settings, lines: guide)
        case .basic, .direct:
            dotted = try Dotting.render(reduced, settings: settings, lines: guide)
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
    static let sizes = Array(stride(from: 50, through: 200, by: 10))
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

    // ───────────── AI 보정(클라우드). 고른 서비스와 설정은 다음에도 기억한다.
    @Published var cloudProvider = CloudProvider(rawValue: UserDefaults.standard.string(forKey: "cloud.provider") ?? "") ?? .pixellab {
        didSet { UserDefaults.standard.set(cloudProvider.rawValue, forKey: "cloud.provider"); editingCloudKey = false }
    }
    /// PixelLab: 다시 그리기(redraw) / 다듬기(correct)
    @Published var cloudCorrecting = UserDefaults.standard.string(forKey: "cloud.mode") == "correct" {
        didSet { UserDefaults.standard.set(cloudCorrecting ? "correct" : "redraw", forKey: "cloud.mode") }
    }
    @Published var cloudFaithful = UserDefaults.standard.object(forKey: "cloud.faithful") as? Bool ?? true {
        didSet { UserDefaults.standard.set(cloudFaithful, forKey: "cloud.faithful") }
    }
    @Published var cloudStrength = UserDefaults.standard.object(forKey: "cloud.strength") as? Int ?? 300 {
        didSet { UserDefaults.standard.set(cloudStrength, forKey: "cloud.strength") }
    }
    @Published var cloudQuality = UserDefaults.standard.string(forKey: "cloud.quality") ?? "medium" {
        didSet { UserDefaults.standard.set(cloudQuality, forKey: "cloud.quality") }
    }
    /// 다듬기 강도 0~1(PixelLab 권장 0.1부터)
    @Published var cloudFix = UserDefaults.standard.object(forKey: "cloud.fix") as? Double ?? 0.1 {
        didSet { UserDefaults.standard.set(cloudFix, forKey: "cloud.fix") }
    }
    /// 따로 넣은 그림 — 있으면 도트화 탭 이미지 대신 이 그림을 보낸다.
    @Published private(set) var cloudInput: (image: CGImage, name: String)?
    @Published private(set) var cloudResult: CloudResult?
    @Published var editingCloudKey = false
    @Published var cloudKeyDraft = ""
    @Published private var keyVersion = 0
    var correcting: Bool { cloudProvider == .pixellab && cloudCorrecting }
    var savedCloudKey: String? { _ = keyVersion; return CloudKey.load(cloudProvider) }

    func saveCloudKey() {
        do { try CloudKey.save(cloudProvider, cloudKeyDraft) } catch { self.error = error.localizedDescription }
        cloudKeyDraft = ""
        editingCloudKey = false
        keyVersion += 1
    }

    func clearCloudKey() {
        CloudKey.clear(cloudProvider)
        keyVersion += 1
    }

    func chooseCloudInput() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.begin { [weak self] response in
            if response == .OK, let url = panel.url { self?.setCloudInput(url) }
        }
    }

    func setCloudInput(_ url: URL?) {
        cloudResult = nil
        guard let url else { cloudInput = nil; return }
        do { cloudInput = (try Raster.load(url, originalResolution: true), url.lastPathComponent) } catch {
            self.error = error.localizedDescription
        }
    }

    private func confirm(_ message: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = "AI 보정"
        alert.informativeText = message
        alert.addButton(withTitle: "계속")
        alert.addButton(withTitle: "취소")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func runCloud() {
        guard busy == nil, product != nil || cloudInput != nil, let key = savedCloudKey else { return }
        if correcting { return runCorrect(key) }
        guard let (w, h) = product.map({ ($0.dottedImage.width, $0.dottedImage.height) }) ?? dimensions() else { return }
        let provider = cloudProvider, input = cloudInput, product = product
        guard confirm("\(input.map { "넣은 그림 '\($0.name)'" } ?? "캐릭터 그림")을(를) \(provider.name)(\(provider.host))로 보내 AI 보정을 합니다.\n요금: 1장 \(provider.price) (내 API 키 계정에 청구)\n\n계속할까요?") else { return }
        cloudResult = nil
        let options = CloudOptions(faithful: cloudFaithful, strength: cloudStrength, quality: cloudQuality)
        let settings = self.settings, report = report
        run("\(provider.name)가 그리는 중 (보통 몇 초~1분)", work: {
            let subject = try input?.image ?? product!.subject.image()
            let painted = try await Cloud.paint(provider, key: key, subject: subject, size: (w, h), options: options)
            let cost = painted.cost.map { String(format: " · 이번 요금 $%.4f", $0) } ?? ""
            if painted.pixel {
                // AI 도트 그림은 배경만 지운다.
                var raster = try Raster(painted.image)
                _ = try Subject.removePaleBackdrop(&raster)
                return CloudResult(ai: painted.image, final: try raster.image(), pixel: true, corrected: false,
                                   status: "\(provider.name) · AI 도트 그림 · 배경 지움 · \(raster.grid.w)×\(raster.grid.h)\(cost)")
            }
            // 도트 느낌의 큰 그림은 지금 도트화 설정으로 한 번 더 도트화한다(AI 업스케일 설정도 따른다).
            let model = Upscaler.model(for: painted.image, mode: settings.upscale, target: max(w, h))
            var source = painted.image, used: String?
            if let model {
                do { source = try Upscaler.upscale(painted.image, model: model); used = model } catch is CancellationError { throw CancellationError() } catch {}
            }
            let extracted = try Subject.extract(source, preserveTransparentArt: settings.method == .faithful)
            let lines = try await Self.lines(for: [settings], subject: extracted, existing: nil, report: report)
            let done = try Product(original: painted.image, subject: extracted, size: Grid(w: w, h: h), settings: settings, lines: lines)
            return CloudResult(ai: painted.image, final: done.dottedImage, pixel: false, corrected: false,
                               status: "\(provider.name) · AI 그림을 도트화 · \(Self.describe(done, upscaled: used))\(cost)")
        }) { self.cloudResult = $0 }
    }

    /// PixelLab 다듬기: 지금 도트화 결과(또는 넣은 그림)를 크기 그대로 보내 정리받는다.
    private func runCorrect(_ key: String) {
        guard let before = cloudInput?.image ?? product?.dottedImage else { return }
        guard before.width * before.height <= 1024 * 1024 else {
            error = "PixelLab 다듬기는 1024×1024 넓이까지입니다. 더 작은 도트 그림을 넣어 주세요."
            return
        }
        let strength = cloudFix
        guard confirm("\(cloudInput.map { "넣은 그림 '\($0.name)'" } ?? "지금 도트화 결과")(\(before.width)×\(before.height))를 PixelLab(api.pixellab.ai)로 보내 다듬기를 합니다.\n요금: PixelLab이 정하며 결과에 표시됩니다 (내 API 키 계정에 청구)\n\n계속할까요?") else { return }
        cloudResult = nil
        run(String(format: "PixelLab이 다듬는 중 (강도 %.2f)", strength), work: {
            let corrected = try await Cloud.correct(key: key, picture: before, strength: strength)
            let cost = corrected.cost.map { String(format: " · 이번 요금 $%.4f", $0) } ?? ""
            return CloudResult(ai: before, final: corrected.image, pixel: true, corrected: true,
                               status: String(format: "PixelLab 다듬기 · 강도 %.2f · ", strength)
                                   + "\(corrected.image.width)×\(corrected.image.height)\(cost)")
        }) { self.cloudResult = $0 }
    }

    var original: CGImage? { product?.original }
    var dotted: CGImage? { product?.dottedImage }
    var reduced: CGImage? { product?.reducedImage }
    var result: CGImage? { result(for: stage) }

    func result(for stage: Stage) -> CGImage? {
        switch stage {
        case .dot: dotted
        case .repair: cloudResult?.final
        case .help: nil
        }
    }
    var dotStatus: String? {
        guard let product else { return nil }
        return Self.describe(product, upscaled: prepared?.model)
    }

    /// 상태줄 문구(윈도우판 dotStatus와 같음)
    nonisolated fileprivate static func describe(_ product: Product, upscaled: String?) -> String {
        let s = product.settings, dotted = product.dotted
        let sharpened = upscaled.map { " · AI 업스케일 \(Upscaler.label($0))" } ?? ""
        switch s.method {
        case .faithful:
            let extras = [s.snapColors ? "원본 색 맞추기" : nil, s.cleanBlends ? "경계 섞인 색 정리" : nil,
                          s.preserveMouth ? "작은 입선 보존" : nil, s.crispOutline ? "바깥 외곽선 원본 선 색" : nil].compactMap { $0 }
            return "원본 보존  ·  \(product.dottedImage.width)×\(product.dottedImage.height) px  ·  투명 PNG"
                + (extras.isEmpty ? "" : "  ·  " + extras.joined(separator: " · ")) + sharpened
        case .soft:
            return SoftDot.status(s, dotted) + sharpened
        case .berry, .direct:
            return "\(s.method.rawValue)  ·  실제 \(ColorReducer.count(dotted.image))색" + sharpened
        case .basic:
            let head = dotted.headCount > 0 ? "분홍 머리 영역 감지" : "분홍 머리 영역 미감지"
            let body = dotted.bodyCount > 0 ? "밝은 몸통 영역 감지" : "밝은 몸통 영역 미감지"
            return "\(head)  ·  \(body)  ·  실제 \(ColorReducer.count(dotted.image))색" + sharpened
        }
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

    /// 선 추출 AI가 필요한 설정이면 선 지도를 만든다(있던 지도는 다시 쓴다). 베리 잉크·2.0 방식·원본 직행에서만 쓴다.
    nonisolated private static func lines(for options: [DotSettings], subject: Raster, existing: Raster?,
                                          report: @escaping @Sendable (String) -> Void) async throws -> Raster? {
        guard options.contains(where: { $0.aiLines && [.berry, .basic, .direct].contains($0.method) }) else { return existing }
        if let existing { return existing }
        return try await LinesAI.extract(subject, progress: report)
    }

    /// 작업 중 진행 문구(모델 받기 등)를 화면에 보인다.
    private var report: @Sendable (String) -> Void {
        { [weak self] text in Task { @MainActor in if self?.busy != nil { self?.busy = text } } }
    }

    func open(_ url: URL) {
        guard let (w, h) = dimensions() else { return }
        let options = settings, report = report
        run("원본에서 캐릭터 분리 중", work: {
            let original = try Raster.load(url, originalResolution: true)
            let model = Upscaler.model(for: original, mode: options.upscale, target: max(w, h))
            let source = try model.map { try Upscaler.upscale(original, model: $0) } ?? original
            let subject = try Subject.extract(source, preserveTransparentArt: options.method == .faithful)
            let lines = try await Self.lines(for: [options], subject: subject, existing: nil, report: report)
            return (try Product(original: original, subject: subject, size: Grid(w: w, h: h), settings: options, lines: lines),
                    source, model)
        }) { product, source, model in
            self.product = product
            self.prepared = (source, model)
            self.file = url
            self.colorStatus = nil
        }
    }

    func resize() {
        guard let product, let (w, h) = dimensions() else { return }
        let options = settings, report = report
        colorStatus = nil
        let model = Upscaler.model(for: product.original, mode: options.upscale, target: max(w, h))
        let reuse = prepared?.model == model ? prepared : nil
        run(reuse == nil ? "AI가 원본을 4배로 키우는 중" : "캐릭터 축소 중", work: {
            let source = try reuse?.image ?? (model.map { try Upscaler.upscale(product.original, model: $0) } ?? product.original)
            let subject = reuse != nil ? product.subject
                : try Subject.extract(source, preserveTransparentArt: options.method == .faithful)
            let lines = try await Self.lines(for: [options], subject: subject, existing: reuse != nil ? product.lines : nil, report: report)
            return (try Product(original: product.original, subject: subject, size: Grid(w: w, h: h), settings: options, lines: lines),
                    source, model)
        }) { product, source, model in
            self.product = product
            self.prepared = (source, model)
        }
    }

    func redot() {
        guard let product, product.settings != settings else { return }
        let options = settings, report = report
        colorStatus = nil
        let faithful = options.method == .faithful
        let model = Upscaler.model(for: product.original, mode: options.upscale, target: product.reduced.image.grid.w)
        let reuse = prepared?.model == model ? prepared : nil
        let sameSubject = reuse != nil && faithful == (product.settings.method == .faithful)
        run(reuse == nil ? "AI가 원본을 4배로 키우는 중" : faithful ? "원본의 선과 색을 맞추는 중" : "외곽선 정리 중", work: {
            let source = try reuse?.image ?? (model.map { try Upscaler.upscale(product.original, model: $0) } ?? product.original)
            let subject = sameSubject ? product.subject
                : try Subject.extract(source, preserveTransparentArt: faithful)
            let lines = try await Self.lines(for: [options], subject: subject, existing: sameSubject ? product.lines : nil, report: report)
            return (try Product(original: product.original, subject: subject, size: product.reduced.image.grid,
                                settings: options, cachedReduction: sameSubject ? product.reduced : nil, lines: lines), source, model)
        }) { product, source, model in
            self.product = product
            self.prepared = (source, model)
        }
    }

    func optimizeColors() {
        guard let product, busy == nil, settings.method != .faithful else { return }
        let options = JevColors.variants(settings), report = report
        run("JEV가 도트화 후보를 나란히 비교 중", work: {
            let key = try GatewayKey.load()
            let lines = try await Self.lines(for: options, subject: product.subject, existing: product.lines, report: report)
            let candidates = try options.map {
                try Product(original: product.original, subject: product.subject,
                            size: product.reduced.image.grid, settings: $0, cachedReduction: product.reduced, lines: lines)
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
                                     settings: product.settings, cachedReduction: product.reduced, jevResult: fill.dotted,
                                     lines: product.lines)
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
                                       jevResult: Dotting.preserve(image: applied), lines: product.lines)
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
                                       settings: product.settings, cachedReduction: product.reduced, lines: product.lines)
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

            Picker("단계", selection: $model.stage) {
                ForEach(Stage.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 330)
            .padding(.horizontal, 20)
            .frame(maxWidth: .infinity, alignment: .leading)

            Group {
                switch model.stage {
                case .dot: screen(.dot)
                case .repair: repairScreen()
                case .help: HelpView()
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 16)
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let first = urls.first, first.isFileURL else { return false }
            // AI 보정 탭에 끌어다 놓으면 보낼 그림으로 넣는다.
            if model.stage == .repair { model.setCloudInput(first) } else { model.open(first) }
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
            let faithful = model.settings.method == .faithful
            let direct = faithful
            let instruction = faithful ? "원본 한 장을 열면 선 굵기와 명암을 살려 투명 PNG 크기에 맞춥니다. 원본에서 바로 격자 칸마다 색을 읽습니다."
                : model.settings.method == .soft
                ? "원본의 색을 살리고 색 수만 줄여 도트로 바꿉니다. 선은 원본에서 줄기를 찾아 1픽셀로 정리하고, 색은 조금 더 선명하게, 바깥 테두리와 색 면은 깔끔하게 정리합니다."
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
                    .frame(width: 560)
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
                                Button("적용 전으로", action: model.resetFaithful)
                            }
                        }
                        HStack(spacing: 16) {
                            Toggle("바깥 외곽선 1픽셀(원본 선 색)", isOn: $model.settings.crispOutline)
                                .help("투명 배경 바로 앞 가장 바깥 칸만, 원본 그 자리에 선이 있으면 원본 선 색으로 칠합니다. 흰 외곽선 장식과 바닥 그림자는 그대로 둡니다.")
                            Toggle("원본 색 맞추기", isOn: $model.settings.snapColors)
                                .help("축소하면서 생긴 탁한 중간색 대신, 그 칸 원본에 실제로 있는 가장 가까운 색을 넣습니다.")
                            Toggle("경계 섞인 색 정리", isOn: $model.settings.cleanBlends)
                            Toggle("작은 입선 보존", isOn: $model.settings.preserveMouth)
                        }
                        Text("JEV를 실행하면 배경을 분리한 원본과 후보를 LLM Gateway로 보냅니다.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Group {
                            let soft = model.settings.method == .soft
                            if soft {
                                HStack(spacing: 16) {
                                    Toggle("선 1픽셀로 정리", isOn: $model.settings.softLines)
                                        .help("큰 원본에서 선의 가운데 줄기를 찾아 그 줄기가 지나는 칸만 선으로 칠합니다. 선이 끊기거나 뭉치지 않고 입(ω) 같은 작은 모양이 살아납니다. 원본이 굵은 선 그림이면 꺼 보세요.")
                                    Toggle("선명하게", isOn: $model.settings.softVivid)
                                        .help("분홍·보라 같은 색의 채도를 25% 올려 또렷하게 합니다. 흰색·검정·회색은 그대로입니다.")
                                    Toggle("테두리·색 면 정리", isOn: $model.settings.softClean)
                                        .help("바깥 테두리를 끊김 없는 순검정 1px로 잇고, 거의 같은 색을 합치고 혼자 떨어진 점을 지웁니다.")
                                }
                            }
                            HStack(spacing: 12) {
                                if soft {
                                    Stepper("최대 \(model.settings.softColors)색", value: $model.settings.softColors, in: 4...64, step: 2)
                                        .fixedSize()
                                } else {
                                    Stepper("최대 \(model.settings.colors)색", value: $model.settings.colors, in: 6...32)
                                        .fixedSize()
                                }
                                Picker("색 정리", selection: $model.settings.cleanup) {
                                    Text("끄기").tag(0)
                                    Text("보통").tag(1)
                                    Text("강하게").tag(2)
                                }
                                .frame(width: 180)
                                .disabled(model.settings.method != .basic && model.settings.method != .direct)
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
                            .disabled(soft)
                            HStack(spacing: 12) {
                                Toggle("몸통 경계색", isOn: $model.settings.boundary)
                                Stepper("투명도 \(model.settings.transparency)%", value: $model.settings.transparency,
                                        in: 0...100, step: 5)
                                    .fixedSize()
                                    .disabled(!model.settings.boundary)
                            }
                            .disabled(soft)
                            Toggle("선 추출 AI로 빠진 선 채우기", isOn: $model.settings.aiLines)
                                .help("MangaLineExtraction으로 원본의 구조선을 읽어, 도트에서 끊기거나 빠진 안쪽 선만 채웁니다. 처음 한 번 모델(약 82MB)을 받습니다.")
                                .disabled(soft)
                            if soft {
                                Text("원본 색 살림: 원본의 색을 살리고 색 수만 줄입니다. 외곽선·선 추출·경계색은 베리 잉크·2.0 방식·원본 직행에서 씁니다.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        .disabled(model.original == nil)
                    }
                }
            case .repair, .help:
                EmptyView()
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

// ───────────── AI 보정 탭(클라우드)
extension ContentView {
    @ViewBuilder
    func repairScreen() -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Stage.repair.instruction).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                Picker("AI 서비스", selection: $model.cloudProvider) {
                    ForEach(CloudProvider.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                Text(model.cloudProvider.detail).foregroundStyle(.secondary)
            }
            cloudKeyRow()
            cloudOptions()
            HStack(spacing: 12) {
                Picker("AI 업스케일", selection: $model.settings.upscale) {
                    ForEach(UpscaleMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 330)
                Text("다시 그린 그림을 도트화하기 전에 적용됩니다(받은 그림이 이미 도트 그림이면 쓰지 않음)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 10) {
                Text("보낼 그림:")
                Text(model.cloudInput.map { "넣은 그림 '\($0.name)' (\($0.image.width)×\($0.image.height))" }
                     ?? (model.original == nil ? "없음 — 이미지를 넣거나 열어 주세요"
                         : model.correcting ? "지금 도트화 결과" : "도트화 탭에서 연 이미지의 캐릭터"))
                    .foregroundStyle(.secondary)
                Button("다른 이미지 넣기…", action: model.chooseCloudInput)
                if model.cloudInput != nil { Button("넣은 그림 빼기") { model.setCloudInput(nil) } }
                Text("이 탭에 이미지를 끌어다 놓아도 됩니다").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Button("AI 보정 실행", action: model.runCloud)
                    .buttonStyle(.borderedProminent)
                    .disabled(model.savedCloudKey == nil || (model.original == nil && model.cloudInput == nil))
                Text(model.correcting
                     ? "실행하면 보낼 그림이 \(model.cloudProvider.host)로 전송되고 요금이 듭니다(결과에 표시, 내 키 계정에 청구). 키는 맥 키체인에만 저장됩니다."
                     : "실행하면 보낼 그림이 \(model.cloudProvider.host)로 전송되고 1장에 \(model.cloudProvider.price) 요금이 듭니다(내 키 계정에 청구). 키는 맥 키체인에만 저장됩니다.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if model.original != nil || model.cloudInput != nil {
                HStack(spacing: 12) {
                    if let r = model.cloudResult {
                        preview(r.corrected ? "다듬기 전" : r.pixel ? "AI 도트 그림" : "AI가 그린 그림", image: r.ai, pixelated: r.pixel)
                    } else {
                        preview(model.cloudInput.map { "보낼 그림 · \($0.name)" } ?? "보낼 그림 · 지금 도트화 결과",
                                image: model.cloudInput?.image ?? model.dotted, pixelated: true)
                    }
                    preview("결과", image: model.cloudResult?.final, pixelated: true)
                }
            } else {
                ContentUnavailableView("원본 이미지를 여기에 놓으십시오", systemImage: "photo",
                                       description: Text("도트화 탭에서 이미지를 열거나, 이 탭에 다른 이미지를 넣어 주세요"))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if let busy = model.busy {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(busy) }.font(.callout)
            } else if let error = model.error {
                Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled)
            } else if let status = model.cloudResult?.status {
                Text(status).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .disabled(model.busy != nil)
    }

    @ViewBuilder
    private func cloudKeyRow() -> some View {
        let provider = model.cloudProvider
        if let key = model.savedCloudKey, !model.editingCloudKey {
            HStack(spacing: 10) {
                Text("\(provider.name) API 키 저장됨 (…\(String(key.suffix(4))))")
                Button("키 바꾸기") { model.editingCloudKey = true }
                Button("키 지우기", action: model.clearCloudKey)
            }
        } else {
            HStack(spacing: 10) {
                SecureField(provider.keyHint, text: $model.cloudKeyDraft)
                    .frame(width: 320)
                    .onSubmit(model.saveCloudKey)
                Button("키 저장", action: model.saveCloudKey)
                if model.editingCloudKey { Button("취소") { model.editingCloudKey = false } }
                Link("키 발급 페이지 ↗", destination: provider.keyPage)
            }
        }
    }

    @ViewBuilder
    private func cloudOptions() -> some View {
        switch model.cloudProvider {
        case .pixellab:
            HStack(spacing: 12) {
                Picker("PixelLab 방식", selection: $model.cloudCorrecting) {
                    Text("다시 그리기").tag(false)
                    Text("다듬기").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
                Text(model.cloudCorrecting ? "지금 도트화 결과를 크기 그대로 보내 잔점·계단 가장자리·색을 정리합니다"
                     : "캐릭터 원본을 보내 지금 크기의 도트 그림으로 새로 그립니다").foregroundStyle(.secondary)
            }
            if model.cloudCorrecting {
                HStack(spacing: 12) {
                    Stepper(String(format: "다듬기 강도 %.2f", model.cloudFix), value: $model.cloudFix, in: 0...1, step: 0.05)
                        .fixedSize()
                    Text("낮을수록 잔점·가장자리만, 높을수록 많이 고쳐 그립니다(권장 0.1부터)").font(.caption).foregroundStyle(.secondary)
                }
            } else {
                HStack(spacing: 16) {
                    Toggle("원본에 충실하게", isOn: $model.cloudFaithful)
                        .help("PixelLab의 충실 모드(fixer). 끄면 AI가 도트 그림으로 새로 해석합니다.")
                    Stepper("원본 유지 \(model.cloudStrength)", value: $model.cloudStrength, in: 0...600, step: 50).fixedSize()
                }
            }
        case .openai:
            Picker("품질", selection: $model.cloudQuality) {
                Text("낮음(싸고 빠름)").tag("low")
                Text("보통").tag("medium")
            }
            .pickerStyle(.segmented)
            .frame(width: 280)
        case .gemini:
            EmptyView()
        }
    }
}

// ───────────── 설명서 탭
private struct HelpView: View {
    private struct Section: Identifiable {
        let title: String
        let items: [String]
        var id: String { title }
    }

    private let sections = [
        Section(title: "시작하기", items: [
            "**이미지 열기…** 버튼을 누르거나 이미지를 창에 끌어다 놓습니다. ⌘O",
            "**결과 크기**: 50×50 ~ 200×200(10px 단위)에서 고르면 바로 다시 그립니다. 배경은 자동으로 지우고 캐릭터를 캔버스에 맞춥니다.",
            "**도트화** 탭: 설정을 바꾸면 바로 다시 계산합니다.",
            "**PNG 저장…**: 지금 탭의 결과를 저장합니다. ⌘S · 저장 배율(1·2·4·8배)은 번짐 없이 키우고, 다음에도 기억합니다.",
        ]),
        Section(title: "도트화 설정", items: [
            "**AI 업스케일(ESRGAN)**: 도트화하기 전에 원본을 Real-ESRGAN으로 4배 키워 흐린 선과 잡티를 정리합니다. 자동은 원본이 결과 크기의 4배보다 작을 때만 켭니다. 6B는 더 깔끔하고, v3는 더 빠릅니다.",
            "**원본 보존**(기본): 원본 픽셀이 결과 격자 한 칸에 걸치는 넓이만큼 그대로 평균 내서, 선 굵기와 명암을 살린 투명 PNG를 만듭니다.",
            "**바깥 외곽선 1픽셀(원본 선 색)**(원본 보존): 투명 배경 바로 앞 가장 바깥 칸만, 원본 그 자리에 선이 있으면 원본 선 색으로 칠합니다. 흰 외곽선 장식과 발밑 그림자는 그대로 둡니다.",
            "**원본 색 맞추기**(원본 보존): 줄이면서 생긴 탁한 중간색 대신, 그 칸 원본에 실제로 있는 가장 가까운 색을 넣습니다.",
            "**경계 섞인 색 정리**(원본 보존): 경계에 생긴 탁한 중간색(빨강+검정 → 자주 등)을 가까운 원래 색으로 바꿉니다.",
            "**작은 입선 보존**(원본 보존): 눈 두 개 사이 아래의 작은 입 선(ω 등)이 회색으로 뭉개지지 않게 원본 선 색으로 살립니다.",
            "**원본 색 살림**: 원본의 선과 색을 살리고 색 수만 줄입니다(최대 4~64색, 기본 24색). 선 1픽셀로 정리 · 선명하게(채도 +25%) · 테두리·색 면 정리를 고릅니다.",
            "**베리 잉크**: 진한 잉크 윤곽과 베리 색감. **2.0 방식**: 머리·몸통을 구분하는 방식. **원본 직행**: 2.0 방식과 같은 그리기를 원본에서 바로 격자를 읽어 합니다(색 정리는 2.0 방식·원본 직행에서만).",
            "**최대 색**: 결과에 쓸 색 수(6~32). **검은 외곽선**: 바깥 테두리 1줄·2줄.",
            "**선 추출 AI로 빠진 선 채우기**: 원본의 선을 AI로 읽어 끊긴 안쪽 선을 채웁니다. 처음 한 번 모델(약 82MB)을 받습니다.",
            "**몸통 경계색**: 검은 테두리 바로 안쪽 흰 몸통에 중간색을 넣습니다. 투명도가 클수록 흰색에 가깝습니다.",
        ]),
        Section(title: "JEV 판정", items: [
            "**JEV 설정**에 LLM Gateway API 키를 넣습니다. 키는 맥 키체인에 보관됩니다.",
            "**JEV 부위별 진단**(원본 보존): 바깥 윤곽·안쪽 선, 머리색, 투명 테두리 띠, 바깥 외곽선, 빠진 디테일을 원본과 비교합니다.",
            "**JEV 섞인 색 판정**(원본 보존): 섞인 색이 몰린 곳을 골라 그대로·가까운 색·선 색 쪽 중 무엇이 나은지 봅니다.",
            "**JEV 선·색 비교**(원본 보존): 선 처리 후보를 먼저 고르고, 그 선으로 채색 후보(원본 채색·16색·32색)를 고릅니다.",
            "**JEV 자동 선택**(그 밖의 방식): 베리 잉크·2.0 방식 후보를 나란히 보여 주고 가장 나은 설정을 고릅니다.",
            "고른 결과는 **적용 전으로**로 되돌릴 수 있습니다. 판정할 때 원본과 후보 그림이 LLM Gateway로 전송되며, 요금은 내 키 계정에 청구됩니다.",
        ]),
        Section(title: "AI 보정 (클라우드)", items: [
            "**AI 보정** 탭에서 서비스를 고르고 **내 API 키**를 넣은 뒤 **AI 보정 실행**을 누릅니다. 지금 캔버스 크기로 결과가 나옵니다. **다른 이미지 넣기…**(또는 이 탭에 끌어다 놓기)로 원하는 그림을 보낼 수도 있습니다.",
            "**PixelLab · 다시 그리기**: 결과가 바로 도트 그림입니다(배경만 지움). '원본에 충실하게'와 '원본 유지'(0~600)로 조절합니다. 약 $0.01/장.",
            "**PixelLab · 다듬기**: 지금 도트화 결과를 크기 그대로 보내 잔점·계단 가장자리·색을 정리받습니다. 강도 0~1, 0.1부터 올려 보세요.",
            "**Gemini**(나노 바나나 2.1) · **OpenAI**(GPT Image 2.5): 도트 느낌의 큰 그림을 받아 지금 도트화 설정으로 한 번 더 도트화합니다.",
            "실행할 때마다 **캐릭터 그림이 그 서비스 서버로 전송**됩니다. 보내기 전에 받는 곳과 요금을 묻습니다. 키는 맥 키체인에만 저장되고 '키 지우기'로 지울 수 있습니다.",
        ]),
        Section(title: "AI 파일", items: [
            "배경 분리(anime-seg)와 AI 업스케일(Real-ESRGAN) 모델은 앱 안에 들어 있어 인터넷 없이 됩니다.",
            "선 추출 AI 모델은 처음 켤 때 한 번 받아 `~/Library/Application Support/DotMaker/lines`에 둡니다.",
        ]),
        Section(title: "문제 해결", items: [
            "**처음 열 때 '확인할 수 없는 개발자' 또는 '손상됨'**: 서명 없는 앱이라 그렇습니다. 터미널에서 `xattr -dr com.apple.quarantine \"/Applications/도트메이커 JEV 부위별 진단 시험.app\"`을 한 번 실행하세요.",
            "**JEV 연결 오류**: JEV 설정의 API 키와 LLM Gateway 잔액을 확인하세요. 처음 판정할 때 키체인 접근을 물으면 **항상 허용**을 누르세요.",
            "**캐릭터를 분리하지 못함**: 캐릭터 주위에 여백이 있는 원본이나 투명 PNG가 가장 잘 됩니다.",
        ]),
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                ForEach(sections) { section in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(section.title).font(.title3.bold())
                        ForEach(section.items, id: \.self) { item in
                            HStack(alignment: .top, spacing: 6) {
                                Text("•")
                                Text(LocalizedStringKey(item)).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
                let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
                Text("도트메이커 맥 앱 \(version) · 모델: skytnt/anime-seg (Apache-2.0), p1atdev/MangaLineExtraction-hf (MIT), Real-ESRGAN (BSD-3-Clause) · 실행 도구: ONNX Runtime (MIT)")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
