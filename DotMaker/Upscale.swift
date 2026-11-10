import COnnxRuntime
import CoreGraphics
import Foundation

/// AI 업스케일(ESRGAN): 도트화하기 전에 원본을 4배로 키워 흐린 선·잡티를 정리한다.
enum UpscaleMode: String, CaseIterable, Identifiable, Sendable {
    case auto = "자동"
    case strong = "6B"
    case light = "v3"
    case off = "끄기"

    var id: Self { self }
}

/// Real-ESRGAN(xinntao, BSD-3) 애니 모델 두 개를 ONNX Runtime으로 돌린다.
/// 자동: 원본 긴 변이 결과 크기의 4배보다 작을 때만 6B를 쓴다(큰 원본은 이미 깨끗해서 차이가 없다).
enum Upscaler {
    private static let tile = 160, pad = 10
    /// 직접 고른 경우에도 이보다 큰 원본은 먼저 줄인다(키워도 차이가 없고 시간만 든다).
    private static let maxSide = 1024
    private static let lock = NSLock()
    nonisolated(unsafe) private static var sessions: [String: OpaquePointer] = [:]
    nonisolated(unsafe) private static var env: OpaquePointer?

    private static var api: OrtApi { OrtGetApiBase().pointee.GetApi(UInt32(ORT_API_VERSION))!.pointee }

    private static func check(_ status: OpaquePointer?) throws {
        guard let status else { return }
        let message = api.GetErrorMessage(status).map { String(cString: $0) } ?? "알 수 없는 오류"
        api.ReleaseStatus(status)
        throw DotError.upscale(message)
    }

    /// 이 원본에 쓸 모델(파일 이름). nil이면 키우지 않는다.
    static func model(for image: CGImage, mode: UpscaleMode, target: Int) -> String? {
        switch mode {
        case .off: nil
        case .strong: "esrgan-anime-6b"
        case .light: "esrgan-animevideo-v3"
        case .auto: max(image.width, image.height) < target * 4 ? "esrgan-anime-6b" : nil
        }
    }

    static func label(_ model: String) -> String { model.hasSuffix("6b") ? "6B" : "v3" }

    private static func session(_ name: String) throws -> OpaquePointer {
        lock.lock(); defer { lock.unlock() }
        if let session = sessions[name] { return session }
        guard let url = Bundle.main.url(forResource: name, withExtension: "onnx") else {
            throw DotError.upscale("모델(\(name).onnx)을 찾지 못했습니다.")
        }
        if env == nil { try check(api.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "DotMakerUpscale", &env)) }
        var options: OpaquePointer?, created: OpaquePointer?
        try check(api.CreateSessionOptions(&options))
        defer { api.ReleaseSessionOptions(options) }
        try check(api.CreateSession(env, url.path, options, &created))
        sessions[name] = created
        return created!
    }

    /// 원본을 4배로 키운 그림. 투명한 부분은 가까운 그림 색으로 채워 돌리고, 투명도는 따로 부드럽게 키운다.
    static func upscale(_ source: CGImage, model: String) throws -> CGImage {
        var raster = try Raster(source)
        if max(raster.grid.w, raster.grid.h) > maxSide {
            let scale = Double(maxSide) / Double(max(raster.grid.w, raster.grid.h))
            raster = try Raster(source, width: max(1, Int(Double(raster.grid.w) * scale)),
                                height: max(1, Int(Double(raster.grid.h) * scale)))
        }
        let w = raster.grid.w, h = raster.grid.h
        let transparent = raster.pixels.contains { $0.a < 255 }
        let colors = transparent ? bleed(raster) : raster.pixels
        let session = try session(model)

        var rgb = [Float](repeating: 0, count: 3 * w * 4 * h * 4)
        let ow = w * 4, oh = h * 4
        for ty in stride(from: 0, to: h, by: tile) {
            for tx in stride(from: 0, to: w, by: tile) {
                try Task.checkCancellation()
                // 가장자리 이음새가 보이지 않게 둘레를 조금 더 넣어 돌리고 가운데만 쓴다.
                let x0 = max(0, tx - pad), y0 = max(0, ty - pad)
                let x1 = min(w, tx + tile + pad), y1 = min(h, ty + tile + pad)
                let tw = x1 - x0, th = y1 - y0
                var input = [Float](repeating: 0, count: 3 * tw * th)
                for y in 0..<th {
                    for x in 0..<tw {
                        let p = colors[(y + y0) * w + x + x0]
                        let i = y * tw + x
                        input[i] = Float(p.r) / 255
                        input[tw * th + i] = Float(p.g) / 255
                        input[2 * tw * th + i] = Float(p.b) / 255
                    }
                }
                let output = try run(session, input: &input, w: tw, h: th)
                let sx0 = (tx - x0) * 4, sy0 = (ty - y0) * 4
                let cw = (min(w, tx + tile) - tx) * 4, ch = (min(h, ty + tile) - ty) * 4
                let plane = tw * 4 * th * 4
                for y in 0..<ch {
                    for x in 0..<cw {
                        let s = (y + sy0) * tw * 4 + x + sx0, d = (ty * 4 + y) * ow + tx * 4 + x
                        for c in 0..<3 { rgb[c * ow * oh + d] = output[c * plane + s] }
                    }
                }
            }
        }

        let alpha = transparent ? try scaledAlpha(raster, width: ow, height: oh) : nil
        var result = Raster(w: ow, h: oh)
        for i in result.pixels.indices {
            func byte(_ c: Int) -> UInt8 { UInt8(max(0, min(1, rgb[c * ow * oh + i])) * 255 + 0.5) }
            result.pixels[i] = Pixel(byte(0), byte(1), byte(2), alpha?[i] ?? 255)
        }
        return try result.image()
    }

    private static func run(_ session: OpaquePointer, input: inout [Float], w: Int, h: Int) throws -> [Float] {
        var memory: OpaquePointer?
        try check(api.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory))
        defer { api.ReleaseMemoryInfo(memory) }
        var shape: [Int64] = [1, 3, Int64(h), Int64(w)]
        var tensor: OpaquePointer?, output: OpaquePointer?
        try input.withUnsafeMutableBytes { buffer in
            try check(api.CreateTensorWithDataAsOrtValue(memory, buffer.baseAddress, buffer.count, &shape, 4,
                                                         ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &tensor))
            defer { api.ReleaseValue(tensor) }
            var inputs: [OpaquePointer?] = [tensor]
            try "image".withCString { inputName in
                try "upscaled".withCString { outputName in
                    var inNames: [UnsafePointer<CChar>?] = [inputName]
                    var outNames: [UnsafePointer<CChar>?] = [outputName]
                    try check(api.Run(session, nil, &inNames, &inputs, 1, &outNames, 1, &output))
                }
            }
        }
        defer { api.ReleaseValue(output) }
        var raw: UnsafeMutableRawPointer?
        try check(api.GetTensorMutableData(output, &raw))
        return Array(UnsafeBufferPointer(start: raw!.assumingMemoryBound(to: Float.self), count: 3 * w * 4 * h * 4))
    }

    /// 투명한 픽셀에 가장 가까운 그림 픽셀의 색을 넣는다(배경색이 테두리로 번져 들지 않게).
    private static func bleed(_ raster: Raster) -> [Pixel] {
        let grid = raster.grid
        var colors = raster.pixels
        var filled = raster.pixels.map { $0.a >= 128 }
        var frontier = filled.indices.filter { filled[$0] }
        if frontier.isEmpty { return colors }
        var next = 0
        while next < frontier.count {
            let i = frontier[next]
            grid.each4(i) { j in
                if !filled[j] { filled[j] = true; colors[j] = Pixel(colors[i].r, colors[i].g, colors[i].b); frontier.append(j) }
            }
            next += 1
        }
        return colors
    }

    private static func scaledAlpha(_ raster: Raster, width: Int, height: Int) throws -> [UInt8] {
        var gray = raster.pixels.map(\.a)
        let w = raster.grid.w, h = raster.grid.h
        return try gray.withUnsafeMutableBytes { buffer -> [UInt8] in
            guard let small = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
                  let image = small.makeImage(),
                  let full = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
                                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { throw DotError.render }
            full.interpolationQuality = .high
            full.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return Array(UnsafeBufferPointer(start: full.data!.assumingMemoryBound(to: UInt8.self), count: width * height))
        }
    }
}
