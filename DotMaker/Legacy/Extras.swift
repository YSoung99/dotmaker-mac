import AppKit
import CoreGraphics
import Foundation
import ImageIO
import simd
import SwiftUI
import UniformTypeIdentifiers

/// 결과 이미지에 실제로 쓰인 색 한 칸.
struct PaletteSwatch: Sendable, Hashable {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
    let count: Int

    var hex: String { String(format: "#%02X%02X%02X", red, green, blue) }
    var color: Color {
        Color(.sRGB, red: Double(red) / 255, green: Double(green) / 255, blue: Double(blue) / 255)
    }

    /// 많이 쓰인 색부터 정렬해 돌려줘요. 불투명 픽셀이 있으면 그것만 세요.
    static func extract(from image: CGImage) -> [PaletteSwatch] {
        guard let bytes = PixelExport.rgbaBytes(image) else { return [] }
        var opaque: [UInt32: Int] = [:]
        var translucent: [UInt32: Int] = [:]
        for offset in Swift.stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Int(bytes[offset + 3])
            guard alpha > 0 else { continue }
            func channel(_ value: UInt8) -> UInt32 {
                UInt32(min(255, (Int(value) * 255 + alpha / 2) / alpha))
            }
            let key = (channel(bytes[offset]) << 16) | (channel(bytes[offset + 1]) << 8) | channel(bytes[offset + 2])
            if alpha == 255 { opaque[key, default: 0] += 1 } else { translucent[key, default: 0] += 1 }
        }
        let counts = opaque.isEmpty ? translucent : opaque
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { entry in
            let key = entry.key
            return PaletteSwatch(red: UInt8((key >> 16) & 0xFF), green: UInt8((key >> 8) & 0xFF),
                                 blue: UInt8(key & 0xFF), count: entry.value)
        }
    }
}

enum PixelExport {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let rgba = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue

    /// 이미지를 프리멀티플라이 RGBA 바이트로 꺼내요.
    static func rgbaBytes(_ image: CGImage) -> [UInt8]? {
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: sRGB, bitmapInfo: rgba
            ) else { return false }
            context.setBlendMode(.copy)
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        return drawn ? bytes : nil
    }

    /// 한 픽셀을 scale×scale 블록으로 그대로 복제해요. 보간이 전혀 없어서 도트가 번지지 않아요.
    static func upscaled(_ image: CGImage, by scale: Int) -> CGImage? {
        guard scale > 1 else { return image }
        guard let source = rgbaBytes(image) else { return nil }
        let width = image.width, height = image.height
        let outWidth = width * scale, outHeight = height * scale
        var output = [UInt8](repeating: 0, count: outWidth * outHeight * 4)
        for y in 0..<height {
            for x in 0..<width {
                let from = (y * width + x) * 4
                for dy in 0..<scale {
                    let rowStart = ((y * scale + dy) * outWidth + x * scale) * 4
                    for dx in 0..<scale {
                        let to = rowStart + dx * 4
                        output[to] = source[from]
                        output[to + 1] = source[from + 1]
                        output[to + 2] = source[from + 2]
                        output[to + 3] = source[from + 3]
                    }
                }
            }
        }
        return PixelExport.image(from: output, width: outWidth, height: outHeight)
    }

    /// 프리멀티플라이 RGBA 바이트로 이미지를 만들어요.
    static func image(from bytes: [UInt8], width: Int, height: Int) -> CGImage? {
        guard bytes.count == width * height * 4,
              let provider = CGDataProvider(data: Data(bytes) as CFData) else { return nil }
        return CGImage(
            width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: sRGB, bitmapInfo: CGBitmapInfo(rawValue: rgba),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
        )
    }

    static func writePNG(_ image: CGImage, to url: URL) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ConversionError.cannotSave
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.cannotSave }
        try (data as Data).write(to: url, options: .atomic)
    }
}

extension Conversion {
    /// 배율을 적용해 PNG로 저장해요. 1배는 기존 저장과 같은 결과예요.
    func writePNG(to url: URL, scale: Int) throws {
        guard scale > 1 else { return try writePNG(to: url) }
        guard let image = PixelExport.upscaled(pixelArt, by: scale) else { throw ConversionError.cannotSave }
        try PixelExport.writePNG(image, to: url)
    }
}

extension SourceImage {
    /// 클립보드에서 이미지를 읽어요. 파일을 복사했다면 그 파일 경로를 먼저 돌려줘요.
    @MainActor
    static func fromPasteboard(_ pasteboard: NSPasteboard = .general) -> (url: URL?, image: SourceImage?) {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        if let url = (pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL])?.first {
            return (url, nil)
        }
        guard let image = NSImage(pasteboard: pasteboard),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return (nil, nil) }
        let source = SourceImage(name: "붙여넣은 이미지.png",
                                 size: PixelSize(width: cgImage.width, height: cgImage.height), image: cgImage)
        return (nil, source)
    }
}

/// 이미지마다 출력 픽셀 격자를 어디에 둘지 골라요.
///
/// 각 후보 위치(¼칸 단위)에서 원본을 4×4 표본으로 나눠, 한 칸 안의 색이 얼마나 섞이는지
/// (칸 안 분산의 합)를 재요. 선과 면의 경계가 칸 경계와 맞을수록 값이 작아져요.
/// 차이가 1% 안쪽이면 기존 기본값(왼쪽·위 ¼칸)을 그대로 써서 결과가 괜히 흔들리지 않게 해요.
enum GridAligner {
    static let defaultGrid = SIMD2(-1, -1)
    private static let side = 4
    private static let margin = 4

    /// (가로, 세로) ¼칸 단위 위치를 돌려줘요. 음수는 왼쪽·위, 범위는 -2...2예요.
    static func bestGrid(for source: SourceImage, size: PixelSize, removeLightBackground: Bool) throws -> SIMD2<Int> {
        let prepared = removeLightBackground ? try PixelConverter.withoutLightBackground(source) : source
        let scale = min(Double(size.width) / Double(prepared.size.width),
                        Double(size.height) / Double(prepared.size.height))
        let width = max(1, min(size.width, Int((Double(prepared.size.width) * scale).rounded())))
        let height = max(1, min(size.height, Int((Double(prepared.size.height) * scale).rounded())))
        // 가장자리 한 줄은 빼고 재므로 너무 작으면 기본값을 써요.
        guard width >= 4, height >= 4 else { return defaultGrid }

        let sampledWidth = width * side, sampledHeight = height * side
        let totalWidth = sampledWidth + margin * 2, totalHeight = sampledHeight + margin * 2
        let context = try PixelConverter.rasterize(
            prepared.image, width: totalWidth, height: totalHeight,
            rect: CGRect(x: margin, y: margin, width: sampledWidth, height: sampledHeight)
        )
        guard let data = context.data else { return defaultGrid }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let stride = context.bytesPerRow
        var samples = [SIMD4<Float>](repeating: .zero, count: totalWidth * totalHeight)
        for y in 0..<totalHeight {
            let row = y * stride
            for x in 0..<totalWidth {
                let offset = row + x * 4
                // 프리멀티플라이 값 그대로 써서 투명한 테두리도 경계로 쳐요.
                samples[y * totalWidth + x] = SIMD4(Float(bytes[offset]), Float(bytes[offset + 1]),
                                                    Float(bytes[offset + 2]), Float(bytes[offset + 3])) / 255
            }
        }

        var scores: [SIMD2<Int>: Float] = [:]
        let cellCount = Float(side * side)
        for gy in -2...2 {
            for gx in -2...2 {
                try Task.checkCancellation()
                // 그림을 왼쪽(gx<0)·위(gy<0)로 옮기는 것은 격자 창을 반대쪽으로 옮기는 것과 같아요.
                let originX = margin - gx, originY = margin - gy
                var total: Float = 0
                for cy in 1..<(height - 1) {
                    for cx in 1..<(width - 1) {
                        var sum = SIMD4<Float>.zero
                        var squares: Float = 0
                        for sy in 0..<side {
                            let base = (originY + cy * side + sy) * totalWidth + originX + cx * side
                            for sx in 0..<side {
                                let value = samples[base + sx]
                                sum += value
                                squares += simd_dot(value, value)
                            }
                        }
                        total += squares - simd_dot(sum, sum) / cellCount
                    }
                }
                scores[SIMD2(gx, gy)] = total
            }
        }
        guard let fallback = scores[defaultGrid],
              let best = scores.min(by: { $0.value != $1.value ? $0.value < $1.value : preferred($0.key, $1.key) })
        else { return defaultGrid }
        return best.value < fallback * 0.99 ? best.key : defaultGrid
    }

    /// 점수가 같으면 덜 움직이는 쪽을 골라요.
    private static func preferred(_ a: SIMD2<Int>, _ b: SIMD2<Int>) -> Bool {
        let da = abs(a.x) + abs(a.y), db = abs(b.x) + abs(b.y)
        return da != db ? da < db : (a.y, a.x) < (b.y, b.x)
    }
}

/// 원본이 이미 도트 그림인지 알아봐요.
struct PixelArtHint: Sendable, Equatable {
    /// 원래 도트 크기예요.
    let native: PixelSize
    /// 원본이 몇 배로 키운 도트인지예요. 1이면 원래 크기 그대로인 작은 그림이에요.
    let blockScale: Int
}

enum PixelArtDetector {
    /// 키운 도트 그림은 색이 바뀌는 자리가 항상 k칸 간격으로만 나와요. 그 간격을 찾아요.
    static func detect(_ source: SourceImage) -> PixelArtHint? {
        let image = source.image
        let width = image.width, height = image.height
        if width * height <= 2048 * 2048, let bytes = PixelExport.rgbaBytes(image),
           let scale = blockScale(bytes, width: width, height: height) {
            let native = PixelSize(width: max(1, Int((Double(width) / Double(scale)).rounded())),
                                   height: max(1, Int((Double(height) / Double(scale)).rounded())))
            if native.width <= 512 && native.height <= 512 { return PixelArtHint(native: native, blockScale: scale) }
        }
        if width <= 512 && height <= 512 {
            return PixelArtHint(native: PixelSize(width: width, height: height), blockScale: 1)
        }
        return nil
    }

    private static func blockScale(_ bytes: [UInt8], width: Int, height: Int) -> Int? {
        func differs(_ a: Int, _ b: Int) -> Bool {
            for c in 0..<4 where abs(Int(bytes[a + c]) - Int(bytes[b + c])) > 8 { return true }
            return false
        }
        // 행·열을 골고루 몇백 줄만 훑어도 충분해요.
        let rowStep = max(1, height / 300), columnStep = max(1, width / 300)
        var horizontal: [Int] = []
        for y in Swift.stride(from: 0, to: height, by: rowStep) {
            let row = y * width * 4
            for x in 1..<width where differs(row + x * 4, row + (x - 1) * 4) { horizontal.append(x) }
        }
        var vertical: [Int] = []
        for x in Swift.stride(from: 0, to: width, by: columnStep) {
            for y in 1..<height where differs((y * width + x) * 4, ((y - 1) * width + x) * 4) { vertical.append(y) }
        }
        guard horizontal.count >= 100, vertical.count >= 100 else { return nil }
        func aligned(_ positions: [Int], _ k: Int) -> Bool {
            var bins = [Int](repeating: 0, count: k)
            for p in positions { bins[p % k] += 1 }
            return Double(bins.max() ?? 0) >= Double(positions.count) * 0.95
        }
        for k in [16, 12, 10, 8, 7, 6, 5, 4, 3, 2] where width / k >= 8 && height / k >= 8 {
            if aligned(horizontal, k) && aligned(vertical, k) { return k }
        }
        return nil
    }
}

/// 팔레트를 평균색 대신 원본에 실제로 많이 있던 색으로 바꿔 채도가 빠지지 않게 해요.
///
/// 결과의 색 하나마다, 그 색이 칠해진 자리의 원본(단순 축소본) 색을 모아 가장 흔한 색으로 바꿔요.
/// 바꾼 색이 다른 팔레트 색과 겹치거나 너무 멀어지면 원래 색을 그대로 둬요.
/// 예: 흰 몸통 경계처럼 일부러 만든 색은 흰색과 겹치므로 남아요.
enum VividPalette {
    static func apply(to conversion: Conversion, keepDarkest: Bool) -> Conversion {
        guard var output = PixelExport.rgbaBytes(conversion.pixelArt),
              let baseline = PixelExport.rgbaBytes(conversion.baseline),
              output.count == baseline.count else { return conversion }

        func unpremultiplied(_ bytes: [UInt8], _ offset: Int) -> SIMD3<Int> {
            let alpha = Int(bytes[offset + 3])
            return SIMD3<Int>((0..<3).map { min(255, (Int(bytes[offset + $0]) * 255 + alpha / 2) / max(1, alpha)) })
        }
        func key(_ color: SIMD3<Int>) -> Int { (color.x << 16) | (color.y << 8) | color.z }

        struct Bin { var total = SIMD3<Int>.zero; var count = 0 }
        var bins: [Int: [Int: Bin]] = [:]
        var colors: [Int: SIMD3<Int>] = [:]
        for offset in Swift.stride(from: 0, to: output.count, by: 4) where output[offset + 3] > 0 {
            let color = unpremultiplied(output, offset)
            let paletteKey = key(color)
            colors[paletteKey] = color
            guard baseline[offset + 3] >= 128 else { continue }
            let source = unpremultiplied(baseline, offset)
            let binKey = ((source.x >> 3) << 10) | ((source.y >> 3) << 5) | (source.z >> 3)
            bins[paletteKey, default: [:]][binKey, default: Bin()].total &+= source
            bins[paletteKey, default: [:]][binKey, default: Bin()].count += 1
        }
        guard colors.count > 1 else { return conversion }
        let darkest = colors.min { luma($0.value) < luma($1.value) }?.key

        var replacement: [Int: SIMD3<Int>] = [:]
        for (paletteKey, color) in colors {
            if keepDarkest && paletteKey == darkest { continue }
            guard let best = bins[paletteKey]?.values.max(by: { $0.count < $1.count }), best.count >= 2 else { continue }
            let candidate = SIMD3(best.total.x / best.count, best.total.y / best.count, best.total.z / best.count)
            // 원래 색에서 너무 멀면 다른 의도로 만든 색이에요.
            guard distance(candidate, color) <= 72 else { continue }
            replacement[paletteKey] = candidate
        }
        // 서로 다른 색이 같은 색으로 합쳐지지 않게 해요.
        let finalColors = colors.map { (key: $0.key, color: replacement[$0.key] ?? $0.value) }
        for item in finalColors where replacement[item.key] != nil {
            let collides = finalColors.contains { other in other.key != item.key && distance(other.color, item.color) < 10 }
            if collides { replacement[item.key] = nil }
        }
        guard !replacement.isEmpty else { return conversion }

        var used: Set<Int> = []
        for offset in Swift.stride(from: 0, to: output.count, by: 4) where output[offset + 3] > 0 {
            let original = unpremultiplied(output, offset)
            let color = replacement[key(original)] ?? original
            let alpha = Int(output[offset + 3])
            output[offset] = UInt8((color.x * alpha + 127) / 255)
            output[offset + 1] = UInt8((color.y * alpha + 127) / 255)
            output[offset + 2] = UInt8((color.z * alpha + 127) / 255)
            used.insert(key(color))
        }
        guard let image = PixelExport.image(from: output, width: conversion.pixelArt.width,
                                            height: conversion.pixelArt.height) else { return conversion }
        return Conversion(size: conversion.size, baseline: conversion.baseline, pixelArt: image, colorCount: used.count)
    }

    private static func luma(_ c: SIMD3<Int>) -> Int { c.x * 299 + c.y * 587 + c.z * 114 }
    private static func distance(_ a: SIMD3<Int>, _ b: SIMD3<Int>) -> Double {
        let d = SIMD3<Double>(Double(a.x - b.x), Double(a.y - b.y), Double(a.z - b.z))
        return (d * d).sum().squareRoot()
    }
}

/// 결과 미리보기 위에 출력 픽셀 경계를 그려요.
struct PixelGridOverlay: View {
    let columns: Int
    let rows: Int

    var body: some View {
        Canvas { context, size in
            let cellWidth = size.width / CGFloat(columns)
            let cellHeight = size.height / CGFloat(rows)
            var lines = Path()
            for column in 1..<max(1, columns) {
                let x = (CGFloat(column) * cellWidth).rounded()
                lines.move(to: CGPoint(x: x, y: 0))
                lines.addLine(to: CGPoint(x: x, y: size.height))
            }
            for row in 1..<max(1, rows) {
                let y = (CGFloat(row) * cellHeight).rounded()
                lines.move(to: CGPoint(x: 0, y: y))
                lines.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(lines, with: .color(.black.opacity(0.28)), lineWidth: 0.5)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
