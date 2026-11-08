import COnnxRuntime
import CoreGraphics
import Foundation

/// 배경 분리 AI: skytnt/anime-seg(isnetis.onnx, Apache-2.0)를 ONNX Runtime으로 돌린다.
/// 윈도우판도 같은 모델·같은 실행 엔진을 쓸 수 있게 맥 전용 Vision 대신 쓴다.
enum AnimeSeg {
    private static let side = 1024
    private static let lock = NSLock()
    nonisolated(unsafe) private static var session: OpaquePointer?

    private static var api: OrtApi { OrtGetApiBase().pointee.GetApi(UInt32(ORT_API_VERSION))!.pointee }

    private static func check(_ status: OpaquePointer?) throws {
        guard let status else { return }
        let message = api.GetErrorMessage(status).map { String(cString: $0) } ?? "알 수 없는 오류"
        api.ReleaseStatus(status)
        throw DotError.segment(message)
    }

    /// 모델은 한 번만 읽어 둔다(약 1초).
    private static func loadSession() throws -> OpaquePointer {
        lock.lock(); defer { lock.unlock() }
        if let session { return session }
        guard let model = Bundle.main.url(forResource: "isnetis", withExtension: "onnx") else {
            throw DotError.segment("배경 분리 모델(isnetis.onnx)을 찾지 못했습니다.")
        }
        var env: OpaquePointer?, options: OpaquePointer?, created: OpaquePointer?
        try check(api.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "DotMaker", &env))
        try check(api.CreateSessionOptions(&options))
        defer { api.ReleaseSessionOptions(options) }
        try check(api.CreateSession(env, model.path, options, &created))
        session = created
        return created!
    }

    /// 캐릭터만 남기고 배경을 투명하게 만든 원본 크기 그림.
    static func subject(_ source: CGImage) throws -> Raster {
        let w = source.width, h = source.height
        let scale = Double(side) / Double(max(w, h))
        let nw = Int(Double(w) * scale), nh = Int(Double(h) * scale)
        let px = (side - nw) / 2, py = (side - nh) / 2

        // 1024×1024 검은 캔버스 가운데에 비율을 유지해 넣고 0~1 RGB 평면으로 나눈다.
        guard let canvas = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                     space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                     bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw DotError.render }
        canvas.interpolationQuality = .high
        canvas.draw(source, in: CGRect(x: px, y: side - py - nh, width: nw, height: nh))
        let bytes = canvas.data!.assumingMemoryBound(to: UInt8.self)
        var input = [Float](repeating: 0, count: 3 * side * side)
        for i in 0..<(side * side) {
            for c in 0..<3 { input[c * side * side + i] = Float(bytes[i * 4 + c]) / 255 }
        }

        try Task.checkCancellation()
        let session = try loadSession()
        var memory: OpaquePointer?
        try check(api.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory))
        defer { api.ReleaseMemoryInfo(memory) }
        var shape: [Int64] = [1, 3, Int64(side), Int64(side)]
        var tensor: OpaquePointer?, output: OpaquePointer?
        try input.withUnsafeMutableBytes { buffer in
            try check(api.CreateTensorWithDataAsOrtValue(memory, buffer.baseAddress, buffer.count, &shape, 4,
                                                         ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &tensor))
            defer { api.ReleaseValue(tensor) }
            var inputs: [OpaquePointer?] = [tensor]
            try "img".withCString { inputName in
                try "mask".withCString { outputName in
                    var inNames: [UnsafePointer<CChar>?] = [inputName]
                    var outNames: [UnsafePointer<CChar>?] = [outputName]
                    try check(api.Run(session, nil, &inNames, &inputs, 1, &outNames, 1, &output))
                }
            }
        }
        defer { api.ReleaseValue(output) }
        var raw: UnsafeMutableRawPointer?
        try check(api.GetTensorMutableData(output, &raw))
        let mask = raw!.assumingMemoryBound(to: Float.self)

        // 마스크에서 그림 부분만 잘라 원본 크기로 늘려 투명도로 쓴다.
        // 모델은 몸통도 0.85~0.99로만 확신해서 그대로 쓰면 캐릭터 전체가 비친다.
        // 0.8 이상은 불투명, 0.2 이하(흐린 배경 찌꺼기)는 투명, 그 사이만 반투명으로 편다.
        var gray = [UInt8](repeating: 0, count: nw * nh)
        for y in 0..<nh {
            for x in 0..<nw {
                let sure = (mask[(y + py) * side + x + px] - 0.2) / 0.6
                gray[y * nw + x] = UInt8(max(0, min(1, sure)) * 255 + 0.5)
            }
        }
        let alpha = try gray.withUnsafeMutableBytes { buffer -> [UInt8] in
            guard let small = CGContext(data: buffer.baseAddress, width: nw, height: nh, bitsPerComponent: 8, bytesPerRow: nw,
                                        space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue),
                  let image = small.makeImage(),
                  let full = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                       space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { throw DotError.render }
            full.interpolationQuality = .high
            full.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return Array(UnsafeBufferPointer(start: full.data!.assumingMemoryBound(to: UInt8.self), count: w * h))
        }
        var raster = try Raster(source)
        for i in raster.pixels.indices { raster.pixels[i].a = min(raster.pixels[i].a, alpha[i]) }
        return raster
    }
}
