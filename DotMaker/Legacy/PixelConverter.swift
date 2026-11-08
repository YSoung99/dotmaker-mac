import CoreGraphics
import Foundation
import ImageIO
import simd
import UniformTypeIdentifiers

struct PixelSize: Equatable, Sendable {
    let width: Int
    let height: Int

    var label: String { "\(width) × \(height)" }
}

struct SourceImage: Sendable {
    let name: String
    let size: PixelSize
    let image: CGImage

    static func load(_ url: URL, displayName: String? = nil) throws -> Self {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else { throw ConversionError.invalidImage }

        let orientation = properties[kCGImagePropertyOrientation] as? Int ?? 1
        let rotated = (5...8).contains(orientation)
        let size = PixelSize(width: rotated ? height : width, height: rotated ? width : height)
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 4096,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary) else {
            throw ConversionError.invalidImage
        }
        return Self(name: displayName ?? url.lastPathComponent, size: size, image: image)
    }
}

struct Conversion: Sendable {
    let size: PixelSize
    let baseline: CGImage
    let pixelArt: CGImage
    let colorCount: Int

    func writePNG(to url: URL) throws {
        // Encode before replacing an existing file, and write atomically.
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw ConversionError.cannotSave
        }
        CGImageDestinationAddImage(destination, pixelArt, nil)
        guard CGImageDestinationFinalize(destination) else { throw ConversionError.cannotSave }
        try (data as Data).write(to: url, options: .atomic)
    }
}

enum ConversionError: LocalizedError {
    case invalidImage, invalidSize, cannotRender, cannotSave

    var errorDescription: String? {
        switch self {
        case .invalidImage: "이미지를 열 수 없어요. PNG, JPEG, WebP 또는 HEIC 파일을 선택해 주세요."
        case .invalidSize: "가로와 세로에 1부터 512까지의 정수를 입력해 주세요."
        case .cannotRender: "이미지를 변환하는 중 문제가 생겼어요."
        case .cannotSave: "PNG 파일을 저장할 수 없어요."
        }
    }
}

enum SpritePaletteStyle: String, CaseIterable, Sendable {
    case original = "원본 계열"
    case berryInk = "베리 잉크"
}

enum PixelConverter {
    private static let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let rgba = CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue
    private static let linearSRGB: [Float] = (0...255).map { byte in
        let value = Float(byte) / 255
        return value <= 0.04045 ? value / 12.92 : powf((value + 0.055) / 1.055, 2.4)
    }
    private static let sampleSide = 4

    static func convert(
        _ source: SourceImage, size: PixelSize, colors: Int,
        gameSprite: Bool = false, removeLightBackground: Bool = false, fineDetail: Bool = false,
        paletteStyle: SpritePaletteStyle = .original, gridOffset: SIMD2<Int> = .zero, thinInk: Bool = false,
        shadeWhiteEdge: Bool = false
    ) throws -> Conversion {
        guard (1...512).contains(size.width), (1...512).contains(size.height), (2...64).contains(colors) else {
            throw ConversionError.invalidSize
        }

        let prepared = gameSprite && removeLightBackground ? try withoutLightBackground(source) : source
        let fitted = fit(prepared.size, inside: size)
        let baselineContext = try rasterize(prepared.image, width: size.width, height: size.height, rect: fitted)
        guard let baseline = baselineContext.makeImage() else { throw ConversionError.cannotRender }

        let side = sampleSide
        let sampledWidth = Int(fitted.width) * side
        let sampledHeight = Int(fitted.height) * side
        let shift = gameSprite ? SIMD2(max(-2, min(2, gridOffset.x)), max(-2, min(2, gridOffset.y))) : .zero
        let samples = try rasterize(
            prepared.image, width: sampledWidth, height: sampledHeight,
            rect: CGRect(x: shift.x, y: shift.y, width: sampledWidth, height: sampledHeight)
        )
        guard let data = samples.data else { throw ConversionError.cannotRender }
        let rgbaBytes = data.assumingMemoryBound(to: UInt8.self)
        if shift != .zero {
            extendSampleEdges(rgbaBytes, width: sampledWidth, height: sampledHeight,
                              stride: samples.bytesPerRow, shift: shift)
        }
        let width = Int(fitted.width)
        let height = Int(fitted.height)
        let pixels: [Pixel]
        let palette: [SIMD3<Float>]
        let labels: [Int]?
        if gameSprite {
            (pixels, palette, labels) = try spritePixels(
                rgbaBytes, stride: samples.bytesPerRow, width: width, height: height, colors: colors,
                fineDetail: fineDetail, paletteStyle: paletteStyle, thinInk: thinInk, shadeWhiteEdge: shadeWhiteEdge
            )
        } else {
            pixels = try choosePixels(rgbaBytes, stride: samples.bytesPerRow, width: width, height: height)
            palette = try buildPalette(from: pixels, count: colors)
            labels = nil
        }
        let encodedPalette = palette.map(encodeSRGB)
        let output = try rasterize(nil, width: size.width, height: size.height, rect: .zero)
        guard let outputData = output.data else { throw ConversionError.cannotRender }
        let outputBytes = outputData.assumingMemoryBound(to: UInt8.self)
        let xOffset = Int(fitted.minX)
        // Core Graphics rectangles use a bottom origin, while bitmap memory is top-first.
        let yOffset = size.height - Int(fitted.maxY)
        var usedColors: Set<UInt32> = []
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                let pixel = pixels[y * width + x]
                let alpha = Int((pixel.alpha * 255).rounded())
                guard alpha > 0, !palette.isEmpty else { continue }
                let index = labels?[y * width + x] ?? nearest(pixel.color, in: palette)
                let rgb = encodedPalette[index]
                let offset = (y + yOffset) * output.bytesPerRow + (x + xOffset) * 4
                outputBytes[offset] = UInt8((Int(rgb.x) * alpha + 127) / 255)
                outputBytes[offset + 1] = UInt8((Int(rgb.y) * alpha + 127) / 255)
                outputBytes[offset + 2] = UInt8((Int(rgb.z) * alpha + 127) / 255)
                outputBytes[offset + 3] = UInt8(alpha)
                usedColors.insert((UInt32(rgb.x) << 16) | (UInt32(rgb.y) << 8) | UInt32(rgb.z))
            }
        }
        guard let pixelArt = output.makeImage() else { throw ConversionError.cannotRender }
        return Conversion(size: size, baseline: baseline, pixelArt: pixelArt, colorCount: usedColors.count)
    }

    private static func extendSampleEdges(
        _ bytes: UnsafeMutablePointer<UInt8>, width: Int, height: Int, stride: Int, shift: SIMD2<Int>
    ) {
        // Clamp edge samples so nudging a full opaque image cannot make transparent corners.
        let firstX = max(0, shift.x), lastX = min(width - 1, width - 1 + shift.x)
        let firstY = max(0, -shift.y), lastY = min(height - 1, height - 1 - shift.y)
        if shift.x != 0 {
            for y in firstY...lastY {
                let row = bytes.advanced(by: y * stride)
                for x in 0..<firstX {
                    row.advanced(by: x * 4).update(from: row.advanced(by: firstX * 4), count: 4)
                }
                for x in (lastX + 1)..<width {
                    row.advanced(by: x * 4).update(from: row.advanced(by: lastX * 4), count: 4)
                }
            }
        }
        for y in 0..<firstY {
            bytes.advanced(by: y * stride).update(from: bytes.advanced(by: firstY * stride), count: stride)
        }
        for y in (lastY + 1)..<height {
            bytes.advanced(by: y * stride).update(from: bytes.advanced(by: lastY * stride), count: stride)
        }
    }

    private static func fit(_ source: PixelSize, inside canvas: PixelSize) -> CGRect {
        let scale = min(Double(canvas.width) / Double(source.width), Double(canvas.height) / Double(source.height))
        let width = max(1, min(canvas.width, Int((Double(source.width) * scale).rounded())))
        let height = max(1, min(canvas.height, Int((Double(source.height) * scale).rounded())))
        let x = (canvas.width - width) / 2
        let top = (canvas.height - height) / 2
        return CGRect(x: x, y: canvas.height - height - top, width: width, height: height)
    }

    /// 작은 원본을 늘릴 때 보간하지 않을지예요. 비교 실험용으로만 끕니다.
    nonisolated(unsafe) static var nearestWhenUpscaling = true

    static func rasterize(_ image: CGImage?, width: Int, height: Int, rect: CGRect) throws -> CGContext {
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: sRGB, bitmapInfo: rgba
        ) else { throw ConversionError.cannotRender }
        context.clear(CGRect(x: 0, y: 0, width: width, height: height))
        if let image {
            // 원본보다 크게 늘려 그릴 때 부드럽게 보간하면 원본에 없던 중간색이 생겨 선과 색이 번져요.
            // 그럴 땐 보간 없이 원본 픽셀을 그대로 써요. (작은 원본 대책 1번, Claude)
            let upscaling = rect.width > CGFloat(image.width) * 1.05 || rect.height > CGFloat(image.height) * 1.05
            context.interpolationQuality = upscaling && nearestWhenUpscaling ? .none : .high
            context.setBlendMode(.copy)
            context.draw(image, in: rect)
        }
        return context
    }

    private struct Pixel {
        var color: SIMD3<Float> = .zero
        var alpha: Float = 0
        var detail: Float = 0
    }

    private struct Subpixel {
        var color: SIMD3<Float> = .zero
        var weight: Float = 0
    }

    private static func choosePixels(
        _ bytes: UnsafePointer<UInt8>, stride: Int, width: Int, height: Int
    ) throws -> [Pixel] {
        let side = sampleSide
        let center: [Float] = [1, 1.4, 1.4, 1]
        let sampleCount = side * side
        var result = Array(repeating: Pixel(), count: width * height)
        var samples = Array(repeating: Subpixel(), count: sampleCount)
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                var mean: SIMD3<Float> = .zero
                var sum: Float = 0
                var alphaSum: Float = 0
                var peakAlpha: Float = 0
                for sy in 0..<side {
                    let start = (y * side + sy) * stride + x * side * 4
                    for sx in 0..<side {
                        let offset = start + sx * 4
                        let alphaByte = Int(bytes[offset + 3])
                        let alpha = Float(alphaByte) / 255
                        let index = sy * side + sx
                        samples[index].weight = 0
                        guard alphaByte > 0 else { continue }
                        let color = decodeLab(bytes.advanced(by: offset), alpha: alphaByte)
                        let weight = alpha * center[sx] * center[sy]
                        samples[index] = Subpixel(color: color, weight: weight)
                        mean += color * weight
                        sum += weight
                        alphaSum += alpha
                        peakAlpha = max(peakAlpha, alpha)
                    }
                }
                guard sum > 0 else { continue }
                let coverage = alphaSum / Float(sampleCount)
                mean /= sum
                var alpha = coverage
                if peakAlpha >= 0.98, coverage < 0.995 {
                    // Snap opaque silhouettes while allowing translucent material to retain its alpha.
                    alpha = coverage >= 0.43 ? 1 : coverage * 0.32
                }
                let representative = chooseColor(samples, mean: mean, totalWeight: sum)
                result[y * width + x] = Pixel(color: representative.color, alpha: alpha, detail: representative.detail)
            }
        }
        return result
    }

    private static func chooseColor(
        _ samples: [Subpixel], mean: SIMD3<Float>, totalWeight: Float, favorDarkStrokes: Bool = true
    ) -> (color: SIMD3<Float>, detail: Float) {
        let variation = samples.reduce(Float(0)) { partial, sample in
            sample.weight > 0 ? max(partial, distanceSquared(sample.color, mean)) : partial
        }
        guard variation > 0.005 else { return (mean, 0) }
        var bestScore: Float = -.infinity
        var best = mean
        for candidate in samples where candidate.weight > 0 {
            var support: Float = 0
            for other in samples where other.weight > 0 {
                let affinity = max(0, 1 - distanceSquared(candidate.color, other.color) / 0.008)
                support += other.weight * affinity
            }
            let fraction = support / totalWeight
            let darker = max(0, mean.x - candidate.color.x)
            // Give a thin dark stroke a chance when multiple subsamples support it.
            let stroke = favorDarkStrokes ? min(0.68, darker * 2.6) * min(1, max(0, (fraction - 0.09) / 0.13)) : 0
            let score = fraction + stroke - 0.38 * distanceSquared(candidate.color, mean)
            if score > bestScore {
                bestScore = score
                best = candidate.color
            }
        }
        let strength = min(1, (variation - 0.005) / 0.024)
        return (mean + (best - mean) * strength, strength)
    }

    private struct Bucket {
        var total: SIMD3<Float> = .zero
        var weight: Float = 0
    }

    private struct Swatch {
        var color: SIMD3<Float>
        var weight: Float
    }

    private static func buildPalette(from pixels: [Pixel], count: Int) throws -> [SIMD3<Float>] {
        var bins: [Int: Bucket] = [:]
        for pixel in pixels where pixel.alpha > 0.02 {
            let l = Int((pixel.color.x * 48).rounded())
            let a = Int(((pixel.color.y + 0.5) * 56).rounded())
            let b = Int(((pixel.color.z + 0.5) * 56).rounded())
            let key = (l << 12) | (a << 6) | b
            let weight = pixel.alpha * (1 + pixel.detail * 0.55)
            bins[key, default: Bucket()].total += pixel.color * weight
            bins[key, default: Bucket()].weight += weight
        }
        let swatches = bins.keys.sorted().compactMap { key -> Swatch? in
            guard let bin = bins[key] else { return nil }
            return Swatch(color: bin.total / bin.weight, weight: powf(bin.weight, 0.65))
        }
        guard let first = swatches.max(by: { $0.weight < $1.weight }) else {
            return pixels.first(where: { $0.alpha > 0 }).map { [$0.color] } ?? []
        }
        guard swatches.count > count else { return swatches.map(\.color) }
        var palette = [first.color]
        var distances = Array(repeating: Float.infinity, count: swatches.count)
        while palette.count < count {
            try Task.checkCancellation()
            let last = palette[palette.count - 1]
            var bestIndex = 0
            var bestScore: Float = -1
            for index in swatches.indices {
                distances[index] = min(distances[index], distanceSquared(swatches[index].color, last))
                let score = distances[index] * swatches[index].weight
                if score > bestScore {
                    bestIndex = index
                    bestScore = score
                }
            }
            guard bestScore > 0 else { break }
            palette.append(swatches[bestIndex].color)
        }
        for _ in 0..<7 {
            try Task.checkCancellation()
            var clusters = Array(repeating: Bucket(), count: palette.count)
            for swatch in swatches {
                let index = nearest(swatch.color, in: palette)
                clusters[index].total += swatch.color * swatch.weight
                clusters[index].weight += swatch.weight
            }
            for index in clusters.indices where clusters[index].weight > 0 {
                palette[index] = clusters[index].total / clusters[index].weight
            }
        }
        return palette
    }

    private static func nearest(_ color: SIMD3<Float>, in palette: [SIMD3<Float>]) -> Int {
        var winner = 0
        var closest = Float.infinity
        for index in palette.indices {
            let distance = distanceSquared(palette[index], color)
            if distance < closest {
                closest = distance
                winner = index
            }
        }
        return winner
    }

    private static func distanceSquared(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float {
        let d = a - b
        return d.x * d.x + d.y * d.y + d.z * d.z
    }

    private static func decodeLab(_ rgba: UnsafePointer<UInt8>, alpha: Int) -> SIMD3<Float> {
        let r = linearSRGB[min(255, (Int(rgba[0]) * 255 + alpha / 2) / alpha)]
        let g = linearSRGB[min(255, (Int(rgba[1]) * 255 + alpha / 2) / alpha)]
        let b = linearSRGB[min(255, (Int(rgba[2]) * 255 + alpha / 2) / alpha)]
        let l = cbrtf(0.41222147 * r + 0.53633255 * g + 0.05144599 * b)
        let m = cbrtf(0.21190350 * r + 0.68069955 * g + 0.10739696 * b)
        let s = cbrtf(0.08830246 * r + 0.28171884 * g + 0.62997870 * b)
        return SIMD3(
            0.21045426 * l + 0.79361779 * m - 0.00407205 * s,
            1.97799850 * l - 2.42859221 * m + 0.45059371 * s,
            0.02590404 * l + 0.78277177 * m - 0.80867577 * s
        )
    }

    private static func encodeSRGB(_ color: SIMD3<Float>) -> SIMD3<UInt8> {
        let l = color.x + 0.39633778 * color.y + 0.21580376 * color.z
        let m = color.x - 0.10556135 * color.y - 0.06385417 * color.z
        let s = color.x - 0.08948418 * color.y - 1.29148555 * color.z
        let ll = l * l * l
        let mm = m * m * m
        let ss = s * s * s
        return SIMD3(
            encodeChannel(4.07674166 * ll - 3.30771159 * mm + 0.23096993 * ss),
            encodeChannel(-1.26843800 * ll + 2.60975740 * mm - 0.34131940 * ss),
            encodeChannel(-0.00419609 * ll - 0.70341861 * mm + 1.70761470 * ss)
        )
    }

    private static func encodeChannel(_ linear: Float) -> UInt8 {
        let clamped = min(1, max(0, linear))
        let encoded = clamped <= 0.0031308 ? clamped * 12.92 : 1.055 * powf(clamped, 1 / 2.4) - 0.055
        return UInt8((encoded * 255).rounded())
    }
}

extension PixelConverter {
    private static func spritePixels(
        _ bytes: UnsafePointer<UInt8>, stride: Int, width: Int, height: Int, colors: Int,
        fineDetail: Bool, paletteStyle: SpritePaletteStyle, thinInk: Bool, shadeWhiteEdge: Bool
    ) throws -> ([Pixel], [SIMD3<Float>], [Int]?) {
        let side = sampleSide
        let sampleCount = Float(side * side)
        var pixels = Array(repeating: Pixel(), count: width * height)
        var fillHues = fineDetail ? [SIMD3<Float>](repeating: .zero, count: pixels.count) : []
        var centers = fineDetail ? [Float](repeating: 0, count: pixels.count) : []
        var lightGaps = fineDetail ? [Float](repeating: 0, count: pixels.count) : []
        var inkTotal: SIMD3<Float> = .zero
        var inkWeight: Float = 0
        var whiteTotal: SIMD3<Float> = .zero
        var whiteWeight: Float = 0
        var fillSamples = Array(repeating: Subpixel(), count: side * side)
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                var alphaSum: Float = 0
                var stroke: Float = 0
                var centerInk: Float = 0
                var lightGap: Float = 0
                var fill: SIMD3<Float> = .zero
                var fillWeight: Float = 0
                var average: SIMD3<Float> = .zero
                var white: SIMD3<Float> = .zero
                var whiteCoverage: Float = 0
                var chromaticFill: SIMD3<Float> = .zero
                var chromaticCoverage: Float = 0
                var chromaticWeight: Float = 0
                for sy in 0..<side {
                    for sx in 0..<side {
                        let offset = (y * side + sy) * stride + (x * side + sx) * 4
                        let alpha = Int(bytes[offset + 3])
                        let index = sy * side + sx
                        fillSamples[index].weight = 0
                        guard alpha > 0 else { continue }
                        let coverage = Float(alpha) / 255
                        let color = decodeLab(bytes.advanced(by: offset), alpha: alpha)
                        let chroma = abs(color.y) + abs(color.z)
                        let dark = min(1, max(0, (0.49 - color.x) / 0.23)) * max(0.35, 1 - 4 * chroma)
                        let weight = coverage * (1 - dark) * (1 - dark)
                        if weight > 0.09 { fillSamples[index] = Subpixel(color: color, weight: weight) }
                        alphaSum += coverage
                        stroke += coverage * dark
                        if fineDetail {
                            let hue = SIMD2(color.y, color.z)
                            let strength = simd_length(hue)
                            if color.x >= 0.46 && strength >= 0.034 {
                                chromaticFill += color * coverage
                                chromaticCoverage += coverage
                                chromaticWeight += strength * coverage
                            }
                            if (1...2).contains(sx) && (1...2).contains(sy) {
                                centerInk += coverage * dark
                                if color.x > 0.92 && chroma < 0.045 { lightGap += coverage }
                            }
                        }
                        fill += color * weight
                        fillWeight += weight
                        average += color * coverage
                        if dark >= 0.72 {
                            inkTotal += color * dark * coverage
                            inkWeight += dark * coverage
                        }
                        if color.x > 0.965 && chroma < 0.022 {
                            white += color * coverage
                            whiteCoverage += coverage
                        }
                    }
                }
                guard alphaSum >= sampleCount * 0.46 else { continue }
                var color = fillWeight > 0.1 ? fill / fillWeight : average / alphaSum
                if whiteCoverage >= max(1, fillWeight * 0.56) {
                    color = white / whiteCoverage
                    whiteTotal += white
                    whiteWeight += whiteCoverage
                } else if fillWeight > 0.1 {
                    color = chooseColor(fillSamples, mean: color, totalWeight: fillWeight, favorDarkStrokes: false).color
                }
                let i = y * width + x
                pixels[i] = Pixel(color: color, alpha: 1, detail: stroke / sampleCount)
                if fineDetail {
                    centers[i] = centerInk / 4
                    lightGaps[i] = lightGap / 4
                    if chromaticCoverage >= sampleCount * 0.58,
                       simd_length(SIMD2(chromaticFill.y, chromaticFill.z)) >= chromaticWeight * 0.90 {
                        fillHues[i] = chromaticFill / chromaticCoverage
                    }
                }
            }
        }
        let opaque = pixels.indices.filter { pixels[$0].alpha > 0 }
        guard !opaque.isEmpty else { return (pixels, [], nil) }

        func neighbors(_ i: Int, diagonals: Bool = false) -> [Int] {
            let x = i % width, y = i / width
            return (max(0, y - 1)...min(height - 1, y + 1)).flatMap { v in
                (max(0, x - 1)...min(width - 1, x + 1)).compactMap { u in
                    guard (u != x || v != y), diagonals || u == x || v == y else { return nil }
                    return v * width + u
                }
            }
        }
        var strokes = Array(repeating: false, count: pixels.count)
        if inkWeight > 0 {
            for i in opaque {
                let edge = neighbors(i).contains { pixels[$0].alpha == 0 }
                let coverage = pixels[i].detail
                if fineDetail && !edge {
                    let protectedGap = lightGaps[i] >= 0.72 && centers[i] < 0.20
                    let concentrated = centers[i] >= 0.58 && coverage >= 0.25
                    strokes[i] = coverage >= 0.57 || (!protectedGap && (coverage >= 0.35 || concentrated))
                } else {
                    strokes[i] = coverage >= (edge ? 0.17 : 0.35)
                }
            }
            let core = strokes
            for i in opaque where !core[i] && pixels[i].detail >= 0.23 {
                if fineDetail && lightGaps[i] >= 0.72 && centers[i] < 0.20 { continue }
                let adjoining = neighbors(i, diagonals: true).filter { core[$0] }
                // Bridge a thin line only when its dark neighbors span opposite sides.
                let x = i % width, y = i / width
                strokes[i] = adjoining.contains { a in
                    adjoining.contains { b in
                        (a % width - x) * (b % width - x) + (a / width - y) * (b / width - y) < 0
                    }
                }
            }
        }
        // Remove the weakest corner of a thick stroke on a light, flat fill
        // if the remaining neighbors still connect the line.
        if width > 1, height > 1 {
            for y in 0..<(height - 1) {
                for x in 0..<(width - 1) {
                    let first = y * width + x
                    let block = [first, first + 1, first + width, first + width + 1]
                    guard block.allSatisfy({ strokes[$0] }),
                          let i = block.min(by: { pixels[$0].detail < pixels[$1].detail }),
                          pixels[i].detail < 0.62 else { continue }
                    let around = neighbors(i, diagonals: true)
                    let adjacentFill = around.filter { !strokes[$0] }
                    guard adjacentFill.count >= 2, adjacentFill.allSatisfy({ j in
                        let p = pixels[j]
                        return p.alpha > 0 && p.color.x > 0.85 && abs(p.color.y) + abs(p.color.z) < 0.10
                    }) else { continue }
                    let whiteCount = adjacentFill.count { j in
                        let color = pixels[j].color
                        return color.x > 0.965 && abs(color.y) + abs(color.z) < 0.022
                    }
                    guard whiteCount * 2 < adjacentFill.count else { continue }
                    let connected = around.filter { strokes[$0] }
                    var reached = Set(connected.prefix(1))
                    for _ in connected {
                        let previous = reached
                        for j in connected where !previous.contains(j) {
                            if previous.contains(where: { n in
                                abs(n % width - j % width) <= 1 && abs(n / width - j / width) <= 1
                            }) { reached.insert(j) }
                        }
                        if previous.count == reached.count { break }
                    }
                    if reached.count == connected.count {
                        strokes[i] = false
                        let sum = adjacentFill.reduce(SIMD3<Float>.zero) { $0 + pixels[$1].color }
                        pixels[i].color = sum / Float(adjacentFill.count)
                    }
                }
            }
        }
        if thinInk {
            try thinSpriteInk(&strokes, pixels: &pixels, width: width, height: height)
        }
        let hasInk = strokes.contains(true)
        let hasWhite = whiteWeight >= sampleCount && (!hasInk || colors > 2)
        var palette: [SIMD3<Float>] = []
        if hasInk { palette.append(inkTotal / inkWeight) }
        let whiteIndex = hasWhite ? palette.count : -1
        if hasWhite { palette.append(whiteTotal / whiteWeight) }
        let fillStart = palette.count
        let fills = opaque.compactMap { i -> Pixel? in
            guard !strokes[i], !hasWhite || distanceSquared(pixels[i].color, palette[whiteIndex]) > 0.00034 else { return nil }
            // Learn colors from the interiors first. Mixed edge samples otherwise
            // spend the limited palette on muddy intermediate tones.
            let weight: Float = pixels[i].detail < 0.10 ? 1 : 0.12
            return Pixel(color: pixels[i].color, alpha: weight)
        }
        if fillStart < colors {
            palette += try buildPalette(from: fills, count: colors - fillStart)
        }
        var labels = Array(repeating: -1, count: pixels.count)
        let fillPalette = Array(palette.dropFirst(hasInk && palette.count > 1 ? 1 : 0))
        let fillOffset = palette.count - fillPalette.count
        for i in opaque {
            labels[i] = strokes[i] ? 0 : nearest(pixels[i].color, in: fillPalette) + fillOffset
        }

        let initial = labels
        for i in opaque {
            let label = initial[i]
            guard label != whiteIndex, !(hasInk && label == 0) else { continue }
            let adjacent = neighbors(i)
            let surrounding = neighbors(i, diagonals: true)
            var votes = [Int](repeating: 0, count: palette.count)
            for j in surrounding {
                let candidate = initial[j]
                if candidate >= fillOffset { votes[candidate] += adjacent.contains(j) ? 2 : 1 }
            }
            guard let best = votes.indices.max(by: { votes[$0] < votes[$1] }) else { continue }
            let whiteFringe = best == whiteIndex && votes[best] >= 4 && votes[label] <= 2
                && adjacent.allSatisfy { initial[$0] == label || initial[$0] == whiteIndex || initial[$0] < fillOffset }
            let isolated = votes[label] <= 1 && votes[best] >= 6
            if whiteFringe || isolated { labels[i] = best }
        }
        if fineDetail && hasWhite {
            try blendSmallPalePatches(&labels, palette: palette, whiteIndex: whiteIndex,
                                      width: width, height: height, skipInk: hasInk)
        }
        if fineDetail {
            try keepFillHues(&labels, palette: palette, evidence: fillHues, width: width,
                             height: height, fillOffset: fillOffset)
        }
        if paletteStyle == .berryInk {
            palette = palette.enumerated().map { index, color in
                berrySwatch(color, isInk: hasInk && index == 0)
            }
        }
        if shadeWhiteEdge && hasInk && hasWhite && palette.count < 64 {
            try shadeWhiteSilhouette(&labels, palette: &palette, whiteIndex: whiteIndex,
                                     width: width, height: height)
        }
        return (pixels, palette, labels)
    }

    private static func keepFillHues(
        _ labels: inout [Int], palette: [SIMD3<Float>], evidence: [SIMD3<Float>],
        width: Int, height: Int, fillOffset: Int
    ) throws {
        let hues = palette.map { SIMD2($0.y, $0.z) }
        let strengths = hues.map { simd_length($0) }
        let initial = labels
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                let i = y * width + x
                let source = evidence[i]
                let label = initial[i]
                guard label >= fillOffset, source.x > 0 else { continue }
                let hue = SIMD2(source.y, source.z)
                let strength = simd_length(hue)
                func matches(_ color: Int) -> Bool {
                    strengths[color] >= 0.026 && simd_dot(hue, hues[color]) >= 0.77 * strength * strengths[color]
                }
                guard !matches(label) else { continue }

                // A swatch must already represent this hue in the immediate neighborhood.
                var best = label
                var bestDistance = Float.infinity
                var supportingNeighbors = 0
                for v in max(0, y - 1)...min(height - 1, y + 1) {
                    for u in max(0, x - 1)...min(width - 1, x + 1) {
                        let candidate = initial[v * width + u]
                        guard candidate >= fillOffset, matches(candidate),
                              abs(source.x - palette[candidate].x) < 0.16 else { continue }
                        supportingNeighbors += 1
                        let distance = distanceSquared(source, palette[candidate])
                        if distance < bestDistance {
                            bestDistance = distance
                            best = candidate
                        }
                    }
                }
                if supportingNeighbors >= 2 { labels[i] = best }
            }
        }
    }

    private static func shadeWhiteSilhouette(
        _ labels: inout [Int], palette: inout [SIMD3<Float>], whiteIndex: Int,
        width: Int, height: Int
    ) throws {
        guard width > 2, height > 2,
              let first = labels.firstIndex(where: { $0 >= 0 }),
              let last = labels.lastIndex(where: { $0 >= 0 }) else { return }
        let top = first / width
        let bottom = last / width
        // Focus on lower white regions and keep facial highlights above the band.
        let bodyTop = top + (bottom - top) * 3 / 5
        let sides = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        func cell(_ x: Int, _ y: Int) -> Int? {
            guard (0..<width).contains(x), (0..<height).contains(y) else { return nil }
            return y * width + x
        }
        func isWhite(_ label: Int) -> Bool {
            guard label > 0 else { return false }
            let color = palette[label]
            return color.x >= 0.94 && abs(color.y) + abs(color.z) <= 0.034
        }

        // Walk only through ink, so the band follows the fill-facing side of the outline.
        var outline = Array(repeating: false, count: labels.count)
        var frontier: [Int] = []
        for i in labels.indices where labels[i] == 0 {
            let x = i % width, y = i / width
            if sides.contains(where: { dx, dy in cell(x + dx, y + dy).map { labels[$0] < 0 } ?? true }) {
                outline[i] = true
                frontier.append(i)
            }
        }
        for _ in 0..<2 {
            try Task.checkCancellation()
            var next: [Int] = []
            for i in frontier {
                let x = i % width, y = i / width
                for (dx, dy) in sides {
                    guard let j = cell(x + dx, y + dy), labels[j] == 0, !outline[j] else { continue }
                    outline[j] = true
                    next.append(j)
                }
            }
            frontier = next
        }

        var white = labels.map(isWhite)
        var regions: [[Int]] = []
        for i in (bodyTop * width)..<white.count where white[i] {
            try Task.checkCancellation()
            var region = [i]
            white[i] = false
            var head = 0
            while head < region.count {
                let j = region[head]
                head += 1
                for (dx, dy) in sides {
                    guard let next = cell(j % width + dx, j / width + dy),
                          next / width >= bodyTop, white[next] else { continue }
                    white[next] = false
                    region.append(next)
                }
            }
            regions.append(region)
        }
        let largest = regions.map(\.count).max() ?? 0
        var body = Array(repeating: false, count: labels.count)
        for region in regions where region.count >= max(4, largest / 4) {
            for i in region { body[i] = true }
        }

        var band = Array(repeating: false, count: labels.count)
        for y in bodyTop..<height {
            try Task.checkCancellation()
            for x in 0..<width where body[y * width + x] {
                band[y * width + x] = sides.contains { dx, dy in
                    guard let ink = cell(x + dx, y + dy), outline[ink],
                          let inside = cell(x - dx, y - dy) else { return false }
                    return body[inside]
                }
            }
        }

        // Reduce the previous shade's distance from the white fill by 20 percent.
        let inkShare: Float = 0.16 * 0.8
        let shade = palette[0] * inkShare + palette[whiteIndex] * (1 - inkShare)
        let shadeIndex = palette.count
        // Discard isolated fragments rather than placing single tinted specks.
        for i in band.indices where band[i] {
            try Task.checkCancellation()
            var run = [i]
            band[i] = false
            var head = 0
            while head < run.count {
                let j = run[head]
                let x = j % width, y = j / width
                head += 1
                for v in max(0, y - 1)...min(height - 1, y + 1) {
                    for u in max(0, x - 1)...min(width - 1, x + 1) where band[v * width + u] {
                        let neighbor = v * width + u
                        band[neighbor] = false
                        run.append(neighbor)
                    }
                }
            }
            if run.count >= 3 {
                for j in run { labels[j] = shadeIndex }
            }
        }
        if labels.contains(shadeIndex) { palette.append(shade) }
    }

    private static func thinSpriteInk(
        _ strokes: inout [Bool], pixels: inout [Pixel], width: Int, height: Int
    ) throws {
        guard width > 2, height > 2 else { return }
        let ringOffsets = [-width, 1 - width, 1, 1 + width, width, width - 1, -1, -1 - width]
        let candidates = strokes.indices.filter { i in
            let x = i % width, y = i / width
            return x > 0 && x + 1 < width && y > 0 && y + 1 < height && strokes[i] && pixels[i].detail < 0.82
        }.sorted { pixels[$0].detail < pixels[$1].detail }
        let originalStrokes = strokes
        // Revisit corners that a later removal exposed in the first pass.
        for _ in 0..<2 {
            for (order, i) in candidates.enumerated() {
                if order % 256 == 0 { try Task.checkCancellation() }
                guard strokes[i] else { continue }
                let neighbors = ringOffsets.map { i + $0 }
                let sides = [neighbors[0], neighbors[2], neighbors[4], neighbors[6]]
                // Leave the outside edge and the tip of each line in place.
                guard sides.allSatisfy({ pixels[$0].alpha > 0 }) else { continue }
                // Removing a pixel with three ink sides cuts a notch into the edge.
                guard sides.count(where: { strokes[$0] }) <= 2 else { continue }
                let fill = sides.filter { !originalStrokes[$0] }
                guard !fill.isEmpty else { continue }
                let ring = neighbors.map { strokes[$0] }
                guard ring.count(where: { $0 }) >= 3 else { continue }
                let entries = ring.indices.count { !ring[$0] && ring[($0 + 1) % ring.count] }
                guard entries == 1 else { continue }
                let color = pixels[i].color
                let white = fill.filter { pixels[$0].color.x > 0.965 && abs(pixels[$0].color.y) + abs(pixels[$0].color.z) < 0.022 }
                // Preserve small marks that sit on white, such as a mouth.
                if white.count >= 2 && white.count == fill.count { continue }
                let replacement = white.count >= 2 ? white.first : fill.min { a, b in
                    distanceSquared(color, pixels[a].color) < distanceSquared(color, pixels[b].color)
                }
                if let replacement {
                    pixels[i].color = pixels[replacement].color
                    strokes[i] = false
                }
            }
        }
    }

    private static func berrySwatch(_ color: SIMD3<Float>, isInk: Bool) -> SIMD3<Float> {
        if isInk {
            return SIMD3(max(0.257, min(color.x, 0.33)), 0.043, -0.042)
        }
        let chroma = (color.y * color.y + color.z * color.z).squareRoot()
        let strength = min(1, max(0, (chroma - 0.017) / 0.038))
        let shadow = min(1, max(0, (0.87 - color.x) / 0.40))
        let violet = color.y > 0.018 && color.z < -0.022 && -color.z > color.y * 0.5
        let pink = color.y > 0.035 && abs(color.z) <= color.y * 0.5
        if violet {
            return color + SIMD3((color.x - 0.67) * 0.16, color.y * 0.13, color.z * 0.35 - 0.007) * strength
        }
        if pink {
            return color + SIMD3((color.x - 0.77) * 0.12, color.y * 0.17 + 0.008, -0.007 - 0.017 * shadow) * strength
        }
        // A small cool shift in chromatic shadows brings the non-pink ramps into the same palette.
        return color + SIMD3(0, color.y * 0.15 + 0.012 * shadow, color.z * 0.15 - 0.016 * shadow) * strength
    }

    private static func blendSmallPalePatches(
        _ labels: inout [Int], palette: [SIMD3<Float>], whiteIndex: Int,
        width: Int, height: Int, skipInk: Bool
    ) throws {
        // Preserve the major white shapes and bright accents in dark colors.
        // A white patch inside a nearby pale fill can use that fill's swatch.
        let pale = palette.indices.filter {
            $0 != whiteIndex && (!skipInk || $0 != 0) && palette[$0].x >= 0.88
                && distanceSquared(palette[$0], palette[whiteIndex]) < 0.005
        }
        guard !pale.isEmpty else { return }
        let possibleColors = Set(pale)
        var visited = [Bool](repeating: false, count: labels.count)
        var patches: [(cells: [Int], replacement: Int?)] = []
        var largest = 0
        for i in labels.indices where labels[i] == whiteIndex && !visited[i] {
            try Task.checkCancellation()
            var cells = [i]
            visited[i] = true
            var touchesExterior = false
            var contacts = [Int](repeating: 0, count: palette.count)
            var head = 0
            while head < cells.count {
                let j = cells[head]
                let x = j % width, y = j / width
                let neighbors = [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)]
                for (u, v) in neighbors {
                    guard (0..<width).contains(u), (0..<height).contains(v) else {
                        touchesExterior = true
                        continue
                    }
                    let n = v * width + u
                    let color = labels[n]
                    if color == whiteIndex {
                        if !visited[n] { visited[n] = true; cells.append(n) }
                    } else if color < 0 {
                        touchesExterior = true
                    } else if !skipInk || color != 0 {
                        contacts[color] += 1
                    }
                }
                head += 1
            }
            largest = max(largest, cells.count)
            let best = contacts.indices.max { contacts[$0] < contacts[$1] }
            let replacement = best.flatMap { index in
                !touchesExterior && possibleColors.contains(index) && contacts[index] >= 4
                    && contacts[index] * 3 >= contacts.reduce(0, +) * 2 ? index : nil
            }
            patches.append((cells, replacement))
        }
        for patch in patches where patch.cells.count <= min(largest / 4, max(4, labels.count / 40)) {
            if let replacement = patch.replacement {
                for i in patch.cells { labels[i] = replacement }
            }
        }
    }
}
