import CoreGraphics
import Foundation
import simd

/// 원본 대조 보정으로 고친 칸 수예요.
struct CorrectionSummary: Equatable, Sendable {
    var restoredLines = 0
    var removedLines = 0
    var fixedColors = 0

    var total: Int { restoredLines + removedLines + fixedColors }
    var label: String {
        guard total > 0 else { return "원본과 대조했어요 · 고칠 칸이 없어요" }
        var parts: [String] = []
        if restoredLines > 0 { parts.append("선 \(restoredLines)칸 복원") }
        if removedLines > 0 { parts.append("헛선 \(removedLines)칸 정리") }
        if fixedColors > 0 { parts.append("색 \(fixedColors)칸 바로잡음") }
        return parts.joined(separator: " · ")
    }
}

/// 변환이 끝난 결과를 원본과 칸마다 대조해서, 빠진 선과 잘못 고른 색을 바로잡아요.
///
/// - 결과의 칸 하나마다 원본의 같은 자리를 8×8로 다시 읽어요(변환 때와 같은 배경 정리·맞춤 위치·격자 이동).
/// - 빠진 선: 원본엔 어두운 선이 18% 이상인데 결과에서 끊긴 칸 중, 양쪽 반대편에 선이 있어 틈을 잇는 칸만 메워요.
///   선이 두꺼워지지 않게 2×2 덩어리가 생기는 칸은 빼요. 원본이 절반 이상 꽉 찬 검정이면 바로 채워요.
/// - 헛선: 결과는 선인데 원본엔 어두운 게 거의 없는 칸은 주변에서 가장 알맞은 색으로 바꿔요.
/// - 틀린 색: 팔레트 색마다 원본에서 무슨 색을 대신하는지 먼저 잡고(베리 잉크처럼 색을 바꾼 스타일도 비교 가능),
///   칸의 원본 색이 지금 색과 많이 다르고 다른 팔레트 색이 훨씬 맞으면 바꿔요.
///   지금 색이 원본 칸 안에 20% 이상 있으면 하이라이트 같은 작은 디테일이라 그대로 둬요.
enum SourceCheck {
    private static let side = 8

    struct Frame: Sendable {
        let width: Int
        let height: Int
        let xOffset: Int
        let yOffset: Int
        /// 변환에 쓴 격자 이동(¼칸 단위, Core Graphics 좌표: x 오른쪽, y 위쪽)
        let shift: SIMD2<Int>
        var dimensions: SIMD2<Int> { SIMD2(width, height) }
    }

    static func frame(for source: SourceImage, size: PixelSize, shift: SIMD2<Int>) -> Frame {
        let scale = min(Double(size.width) / Double(source.size.width), Double(size.height) / Double(source.size.height))
        let width = max(1, min(size.width, Int((Double(source.size.width) * scale).rounded())))
        let height = max(1, min(size.height, Int((Double(source.size.height) * scale).rounded())))
        return Frame(width: width, height: height, xOffset: (size.width - width) / 2,
                     yOffset: (size.height - height) / 2, shift: shift)
    }

    /// 칸마다 원본에서 읽은 값이에요.
    struct Evidence: Sendable {
        let frame: Frame
        let dark: [Float]          // 어두운 선 비율
        let color: [SIMD3<Float>]  // 선이 아닌 부분에서 가장 흔한 색
        let opaque: [Bool]
        let samples: [[SIMD3<Float>]]  // 칸 안의 불투명 표본 (작은 디테일 확인용)
    }

    /// cells: 결과 그림이 실제로 쓴 칸 수(가로, 세로). AI로 키운 그림으로 변환하면 배경을 잘라낸 비율이 원본과
    /// 1칸쯤 달라질 수 있어서, 원본을 그 칸 수에 맞춰 읽어요. (안 맞추면 보정이 통째로 건너뛰거나 1칸 어긋나요)
    static func evidence(prepared: SourceImage, size: PixelSize, shift: SIMD2<Int>, cells: SIMD2<Int>? = nil) throws -> Evidence {
        let frame = cells.map { Frame(width: $0.x, height: $0.y, xOffset: (size.width - $0.x) / 2,
                                      yOffset: (size.height - $0.y) / 2, shift: shift) }
            ?? frame(for: prepared, size: size, shift: shift)
        let w = frame.width, h = frame.height
        // 변환은 4×4 표본 기준으로 shift칸 옮겼으니, 8×8에서는 두 배만큼 옮겨요.
        let context = try PixelConverter.rasterize(
            prepared.image, width: w * side, height: h * side,
            rect: CGRect(x: shift.x * 2, y: shift.y * 2, width: w * side, height: h * side))
        guard let data = context.data else { throw ConversionError.cannotRender }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let stride = context.bytesPerRow
        var dark = [Float](repeating: 0, count: w * h)
        var color = [SIMD3<Float>](repeating: .zero, count: w * h)
        var opaque = [Bool](repeating: false, count: w * h)
        var samples = [[SIMD3<Float>]](repeating: [], count: w * h)
        for cy in 0..<h {
            try Task.checkCancellation()
            for cx in 0..<w {
                var points: [SIMD3<Float>] = []
                var sparse: [SIMD3<Float>] = []
                points.reserveCapacity(side * side)
                for sy in 0..<side {
                    for sx in 0..<side {
                        let offset = (cy * side + sy) * stride + (cx * side + sx) * 4
                        let alpha = Int(bytes[offset + 3])
                        guard alpha > 127 else { continue }
                        let lab = MapleRamp.decodeLab(bytes.advanced(by: offset), alpha: alpha)
                        points.append(lab)
                        // 작은 디테일 확인용은 16개만 남겨 메모리를 아껴요
                        if sx % 2 == 0 && sy % 2 == 0 { sparse.append(lab) }
                    }
                }
                let i = cy * w + cx
                let coverage = Float(points.count) / Float(side * side)
                opaque[i] = coverage >= 0.5
                guard !points.isEmpty else { continue }
                let darkPoints = points.filter(isDark)
                dark[i] = Float(darkPoints.count) / Float(points.count) * coverage
                let body = points.count - darkPoints.count >= 4 ? points.filter { !isDark($0) } : points
                color[i] = commonest(body)
                samples[i] = sparse
            }
        }
        return Evidence(frame: frame, dark: dark, color: color, opaque: opaque, samples: samples)
    }

    static func isDark(_ c: SIMD3<Float>) -> Bool {
        let chroma = simd_length(SIMD2(c.y, c.z))
        return (c.x < 0.42 && chroma < 0.06) || (c.x < 0.36 && chroma < 0.12)
    }

    private static func commonest(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
        var bins: [SIMD3<Int32>: (total: SIMD3<Float>, count: Int)] = [:]
        for p in points {
            let key = SIMD3<Int32>(Int32((p.x / 0.04).rounded()), Int32((p.y / 0.03).rounded()), Int32((p.z / 0.03).rounded()))
            let old = bins[key] ?? (.zero, 0)
            bins[key] = (old.total + p, old.count + 1)
        }
        // 개수가 같으면 칸 번호로 정해요. (사전 순서는 실행마다 바뀌어서 결과가 흔들려요)
        let best = bins.max { a, b in
            a.value.count != b.value.count ? a.value.count < b.value.count
                : (a.key.x, a.key.y, a.key.z) > (b.key.x, b.key.y, b.key.z)
        }!.value
        return best.total / Float(best.count)
    }

    /// 칸마다 고를 색 번호를 받아 고친 번호를 돌려줘요. -1은 투명이에요.
    /// - palette: 번호별 OKLab 색
    /// - lineLabels: 선으로 쓸 수 있는 번호예요. nil이면 어두운 색 전부예요. (메이플 램프는 윤곽선 번호만)
    /// - keepWideDark: 넓게 어두운 면(검은 모자·옷)은 선으로 덮지 않아요. 메이플 램프가 그 면을 재질로 남겨 음영을 지키거든요.
    static func correct(_ labels: [Int], palette: [SIMD3<Float>], evidence: Evidence,
                        lineLabels: [Int]? = nil, keepWideDark: Bool = false,
                        summary: inout CorrectionSummary) -> [Int] {
        let w = evidence.frame.width, h = evidence.frame.height
        var result = labels
        guard !palette.isEmpty, labels.count == w * h else { return labels }
        let inkCandidates = lineLabels ?? palette.indices.filter { isDark(palette[$0]) }
        let ink = inkCandidates.min { palette[$0].x < palette[$1].x }
        // 주변 5×5칸 원본의 평균 어두운 비율이에요. 0.45를 넘으면 선이 아니라 면이에요. (MapleRamp 윤곽선 판단과 같은 기준)
        var wideDark = [Bool](repeating: false, count: w * h)
        if keepWideDark {
            for y in 0..<h {
                for x in 0..<w {
                    var total: Float = 0, cells = 0
                    for v in max(0, y - 2)...min(h - 1, y + 2) {
                        for u in max(0, x - 2)...min(w - 1, x + 2) { total += evidence.dark[v * w + u]; cells += 1 }
                    }
                    wideDark[y * w + x] = total / Float(cells) > 0.45
                }
            }
        }

        // 팔레트 색마다 원본에서 대신하는 색
        var sums = [SIMD3<Float>](repeating: .zero, count: palette.count)
        var counts = [Int](repeating: 0, count: palette.count)
        for i in labels.indices where labels[i] >= 0 && evidence.opaque[i] {
            sums[labels[i]] += evidence.color[i]; counts[labels[i]] += 1
        }
        let meaning = palette.indices.map { counts[$0] > 0 ? sums[$0] / Float(counts[$0]) : palette[$0] }

        func label(_ x: Int, _ y: Int) -> Int { (0..<w).contains(x) && (0..<h).contains(y) ? labels[y * w + x] : -1 }

        if let ink {
            func line(_ x: Int, _ y: Int) -> Bool { label(x, y) == ink }
            let pairs = [((-1, 0), (1, 0)), ((0, -1), (0, 1)), ((-1, -1), (1, 1)), ((-1, 1), (1, -1))]
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    guard labels[i] >= 0, labels[i] != ink, !wideDark[i] else { continue }
                    let f = evidence.dark[i]
                    let bridge = pairs.contains { a, b in line(x + a.0, y + a.1) && line(x + b.0, y + b.1) }
                    let block = [(-1, -1), (-1, 1), (1, -1), (1, 1)].contains { dx, dy in
                        line(x + dx, y) && line(x, y + dy) && line(x + dx, y + dy)
                    }
                    if f >= 0.5 || (f >= 0.18 && bridge && !block) {
                        result[i] = ink
                        summary.restoredLines += 1
                    }
                }
            }
            for y in 0..<h {
                for x in 0..<w {
                    let i = y * w + x
                    guard labels[i] == ink, evidence.dark[i] < 0.03, evidence.opaque[i] else { continue }
                    var candidates: Set<Int> = []
                    for v in max(0, y - 1)...min(h - 1, y + 1) {
                        for u in max(0, x - 1)...min(w - 1, x + 1) {
                            let l = labels[v * w + u]
                            if l >= 0 && l != ink { candidates.insert(l) }
                        }
                    }
                    if let best = candidates.min(by: {
                        simd_distance(meaning[$0], evidence.color[i]) < simd_distance(meaning[$1], evidence.color[i])
                    }) {
                        result[i] = best
                        summary.removedLines += 1
                    }
                }
            }
        }

        let fills = palette.indices.filter { $0 != ink }
        for i in result.indices {
            let current = result[i]
            guard current >= 0, current != ink, evidence.dark[i] < 0.35, evidence.opaque[i], !fills.isEmpty else { continue }
            let c = evidence.color[i]
            guard simd_distance(meaning[current], c) > 0.10 else { continue }
            let points = evidence.samples[i]
            let present = points.isEmpty ? 0 : Float(points.count { simd_distance($0, meaning[current]) < 0.08 }) / Float(points.count)
            guard present < 0.2 else { continue }
            let best = fills.min { simd_distance(meaning[$0], c) < simd_distance(meaning[$1], c) }!
            if best != current && simd_distance(meaning[best], c) <= 0.07 {
                result[i] = best
                summary.fixedColors += 1
            }
        }
        return result
    }

    /// 완성된 결과 이미지(기본 도트·게임 스프라이트)를 대조해서 고쳐요.
    static func apply(to conversion: Conversion, prepared: SourceImage, size: PixelSize, shift: SIMD2<Int>,
                      cells: SIMD2<Int>? = nil) throws -> (Conversion, CorrectionSummary) {
        let evidence = try evidence(prepared: prepared, size: size, shift: shift, cells: cells)
        let f = evidence.frame
        guard var bytes = PixelExport.rgbaBytes(conversion.pixelArt), conversion.pixelArt.width == size.width else {
            return (conversion, CorrectionSummary())
        }
        // 칸 색 → 번호
        var keys: [UInt32: Int] = [:]
        var palette: [SIMD3<Float>] = []
        var rgbOf: [SIMD3<UInt8>] = []
        var labels = [Int](repeating: -1, count: f.width * f.height)
        for cy in 0..<f.height {
            for cx in 0..<f.width {
                let offset = ((cy + f.yOffset) * size.width + cx + f.xOffset) * 4
                let alpha = Int(bytes[offset + 3])
                guard alpha > 127 else { continue }
                let rgb = SIMD3<UInt8>((0..<3).map { UInt8(min(255, (Int(bytes[offset + $0]) * 255 + alpha / 2) / alpha)) })
                let key = (UInt32(rgb.x) << 16) | (UInt32(rgb.y) << 8) | UInt32(rgb.z)
                if keys[key] == nil {
                    keys[key] = palette.count
                    var full: [UInt8] = [rgb.x, rgb.y, rgb.z, 255]
                    palette.append(full.withUnsafeMutableBufferPointer { MapleRamp.decodeLab(UnsafePointer($0.baseAddress!), alpha: 255) })
                    rgbOf.append(rgb)
                }
                labels[cy * f.width + cx] = keys[key]!
            }
        }
        var summary = CorrectionSummary()
        let fixed = correct(labels, palette: palette, evidence: evidence, summary: &summary)
        guard summary.total > 0 else { return (conversion, summary) }
        for i in fixed.indices where fixed[i] != labels[i] && fixed[i] >= 0 {
            let cx = i % f.width, cy = i / f.width
            let offset = ((cy + f.yOffset) * size.width + cx + f.xOffset) * 4
            let rgb = rgbOf[fixed[i]]
            bytes[offset] = rgb.x; bytes[offset + 1] = rgb.y; bytes[offset + 2] = rgb.z; bytes[offset + 3] = 255
        }
        guard let image = PixelExport.image(from: bytes, width: size.width, height: size.height) else {
            return (conversion, CorrectionSummary())
        }
        var used: Set<UInt32> = []
        for offset in Swift.stride(from: 0, to: bytes.count, by: 4) where bytes[offset + 3] > 0 {
            used.insert((UInt32(bytes[offset]) << 16) | (UInt32(bytes[offset + 1]) << 8) | UInt32(bytes[offset + 2]))
        }
        return (Conversion(size: conversion.size, baseline: conversion.baseline, pixelArt: image, colorCount: used.count), summary)
    }

    /// 메이플 램프는 재질·음영 지도를 직접 고쳐서, 색을 바꿔도 보정이 유지되게 해요.
    static func apply(to sprite: MapleSprite, prepared: SourceImage) throws -> (MapleSprite, CorrectionSummary) {
        let evidence = try evidence(prepared: prepared, size: sprite.size, shift: .zero,
                                    cells: SIMD2(sprite.width, sprite.height))
        // (재질, 단계) 쌍마다 번호를 매겨요. 윤곽선(단계 -1)은 진한 잉크면 하나로 묶어요.
        var pairs: [SIMD2<Int32>: Int] = [:]
        var palette: [SIMD3<Float>] = []
        var pairOf: [SIMD2<Int32>] = []
        var labels = [Int](repeating: -1, count: sprite.material.count)
        for i in sprite.material.indices where sprite.material[i] >= 0 {
            let m = sprite.material[i], t = sprite.tone[i]
            let key = SIMD2<Int32>(t < 0 && sprite.fixedOutline ? -1 : Int32(m), Int32(t))
            if pairs[key] == nil {
                pairs[key] = palette.count
                palette.append(sprite.color(material: m, tone: t, adjust: MaterialAdjust()))
                pairOf.append(key)
            }
            labels[i] = pairs[key]!
        }
        var summary = CorrectionSummary()
        // 선은 윤곽선(단계 -1)으로만 이어요. 가장 어두운 '재질'(검은 모자 등)을 선으로 쓰면 음영이 지워지고 색 바꾸기도 꼬여요.
        let outlineLabels = pairOf.indices.filter { pairOf[$0].y < 0 }
        let fixed = correct(labels, palette: palette, evidence: evidence, lineLabels: outlineLabels, keepWideDark: true,
                            summary: &summary)
        guard summary.total > 0 else { return (sprite, summary) }
        var material = sprite.material, tone = sprite.tone
        for i in fixed.indices where fixed[i] != labels[i] && fixed[i] >= 0 {
            let pair = pairOf[fixed[i]]
            if pair.y < 0 {
                // 윤곽선으로: 진한 잉크면 지금 재질의 윤곽선, 아니면 그 윤곽선 재질
                if pair.x >= 0 { material[i] = Int(pair.x) }
                tone[i] = -1
            } else {
                material[i] = Int(pair.x)
                tone[i] = Int(pair.y)
            }
        }
        var counts = [Int](repeating: 0, count: sprite.materialCount)
        for m in material where m >= 0 { counts[m] += 1 }
        let corrected = MapleSprite(size: sprite.size, width: sprite.width, height: sprite.height,
                                    xOffset: sprite.xOffset, yOffset: sprite.yOffset, material: material, tone: tone,
                                    ramps: sprite.ramps, outlines: sprite.outlines, counts: counts,
                                    baseline: sprite.baseline, fixedOutline: sprite.fixedOutline)
        return (corrected, summary)
    }
}
