import COnnxRuntime
import CoreGraphics
import Foundation

/// 선 추출 AI(p1atdev/MangaLineExtraction-hf, MIT): 원본에서 구조선을 읽어 도트에서 끊기거나 빠진 안쪽 선을 채운다.
/// 윈도우판과 같은 구조(lines-graph.onnx)를 쓰고, 가중치(약 82MB)는 처음 한 번 받아 Float32로 풀어 둔다.
enum LinesAI {
    private static let url = URL(string: "https://huggingface.co/p1atdev/MangaLineExtraction-hf/resolve/3c815256f6f9be1ead162e8caaee63b489731d00/model.safetensors")!
    private static let downloadSize = 86_354_074
    private static let lock = NSLock()
    nonisolated(unsafe) private static var session: OpaquePointer?
    nonisolated(unsafe) private static var env: OpaquePointer?

    private static var api: OrtApi { OrtGetApiBase().pointee.GetApi(UInt32(ORT_API_VERSION))!.pointee }
    private static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DotMaker/lines", isDirectory: true)
    }

    private static func check(_ status: OpaquePointer?) throws {
        guard let status else { return }
        let message = api.GetErrorMessage(status).map { String(cString: $0) } ?? "알 수 없는 오류"
        api.ReleaseStatus(status)
        throw DotError.lines(message)
    }

    /// 구조(앱에 들어 있음)와 Float32 가중치(weights.bin)를 한 폴더에 두고 연다. 가중치가 없으면 받아서 만든다.
    private static func loadSession(progress: @escaping @Sendable (String) -> Void) async throws -> OpaquePointer {
        if let session = lock.withLock({ session }) { return session }
        let fm = FileManager.default
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let graph = folder.appendingPathComponent("lines-graph.onnx"), weights = folder.appendingPathComponent("weights.bin")
        guard let bundled = Bundle.main.url(forResource: "lines-graph", withExtension: "onnx"),
              let manifestURL = Bundle.main.url(forResource: "lines-manifest", withExtension: "json") else {
            throw DotError.lines("선 추출 모델 구조 파일을 찾지 못했습니다.")
        }
        if !fm.fileExists(atPath: graph.path) || (try? Data(contentsOf: graph)) != (try? Data(contentsOf: bundled)) {
            try? fm.removeItem(at: graph)
            try fm.copyItem(at: bundled, to: graph)
        }
        if !fm.fileExists(atPath: weights.path) {
            progress("선 추출 AI 모델 받는 중 (처음 한 번, 약 82MB)")
            let (file, response) = try await URLSession.shared.download(from: url)
            defer { try? fm.removeItem(at: file) }
            let data = try Data(contentsOf: file)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count == downloadSize else {
                throw DotError.lines("선 추출 AI 모델을 받지 못했습니다. 인터넷 연결을 확인해 주세요.")
            }
            progress("선 추출 AI 모델 준비 중")
            let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [[Any]] ?? []
            try convert(safetensors: data, manifest: manifest).write(to: weights, options: .atomic)
        }
        return try lock.withLock {
            if let session { return session }
            if env == nil { try check(api.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "DotMakerLines", &env)) }
            var options: OpaquePointer?, created: OpaquePointer?
            try check(api.CreateSessionOptions(&options))
            defer { api.ReleaseSessionOptions(options) }
            try check(api.CreateSession(env, graph.path, options, &created))
            session = created
            return created!
        }
    }

    /// safetensors(BF16) → 목록 순서대로 이어 붙인 Float32. BF16은 Float32의 위쪽 16비트라 16비트 밀어 올리면 같은 값이다.
    private static func convert(safetensors data: Data, manifest: [[Any]]) throws -> Data {
        let headerLength = Int(data.prefix(8).withUnsafeBytes { $0.loadUnaligned(as: UInt64.self) })
        guard let header = try JSONSerialization.jsonObject(with: data.subdata(in: 8..<(8 + headerLength))) as? [String: Any],
              let last = manifest.last, let lastOffset = last[1] as? Int, let lastCount = last[2] as? Int else {
            throw DotError.lines("선 추출 AI 모델 파일이 예상과 다릅니다.")
        }
        let start = 8 + headerLength
        var out = [UInt32](repeating: 0, count: (lastOffset + lastCount * 4) / 4)
        try data.withUnsafeBytes { raw in
            for entry in manifest {
                guard let key = entry[0] as? String, let offset = entry[1] as? Int, let count = entry[2] as? Int,
                      let info = header[key] as? [String: Any], info["dtype"] as? String == "BF16",
                      let range = info["data_offsets"] as? [Int] else {
                    throw DotError.lines("선 추출 AI 모델 파일이 예상과 다릅니다.")
                }
                let base = start + range[0], first = offset / 4
                for k in 0..<count {
                    out[first + k] = UInt32(raw.loadUnaligned(fromByteOffset: base + k * 2, as: UInt16.self)) << 16
                }
            }
        }
        return out.withUnsafeBytes { Data($0) }
    }

    /// 캐릭터(subject)의 구조선 지도: 흰 바탕에 검은 선, 캐릭터와 같은 크기(윈도우판 extractLines와 같은 입력·출력).
    static func extract(_ subject: Raster, progress: @escaping @Sendable (String) -> Void) async throws -> Raster {
        let session = try await loadSession(progress: progress)
        progress("선 추출 AI가 원본의 선을 읽는 중")
        let w = subject.grid.w, h = subject.grid.h
        let pw = (w + 15) / 16 * 16, ph = (h + 15) / 16 * 16
        var input = [Float](repeating: 255, count: pw * ph)
        for y in 0..<h {
            for x in 0..<w {
                let p = subject.pixels[y * w + x], pct = Int(p.a) * 100 / 255
                func white(_ c: UInt8) -> Int { (255 * (100 - pct) + Int(c) * pct + 50) / 100 }
                // 흰 바탕에 얹은 뒤 PIL 'L' 변환과 같은 회색
                input[y * pw + x] = Float((white(p.r) * 19595 + white(p.g) * 38470 + white(p.b) * 7471 + 0x8000) >> 16)
            }
        }
        try Task.checkCancellation()
        var memory: OpaquePointer?
        try check(api.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory))
        defer { api.ReleaseMemoryInfo(memory) }
        var shape: [Int64] = [1, 1, Int64(ph), Int64(pw)]
        var tensor: OpaquePointer?, output: OpaquePointer?
        try input.withUnsafeMutableBytes { buffer in
            try check(api.CreateTensorWithDataAsOrtValue(memory, buffer.baseAddress, buffer.count, &shape, 4,
                                                         ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &tensor))
            defer { api.ReleaseValue(tensor) }
            var inputs: [OpaquePointer?] = [tensor]
            try "image".withCString { inputName in
                try "lines".withCString { outputName in
                    var inNames: [UnsafePointer<CChar>?] = [inputName]
                    var outNames: [UnsafePointer<CChar>?] = [outputName]
                    try check(api.Run(session, nil, &inNames, &inputs, 1, &outNames, 1, &output))
                }
            }
        }
        defer { api.ReleaseValue(output) }
        var raw: UnsafeMutableRawPointer?
        try check(api.GetTensorMutableData(output, &raw))
        let values = raw!.assumingMemoryBound(to: Float.self)
        var lines = Raster(w: w, h: h)
        for y in 0..<h {
            for x in 0..<w {
                let v = UInt8(Int(min(255, max(0, values[y * pw + x]))))
                lines.pixels[y * w + x] = Pixel(v, v, v)
            }
        }
        return lines
    }
}

/// 선 지도로 도트에서 끊기거나 빠진 안쪽 선만 채운다(윈도우판 LineGuide와 같음).
enum LineGuide {
    static func apply(_ raster: inout Raster, mask: [Bool], outline: [Bool], width: Int, lines: Raster) {
        let grid = raster.grid
        guard let coverage = sampleLines(lines, mask: mask, grid: grid) else { return }
        let depth = grid.depths(mask)
        var inkOrder: [Int] = [], inkVotes: [Int: (Int, Pixel)] = [:]
        for i in mask.indices where mask[i] && !outline[i] && LineCleanup.isInk(raster.pixels[i]) {
            let p = raster.pixels[i], k = Int(p.r) << 16 | Int(p.g) << 8 | Int(p.b)
            if inkVotes[k] == nil { inkOrder.append(k); inkVotes[k] = (0, p) }
            inkVotes[k]!.0 += 1
        }
        var best: (Int, Pixel)?
        for k in inkOrder where best == nil || inkVotes[k]!.0 > best!.0 { best = inkVotes[k] }
        let lineColor = best?.1 ?? .black
        let inner = mask.indices.map { mask[$0] && !outline[$0] && depth[$0] > width + 2 }
        let before = raster.pixels
        var skeleton = mask.indices.map { inner[$0] && coverage[$0] >= 0.35 }
        LineCleanup.skeletonize(&skeleton, grid: grid)
        let hadInk = mask.indices.map { mask[$0] && (outline[$0] || LineCleanup.isInk(raster.pixels[$0])) }
        var added = [Bool](repeating: false, count: grid.count)
        for i in mask.indices where skeleton[i] && !hadInk[i] {
            var near = false
            grid.each8(i) { if hadInk[$0] { near = true } }
            if !near { raster.pixels[i] = lineColor; added[i] = true }
        }
        var seen = [Bool](repeating: false, count: grid.count)
        for start in mask.indices where added[start] && !seen[start] {
            var piece = [start], touches = false, next = 0
            seen[start] = true
            while next < piece.count {
                grid.each8(piece[next]) { j in
                    if added[j] && !seen[j] { seen[j] = true; piece.append(j) } else if hadInk[j] { touches = true }
                }
                next += 1
            }
            if !touches && piece.count < 3 {
                for i in piece { raster.pixels[i] = before[i]; added[i] = false }
            }
        }
    }

    private static func sampleLines(_ lines: Raster, mask: [Bool], grid: Grid) -> [Double]? {
        var x0 = Int.max, y0 = Int.max, x1 = -1, y1 = -1
        for i in mask.indices where mask[i] {
            let x = i % grid.w, y = i / grid.w
            x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
        }
        guard x1 >= 0, let image = try? lines.image() else { return nil }
        let bw = x1 - x0 + 1, bh = y1 - y0 + 1, factor = 4
        guard let scaled = try? Raster(image, width: bw * factor, height: bh * factor) else { return nil }
        var coverage = [Double](repeating: 0, count: grid.count)
        for v in 0..<bh {
            for u in 0..<bw {
                var dark = 0
                for sy in 0..<factor {
                    for sx in 0..<factor where scaled.pixels[(v * factor + sy) * scaled.grid.w + u * factor + sx].light < 128 { dark += 1 }
                }
                coverage[(v + y0) * grid.w + u + x0] = Double(dark) / Double(factor * factor)
            }
        }
        return coverage
    }
}
