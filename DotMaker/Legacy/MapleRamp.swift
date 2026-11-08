import CoreGraphics
import Foundation
import simd

/// 윤곽선을 어떻게 칠할지예요.
enum OutlineStyle: String, CaseIterable, Sendable {
    case ink = "진한 잉크 윤곽선"
    case material = "재질 색 윤곽선"
    case none = "윤곽선 없음"
}

/// 메이플 램프 모드의 설정이에요.
struct MapleOptions: Equatable, Sendable {
    var materials = 8
    var tones = 3
    var outlineStyle = OutlineStyle.ink
    /// 큰 재질끼리 맞닿는 곳에도 선을 그어 물건·부위를 나눠요.
    var boundary = true
    var hueShift = true
    /// 가는 안쪽 선을 잉크 대신 재질의 어두운 색으로 칠해요. (진한 잉크 윤곽선일 때만)
    var softInnerLines = false
    /// 목표 스타일(사용자가 준 메이플 예시): 거의 순검정 잉크, 흰색 그림자는 따뜻한 베이지
    var targetStyle = false
}

/// 재질 하나의 색 조정값이에요. 램프 전체와 윤곽선이 함께 바뀌어요.
struct MaterialAdjust: Equatable, Sendable {
    /// 색상 회전(도)
    var hue: Double = 0
    /// 채도 배율
    var saturation: Double = 1
    /// 밝기 이동 (OKLab L)
    var lightness: Double = 0

    var isIdentity: Bool { hue == 0 && saturation == 1 && lightness == 0 }
}

/// 재질과 음영 단계로 나눈 결과예요. 색만 바꿀 때는 다시 변환하지 않고 이것으로 바로 그려요.
struct MapleSprite: Sendable {
    let size: PixelSize
    let width: Int
    let height: Int
    let xOffset: Int
    let yOffset: Int
    /// 칸마다 재질 번호, 투명이면 -1
    let material: [Int]
    /// 칸마다 음영 단계(0이 가장 어두움), 윤곽선이면 -1
    let tone: [Int]
    /// 재질마다 어두운 순서의 램프 색 (OKLab)
    let ramps: [[SIMD3<Float>]]
    /// 재질마다 윤곽선 색 (OKLab)
    let outlines: [SIMD3<Float>]
    /// 재질마다 쓰인 칸 수
    let counts: [Int]
    let baseline: CGImage
    /// 진한 잉크 윤곽선은 색을 바꿔도 그대로 둬요.
    var fixedOutline = false
    /// 선 바로 안쪽 1칸(선과 그림 사이 중간색을 칠할 칸)이에요. 비어 있으면 안 칠해요.
    var rim: [Bool] = []
    /// 중간색에 섞을 선 색 비율이에요. 0.2면 그림 80% + 선 20%예요.
    var rimInk: Float = 0

    var materialCount: Int { ramps.count }

    /// 재질의 대표 색(가운데 단계)이에요. 비슷한 재질끼리 조정값을 이어받을 때 써요.
    func baseColor(_ index: Int) -> SIMD3<Float> {
        let ramp = ramps[index]
        return ramp[ramp.count / 2]
    }

    /// 검정·흰색·회색처럼 색이 거의 없는 재질이에요. 색상을 돌려도 변하지 않아서 물들이기로 처리해요.
    func isNeutral(_ index: Int) -> Bool {
        let base = baseColor(index)
        return simd_length(SIMD2(base.y, base.z)) < 0.03
    }

    func color(material index: Int, tone level: Int, adjust: MaterialAdjust) -> SIMD3<Float> {
        if level < 0 && fixedOutline { return outlines[index] }
        let lab = level >= 0 ? ramps[index][level] : outlines[index]
        return MapleRamp.adjusted(lab, adjust, neutral: isNeutral(index))
    }

    func render(_ adjusts: [MaterialAdjust]) throws -> Conversion {
        let output = try PixelConverter.rasterize(nil, width: size.width, height: size.height, rect: .zero)
        guard let data = output.data else { throw ConversionError.cannotRender }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        // 재질×단계별 색을 미리 계산해요.
        let table: [[SIMD3<UInt8>]] = ramps.indices.map { m in
            let adjust = m < adjusts.count ? adjusts[m] : MaterialAdjust()
            let neutral = isNeutral(m)
            let line = MapleRamp.encode(fixedOutline ? outlines[m] : MapleRamp.adjusted(outlines[m], adjust, neutral: neutral))
            return [line] + ramps[m].map { MapleRamp.encode(MapleRamp.adjusted($0, adjust, neutral: neutral)) }
        }
        // 선 안쪽 중간색: 그림 80% + 선 20%를 섞은 색에 가장 가까운 '같은 재질의 더 어두운 단계'를 써요.
        // 새 색을 만들지 않아서 색 수가 늘지 않고, 메이플 도트처럼 테두리 안쪽에 한 단계 어두운 띠가 생겨요. (원탁회의 결론 3번)
        // 이미 가장 어두운 단계면 그대로 둬요.
        let rimTable: [[SIMD3<UInt8>]] = rim.isEmpty ? [] : ramps.indices.map { m in
            let adjust = m < adjusts.count ? adjusts[m] : MaterialAdjust()
            let neutral = isNeutral(m)
            let line = fixedOutline ? outlines[m] : MapleRamp.adjusted(outlines[m], adjust, neutral: neutral)
            let shades = ramps[m].map { MapleRamp.adjusted($0, adjust, neutral: neutral) }
            return shades.indices.map { t in
                let mixed = shades[t] * (1 - rimInk) + line * rimInk
                let darker = (0..<t).min { simd_distance(shades[$0], mixed) < simd_distance(shades[$1], mixed) }
                return MapleRamp.encode(shades[darker ?? t])
            }
        }
        var used: Set<UInt32> = []
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let m = material[i]
                guard m >= 0 else { continue }
                let rgb = !rim.isEmpty && rim[i] && tone[i] >= 0 ? rimTable[m][tone[i]] : table[m][tone[i] + 1]
                let offset = (y + yOffset) * output.bytesPerRow + (x + xOffset) * 4
                bytes[offset] = rgb.x
                bytes[offset + 1] = rgb.y
                bytes[offset + 2] = rgb.z
                bytes[offset + 3] = 255
                used.insert((UInt32(rgb.x) << 16) | (UInt32(rgb.y) << 8) | UInt32(rgb.z))
            }
        }
        guard let image = output.makeImage() else { throw ConversionError.cannotRender }
        return Conversion(size: size, baseline: baseline, pixelArt: image, colorCount: used.count)
    }
}

/// 메이플식 도트 변환: 재질 → 재질별 음영 램프 → 색 있는 윤곽선.
///
/// 1. 원본을 4×4 표본으로 나눠 칸마다 가장 대표적인 실제 표본 색을 골라요(평균을 쓰지 않아 경계가 또렷해요).
/// 2. 밝기는 약하게, 색 계열은 강하게 보고 k-평균으로 재질을 나눠요. 무채색은 밝기로 갈라요.
/// 3. 재질마다 밝기만 2~5단계로 나눠 램프를 만들고, 단계 색은 평균이 아닌 가장 흔한 실제 색으로 정해요.
/// 4. 그림자는 보라·파랑 쪽, 밝은 쪽은 노랑 쪽으로 살짝 색상을 틀어요(휴 시프트).
/// 5. 가는 어두운 선과 바깥 테두리는 맞닿은 재질의 가장 어두운 색으로 칠해요. 넓게 어두운 면(검은 옷 등)은 선이 아니라 재질로 남겨 음영을 지켜요.
enum MapleRamp {
    private static let linearSRGB: [Float] = (0...255).map { byte in
        let value = Float(byte) / 255
        return value <= 0.04045 ? value / 12.92 : powf((value + 0.055) / 1.055, 2.4)
    }

    static func build(_ source: SourceImage, size: PixelSize, removeLightBackground: Bool,
                      options: MapleOptions) throws -> MapleSprite {
        guard (1...512).contains(size.width), (1...512).contains(size.height) else { throw ConversionError.invalidSize }
        let prepared = removeLightBackground ? try PixelConverter.withoutLightBackground(source) : source
        let scale = min(Double(size.width) / Double(prepared.size.width), Double(size.height) / Double(prepared.size.height))
        let width = max(1, min(size.width, Int((Double(prepared.size.width) * scale).rounded())))
        let height = max(1, min(size.height, Int((Double(prepared.size.height) * scale).rounded())))
        let xOffset = (size.width - width) / 2
        let top = (size.height - height) / 2
        let fitted = CGRect(x: xOffset, y: size.height - height - top, width: width, height: height)
        let baselineContext = try PixelConverter.rasterize(prepared.image, width: size.width, height: size.height, rect: fitted)
        guard let baseline = baselineContext.makeImage() else { throw ConversionError.cannotRender }

        let lab = try sampleCells(prepared.image, width: width, height: height)
        let count = width * height
        let opaque = (0..<count).filter { lab[$0] != nil }
        guard !opaque.isEmpty else {
            return MapleSprite(size: size, width: width, height: height, xOffset: xOffset, yOffset: top,
                               material: Array(repeating: -1, count: count), tone: Array(repeating: 0, count: count),
                               ramps: [], outlines: [], counts: [], baseline: baseline)
        }
        let colors = lab.map { $0 ?? .zero }

        // 재질 나누기
        let features = opaque.map { i -> SIMD3<Float> in
            let c = colors[i]
            let chroma = simd_length(SIMD2(c.y, c.z))
            return SIMD3(c.y * 3, c.z * 3, c.x * (chroma < 0.035 ? 1.6 : 0.45))
        }
        var rng = SplitMix(seed: 0)
        let assignment = try kmeans(features, k: min(options.materials, opaque.count), rng: &rng)
        var material = Array(repeating: -1, count: count)
        for (n, i) in opaque.enumerated() { material[i] = assignment[n] }
        try cleanMaterials(&material, opaque: opaque, width: width, height: height)

        // 쓰인 재질만 많이 쓰인 순서로 다시 번호를 매겨요.
        var usage: [Int: Int] = [:]
        for i in opaque { usage[material[i], default: 0] += 1 }
        let order = usage.keys.sorted { usage[$0]! != usage[$1]! ? usage[$0]! > usage[$1]! : $0 < $1 }
        let remap = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        for i in opaque { material[i] = remap[material[i]]! }
        let materialCount = order.count

        // 어두운 칸과, 그중 넓은 면(검은 옷 등)이 아닌 가는 선 칸이에요.
        let dark = (0..<count).map { i -> Bool in
            guard material[i] >= 0 else { return false }
            let c = colors[i]
            return c.x < 0.42 && simd_length(SIMD2(c.y, c.z)) < 0.06
        }
        func isSurface(_ i: Int) -> Bool {
            let x = i % width, y = i / width
            var darkCount = 0, cells = 0
            for v in max(0, y - 2)...min(height - 1, y + 2) {
                for u in max(0, x - 2)...min(width - 1, x + 2) {
                    cells += 1
                    if dark[v * width + u] { darkCount += 1 }
                }
            }
            return Float(darkCount) / Float(cells) > 0.45
        }
        // 가는 선 칸은 윤곽선이 될 거라 음영 램프에서 빼요.
        // 넣으면 모든 재질의 가장 어두운 단계가 검정이 돼서, 금장식·흰 옷 안에 검은 잔점이 찍혀요.
        let lineCell = (0..<count).map { options.outlineStyle != .none && dark[$0] && !isSurface($0) }

        // 재질마다 음영 단계
        var tone = Array(repeating: 0, count: count)
        var members = Array(repeating: [Int](), count: materialCount)
        for i in opaque { members[material[i]].append(i) }
        for m in 0..<materialCount {
            try Task.checkCancellation()
            let body = members[m].filter { !lineCell[$0] }
            if body.count < members[m].count { members[m] = body.isEmpty ? members[m] : body }
            let values = members[m].map { SIMD3<Float>(colors[$0].x, 0, 0) }
            let lights = members[m].map { colors[$0].x }
            let range = (lights.max() ?? 0) - (lights.min() ?? 0)
            // 목표 스타일은 원본의 작은 밝기 차(0.035)도 단계로 나눠요. (밋밋한 파스텔 원본도 음영 띠가 생기게)
            let step: Float = options.targetStyle ? 0.035 : 0.07
            let levels = max(1, min(options.tones, Int((range / step).rounded()), values.count))
            var levelRng = SplitMix(seed: UInt64(m + 1))
            let raw = try kmeans(values, k: levels, rng: &levelRng)
            // 어두운 단계가 0번이 되도록 순서를 맞춰요.
            var sums = [Float](repeating: 0, count: levels), ns = [Int](repeating: 0, count: levels)
            for (n, label) in raw.enumerated() { sums[label] += lights[n]; ns[label] += 1 }
            let sorted = (0..<levels).sorted { (ns[$0] > 0 ? sums[$0] / Float(ns[$0]) : 9) < (ns[$1] > 0 ? sums[$1] / Float(ns[$1]) : 9) }
            var rank = [Int](repeating: 0, count: levels)
            for (r, label) in sorted.enumerated() { rank[label] = r }
            for (n, i) in members[m].enumerated() { tone[i] = rank[raw[n]] }
        }
        // 진한 잉크 스타일은 음영 띠를 더 깔끔하게(2번, 조금 더 과감하게) 정리해요.
        let cleanBands = options.outlineStyle == .ink
        let bodyCells = opaque.filter { !lineCell[$0] }
        for _ in 0..<(cleanBands ? 2 : 1) {
            smoothTones(&tone, material: material, opaque: bodyCells, skip: lineCell, width: width, height: height,
                        allowed: cleanBands ? 1 : 0)
        }

        // 램프와 윤곽선 색
        var ramps: [[SIMD3<Float>]] = []
        var outlines: [SIMD3<Float>] = []
        for m in 0..<materialCount {
            let all = members[m].map { colors[$0] }
            let base = all.reduce(SIMD3<Float>.zero, +) / Float(all.count)
            let baseHue = atan2f(base.z, base.y)
            let baseChroma = simd_length(SIMD2(base.y, base.z))
            let levels = (members[m].map { tone[$0] }.max() ?? 0) + 1
            var ramp: [SIMD3<Float>] = []
            for level in 0..<levels {
                let points = members[m].filter { tone[$0] == level }.map { colors[$0] }
                var c = points.isEmpty ? (ramp.last ?? base) : commonest(points)
                if options.hueShift && baseChroma > 0.03 {
                    let depth = c.x - base.x
                    let hue = atan2f(c.z, c.y) - 0.9 * depth
                    let chroma = simd_length(SIMD2(c.y, c.z)) * (1 + max(0, -depth) * 1.2)
                    c = SIMD3(c.x, chroma * cosf(hue), chroma * sinf(hue))
                }
                ramp.append(c)
            }
            // 목표 스타일: 단계 사이 밝기 차를 예시처럼 0.08 이상 벌려요. 위(가장 밝은 단계)는 그대로 두고 아래를 어둡게,
            // 색이 있는 재질은 어두울수록 붉은 쪽으로 돌리고 채도를 올려요(예시: 주황 → 빨강 → 진홍).
            if options.targetStyle && ramp.count >= 2 {
                for t in stride(from: ramp.count - 2, through: 0, by: -1) where ramp[t].x > ramp[t + 1].x - 0.08 {
                    let c = ramp[t]
                    let lowered = ramp[t + 1].x - 0.08
                    let depth = c.x - lowered
                    if baseChroma > 0.03 {
                        let hue = atan2f(c.z, c.y) - 0.9 * depth
                        let chroma = simd_length(SIMD2(c.y, c.z)) * (1 + depth * 2)
                        ramp[t] = SIMD3(lowered, chroma * cosf(hue), chroma * sinf(hue))
                    } else {
                        ramp[t] = SIMD3(lowered, c.y, c.z)
                    }
                }
            }
            // 목표 스타일: 흰색·밝은 무채색 재질의 그림자 단계를 회색 대신 따뜻한 베이지로 (예시 #EDDCCC, #CBB6A3)
            if options.targetStyle && baseChroma < 0.03, let top = ramp.last, top.x > 0.75 {
                ramp = ramp.map { c in
                    let depth = min(1, max(0, (top.x - c.x) / 0.1))
                    return SIMD3(c.x, c.y * (1 - depth) + 0.012 * depth, c.z * (1 - depth) + 0.028 * depth)
                }
            }
            let darkest = ramp[0]
            if baseChroma >= 0.03 {
                let chroma = max(simd_length(SIMD2(darkest.y, darkest.z)) * 1.4, 0.045)
                outlines.append(SIMD3(min(0.42, max(0.22, darkest.x * 0.55)), chroma * cosf(baseHue), chroma * sinf(baseHue)))
            } else {
                // 무채색은 메이플 도트처럼 자두빛이 도는 회색 윤곽선으로 해요.
                outlines.append(SIMD3(min(0.36, max(0.18, darkest.x * 0.5)), 0.02, -0.035))
            }
            ramps.append(ramp)
        }

        // 윤곽선 표시
        if options.outlineStyle == .ink {
            // 메이플식 도트의 윤곽선: 아주 진한 고동색 한 가지 (#1D1514)
            let ink = options.targetStyle ? targetInk : inkColor
            outlines = outlines.map { _ in ink }
        }
        if options.outlineStyle != .none {
            var outlineMaterial = material
            var isOutline = Array(repeating: false, count: count)
            for i in opaque {
                let x = i % width, y = i / width
                if dark[i] {
                    if !lineCell[i] { continue }
                    var votes: [Int: Int] = [:]
                    for v in max(0, y - 1)...min(height - 1, y + 1) {
                        for u in max(0, x - 1)...min(width - 1, x + 1) where u != x || v != y {
                            let j = v * width + u
                            if material[j] >= 0 && !dark[j] { votes[material[j], default: 0] += 1 }
                        }
                    }
                    if let best = votes.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) {
                        isOutline[i] = true
                        outlineMaterial[i] = best.key
                    }
                } else {
                    let edge = [(-1, 0), (1, 0), (0, -1), (0, 1)].contains { dx, dy in
                        let u = x + dx, v = y + dy
                        return !(0..<width).contains(u) || !(0..<height).contains(v) || material[v * width + u] < 0
                    }
                    if edge { isOutline[i] = true }
                }
            }
            if options.boundary {
                markBoundaries(&isOutline, material: material, ramps: ramps, opaque: opaque, width: width, height: height)
            }
            for i in opaque where isOutline[i] {
                material[i] = outlineMaterial[i]
                tone[i] = -1
            }
        }
        var counts = [Int](repeating: 0, count: materialCount)
        for i in opaque { counts[material[i]] += 1 }
        for i in 0..<count where material[i] < 0 { tone[i] = 0 }
        return MapleSprite(size: size, width: width, height: height, xOffset: xOffset, yOffset: top,
                           material: material, tone: tone, ramps: ramps, outlines: outlines,
                           counts: counts, baseline: baseline, fixedOutline: options.outlineStyle == .ink)
    }

    /// 진한 잉크 윤곽선을 메이플식으로 다듬어요. 원본 대조 보정까지 끝난 뒤에 불러요.
    ///
    /// 1. 안쪽의 가는 선(원본 선 굵기가 thinLimit칸 미만)은 잉크 대신 맞닿은 재질의 가장 어두운 색으로 칠해요.
    ///    단, 그 색이 양옆 칠보다 minContrast(OKLab 밝기) 넘게 어두워서 여전히 선으로 보일 때만요.
    ///    → 감은 눈은 굵은 눈꺼풀만 진하게 남고, 진한 음영이 없는 연한 재질(분홍 머리카락 등)의 선은 잉크로 남아요.
    ///    바깥 테두리·굵은 선·원본에 선이 없는 재질 경계선은 잉크로 둬요.
    ///    (softInnerLines일 때만. 그림에 따라 좋기도 나쁘기도 해서 기본은 꺼짐 — 춤 그림은 팔·몸 선이 회색이 돼요)
    /// 2. 이어진 선이 하나도 없는 외톨이 잉크 점은 주변 색으로 되돌려요. → 코트·장식의 잔점이 줄어요. (항상)
    /// 점선처럼 끊긴 선 잇기: 선 칸 두 개 사이에 1~2칸 틈이 있고, 그 틈 칸에 원본 선(어두운 부분)이 조금이라도(1/5 이상) 있으면 선으로 이어요.
    /// 원본이 출력보다 아주 크면(AI로 키운 그림 등) 가는 선이 칸 안에서 소수파가 돼 군데군데 빠지거든요.
    /// 같은 재질 안에서 홀로 튀는 음영 점(머리카락 속 빨간 점 등)도 주변 음영으로 맞춰요.
    static func bridgeLines(_ sprite: MapleSprite, dark: [Float], minDark: Float = 0.2) -> MapleSprite {
        let w = sprite.width, h = sprite.height
        var tone = sprite.tone
        func at(_ x: Int, _ y: Int) -> Int? { (0..<w).contains(x) && (0..<h).contains(y) ? y * w + x : nil }
        func line(_ i: Int?) -> Bool { i.map { sprite.material[$0] >= 0 && sprite.tone[$0] < 0 } ?? false }
        func gap(_ i: Int?) -> Bool { i.map { sprite.material[$0] >= 0 && sprite.tone[$0] >= 0 && dark[$0] >= minDark } ?? false }
        let axes = [(1, 0), (0, 1), (1, 1), (1, -1)]
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                guard gap(i) else { continue }
                for (dx, dy) in axes {
                    // 틈 1칸: 양옆이 선 / 틈 2칸: 한쪽은 선, 다른 쪽은 틈 하나 건너 선
                    if line(at(x - dx, y - dy)) && line(at(x + dx, y + dy)) { tone[i] = -1; break }
                    if line(at(x - dx, y - dy)) && gap(at(x + dx, y + dy)) && line(at(x + 2 * dx, y + 2 * dy)) {
                        tone[i] = -1; tone[at(x + dx, y + dy)!] = -1; break
                    }
                }
            }
        }
        // 홀로 튀는 음영 점: 같은 재질·같은 음영 이웃이 하나도 없고, 둘레 4칸이 모두 같은 재질 칠이면 가장 많은 이웃 음영으로
        let bridged = tone
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                guard sprite.material[i] >= 0, bridged[i] >= 0 else { continue }
                let m = sprite.material[i]
                let near = [(-1, 0), (1, 0), (0, -1), (0, 1)].compactMap { at(x + $0.0, y + $0.1) }
                guard near.count == 4, near.allSatisfy({ sprite.material[$0] == m && bridged[$0] >= 0 }) else { continue }
                var votes: [Int: Int] = [:]
                for v in max(0, y - 1)...min(h - 1, y + 1) {
                    for u in max(0, x - 1)...min(w - 1, x + 1) where (u, v) != (x, y) {
                        let j = v * w + u
                        if sprite.material[j] == m, bridged[j] >= 0 { votes[bridged[j], default: 0] += 1 }
                    }
                }
                guard votes[bridged[i]] == nil,
                      let best = votes.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) else { continue }
                tone[i] = best.key
            }
        }
        return MapleSprite(size: sprite.size, width: w, height: h, xOffset: sprite.xOffset, yOffset: sprite.yOffset,
                             material: sprite.material, tone: tone, ramps: sprite.ramps, outlines: sprite.outlines,
                             counts: sprite.counts, baseline: sprite.baseline, fixedOutline: sprite.fixedOutline)
    }

    static func refineLines(_ sprite: MapleSprite, prepared: SourceImage, softInnerLines: Bool,
                            thinLimit: Float = 1.1, minContrast: Float = 0.2) throws -> MapleSprite {
        guard sprite.fixedOutline, sprite.materialCount > 0 else { return sprite }
        let evidence = try SourceCheck.evidence(prepared: prepared, size: sprite.size, shift: .zero,
                                                cells: SIMD2(sprite.width, sprite.height))
        let sprite = bridgeLines(sprite, dark: evidence.dark)
        let w = sprite.width, h = sprite.height
        var material = sprite.material, tone = sprite.tone
        let dark = evidence.dark
        func d(_ x: Int, _ y: Int) -> Float { (0..<w).contains(x) && (0..<h).contains(y) ? dark[y * w + x] : 0 }
        func filled(_ x: Int, _ y: Int) -> Bool { (0..<w).contains(x) && (0..<h).contains(y) && sprite.material[y * w + x] >= 0 }
        func isLine(_ x: Int, _ y: Int) -> Bool { filled(x, y) && sprite.tone[y * w + x] < 0 }
        let around = [(-1, -1), (0, -1), (1, -1), (-1, 0), (1, 0), (-1, 1), (0, 1), (1, 1)]
        // 선 칸마다 원본 선 굵기(칸): 선을 가로지르는 방향으로 잰 값이라 네 방향 중 가장 얇게 나오는 값이에요.
        var thickness = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w where isLine(x, y) {
                thickness[y * w + x] = [(1, 0), (0, 1), (1, 1), (1, -1)].map { dx, dy in
                    d(x - dx, y - dy) + dark[y * w + x] + d(x + dx, y + dy)
                }.min()!
            }
        }

        for y in 0..<h {
            for x in 0..<w where isLine(x, y) {
                let i = y * w + x
                let interior = [(-1, 0), (1, 0), (0, -1), (0, 1)].allSatisfy { filled(x + $0.0, y + $0.1) }
                guard interior else { continue }
                let lineNeighbours = around.count { isLine(x + $0.0, y + $0.1) }
                let lonely = lineNeighbours == 0
                let t = thickness[i]
                guard lonely || (softInnerLines && t >= 0.15 && t < thinLimit) else { continue }
                // 맞닿은 칠 칸 중 표를 2개 이상 얻은 재질에서 가장 어두운 쪽 색으로 (외톨이 점은 가장 많은 쪽으로)
                var votes: [Int: Int] = [:]
                var toneVotes: [Int: [Int: Int]] = [:]
                for (dx, dy) in around where filled(x + dx, y + dy) && !isLine(x + dx, y + dy) {
                    let j = (y + dy) * w + x + dx
                    votes[sprite.material[j], default: 0] += 1
                    toneVotes[sprite.material[j], default: [:]][sprite.tone[j], default: 0] += 1
                }
                guard !votes.isEmpty else { continue }
                if lonely {
                    let best = votes.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }!.key
                    material[i] = best
                    tone[i] = toneVotes[best]!.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }!.key
                } else {
                    let strong = votes.filter { $0.value >= 2 }.map(\.key)
                    let pool = strong.isEmpty ? Array(votes.keys) : strong
                    let chosen = pool.min { a, b in
                        sprite.ramps[a][0].x != sprite.ramps[b][0].x ? sprite.ramps[a][0].x < sprite.ramps[b][0].x : a < b
                    }!
                    // 양옆 칠 중 더 어두운 쪽보다도 충분히 어두워야 선으로 보여요.
                    let fills = around.compactMap { dx, dy -> Float? in
                        guard filled(x + dx, y + dy), !isLine(x + dx, y + dy) else { return nil }
                        let j = (y + dy) * w + x + dx
                        return sprite.ramps[sprite.material[j]][sprite.tone[j]].x
                    }
                    guard let darkestFill = fills.min(), darkestFill - sprite.ramps[chosen][0].x >= minContrast else { continue }
                    material[i] = chosen
                    tone[i] = 0
                }
            }
        }
        dropFragments(&material, &tone, width: w, height: h, dark: dark)
        dropShadeSpecks(&material, &tone, width: w, height: h)
        var counts = [Int](repeating: 0, count: sprite.materialCount)
        for m in material where m >= 0 { counts[m] += 1 }
        return MapleSprite(size: sprite.size, width: w, height: h, xOffset: sprite.xOffset, yOffset: sprite.yOffset,
                           material: material, tone: tone, ramps: sprite.ramps, outlines: sprite.outlines,
                           counts: counts, baseline: sprite.baseline, fixedOutline: sprite.fixedOutline)
    }

    /// 외톨이 음영 점 지우기: 같은 재질·같은 음영 이웃(8방향)이 하나도 없는 칠 칸은, 같은 재질 이웃 중 가장 많은 음영으로 맞춰요.
    /// (테두리 모서리에 혼자 찍힌 베이지·회색 점처럼 외곽선을 지저분하게 보이게 하는 점)
    static func dropShadeSpecks(_ material: inout [Int], _ tone: inout [Int], width w: Int, height h: Int) {
        let snapshot = tone
        for i in 0..<(w * h) where material[i] >= 0 && snapshot[i] >= 0 {
            let x = i % w, y = i / w, m = material[i]
            var votes: [Int: Int] = [:]
            var alone = true
            for v in max(0, y - 1)...min(h - 1, y + 1) {
                for u in max(0, x - 1)...min(w - 1, x + 1) where (u, v) != (x, y) {
                    let j = v * w + u
                    guard material[j] == m, snapshot[j] >= 0 else { continue }
                    if snapshot[j] == snapshot[i] { alone = false }
                    votes[snapshot[j], default: 0] += 1
                }
            }
            guard alone, let best = votes.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) else { continue }
            tone[i] = best.key
        }
    }

    /// 떠 있는 짧은 선 조각 지우기: 다른 선과 안 이어진 2~3칸짜리 안쪽 선 조각(끊긴 선의 부스러기)은
    /// 원본에서 그 자리가 확실히 선(어두운 비율 평균 0.6 이상)이 아니면 둘레 칠 색으로 메워요. (1칸 외톨이 점은 위에서 이미 정리)
    static func dropFragments(_ material: inout [Int], _ tone: inout [Int], width w: Int, height h: Int, dark: [Float]) {
        func isLine(_ i: Int) -> Bool { material[i] >= 0 && tone[i] < 0 }
        var seen = [Bool](repeating: false, count: w * h)
        for start in 0..<(w * h) where isLine(start) && !seen[start] {
            var stack = [start], piece: [Int] = []
            seen[start] = true
            var touchesOutside = false
            while let i = stack.popLast() {
                piece.append(i)
                let x = i % w, y = i / w
                for dy in -1...1 {
                    for dx in -1...1 where (dx, dy) != (0, 0) {
                        let u = x + dx, v = y + dy
                        guard (0..<w).contains(u), (0..<h).contains(v) else { touchesOutside = true; continue }
                        let j = v * w + u
                        if material[j] < 0 { touchesOutside = true }
                        if isLine(j) && !seen[j] { seen[j] = true; stack.append(j) }
                    }
                }
            }
            guard piece.count <= 3, !touchesOutside,
                  piece.map({ dark[$0] }).reduce(0, +) / Float(piece.count) < 0.6 else { continue }
            let snapshot = (material, tone)
            for i in piece {
                let x = i % w, y = i / w
                var votes: [SIMD2<Int>: Int] = [:]
                for v in max(0, y - 1)...min(h - 1, y + 1) {
                    for u in max(0, x - 1)...min(w - 1, x + 1) {
                        let j = v * w + u
                        if snapshot.0[j] >= 0, snapshot.1[j] >= 0 { votes[SIMD2(snapshot.0[j], snapshot.1[j]), default: 0] += 1 }
                    }
                }
                guard let best = votes.max(by: { $0.value != $1.value ? $0.value < $1.value : ($0.key.x, $0.key.y) > ($1.key.x, $1.key.y) })
                else { continue }
                material[i] = best.key.x; tone[i] = best.key.y
            }
        }
    }

    /// 선과 그림 사이 중간색을 칠할 칸을 표시해요. 선 바로 안쪽 1칸이고, 그 안쪽 칸도 같은 재질일 때만이에요.
    /// (1칸짜리 가는 부분 — 눈동자, 가는 머리카락 — 은 통째로 중간색이 되지 않게 남겨요)
    static func markRim(_ sprite: MapleSprite, ink: Float) -> MapleSprite {
        var result = sprite
        let w = sprite.width, h = sprite.height
        var rim = Array(repeating: false, count: w * h)
        // 바깥 테두리 선 안쪽에만 칠해요. (눈·입 같은 안쪽 선 둘레는 빼요)
        let distance = RimShade.edgeDistance(opaque: sprite.material.map { $0 >= 0 }, width: w, height: h)
        func isFill(_ x: Int, _ y: Int, material m: Int) -> Bool {
            guard (0..<w).contains(x), (0..<h).contains(y) else { return false }
            let j = y * w + x
            return sprite.material[j] == m && sprite.tone[j] >= 0
        }
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let m = sprite.material[i]
                guard m >= 0, sprite.tone[i] >= 0 else { continue }
                rim[i] = [(-1, 0), (1, 0), (0, -1), (0, 1)].contains { dx, dy in
                    let u = x + dx, v = y + dy
                    guard (0..<w).contains(u), (0..<h).contains(v) else { return false }
                    let n = v * w + u
                    return sprite.material[n] >= 0 && sprite.tone[n] < 0 && isFill(x - dx, y - dy, material: m)
                        && distance[n] <= RimShade.outerLineDepth && distance[i] > distance[n]
                }
            }
        }
        result.rim = rim
        result.rimInk = ink
        return result
    }

    /// 목표 스타일 잉크: 예시의 외곽선(#010101~#070507)처럼 거의 순검정, 살짝 따뜻하게
    static let targetInk: SIMD3<Float> = {
        var bytes: [UInt8] = [0x0A, 0x06, 0x07, 0xFF]
        return bytes.withUnsafeMutableBufferPointer { decode(UnsafePointer($0.baseAddress!), alpha: 255) }
    }()

    static let inkColor: SIMD3<Float> = {
        var bytes: [UInt8] = [0x1D, 0x15, 0x14, 0xFF]
        return bytes.withUnsafeMutableBufferPointer { decode(UnsafePointer($0.baseAddress!), alpha: 255) }
    }()

    /// 크게 다른 재질 두 덩어리가 맞닿는 곳에서, 더 어두운 쪽 칸에 선을 그어요.
    /// 바깥에 닿지 않고 갇힌 작은 덩어리(하이라이트·볼터치)와 아주 작은 조각은 선을 긋지 않아요.
    private static func markBoundaries(_ isOutline: inout [Bool], material: [Int], ramps: [[SIMD3<Float>]],
                                       opaque: [Int], width: Int, height: Int) {
        let sides = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        var size = Array(repeating: 0, count: material.count)
        var seen = Array(repeating: false, count: material.count)
        for start in opaque where !seen[start] {
            var component = [start]
            seen[start] = true
            var head = 0
            var open = false
            while head < component.count {
                let j = component[head]; head += 1
                let x = j % width, y = j / width
                for (dx, dy) in sides {
                    let u = x + dx, v = y + dy
                    guard (0..<width).contains(u), (0..<height).contains(v) else { open = true; continue }
                    let n = v * width + u
                    if material[n] < 0 { open = true; continue }
                    if !seen[n] && material[n] == material[start] { seen[n] = true; component.append(n) }
                }
            }
            let value = open || component.count >= 80 ? component.count : 0
            for j in component { size[j] = value }
        }
        let bases = ramps.map { ramp in ramp.reduce(SIMD3<Float>.zero, +) / Float(ramp.count) }
        let initial = isOutline
        for i in opaque where !initial[i] && size[i] >= 16 {
            let x = i % width, y = i / width
            for (dx, dy) in sides {
                let u = x + dx, v = y + dy
                guard (0..<width).contains(u), (0..<height).contains(v) else { continue }
                let n = v * width + u
                let a = material[i], b = material[n]
                guard b >= 0, b != a, !initial[n], size[n] >= 16 else { continue }
                let p = bases[a], q = bases[b]
                if simd_distance(p, q) > 0.12 && (p.x < q.x || (p.x == q.x && i < n)) {
                    isOutline[i] = true
                    break
                }
            }
        }
    }

    // MARK: - 단계별 도우미

    /// 칸마다 대표 표본(채널별 중앙값에 가장 가까운 실제 표본)을 골라요. 덜 덮인 칸은 투명이에요.
    private static func sampleCells(_ image: CGImage, width: Int, height: Int) throws -> [SIMD3<Float>?] {
        let side = 4
        let samples = try PixelConverter.rasterize(image, width: width * side, height: height * side,
                                                   rect: CGRect(x: 0, y: 0, width: width * side, height: height * side))
        guard let data = samples.data else { throw ConversionError.cannotRender }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let stride = samples.bytesPerRow
        var result = [SIMD3<Float>?](repeating: nil, count: width * height)
        var points: [SIMD3<Float>] = []
        points.reserveCapacity(16)
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                points.removeAll(keepingCapacity: true)
                var coverage = 0
                for sy in 0..<side {
                    for sx in 0..<side {
                        let offset = (y * side + sy) * stride + (x * side + sx) * 4
                        let alpha = Int(bytes[offset + 3])
                        coverage += alpha
                        guard alpha > 127 else { continue }
                        points.append(decode(bytes.advanced(by: offset), alpha: alpha))
                    }
                }
                guard coverage * 2 >= 255 * side * side, !points.isEmpty else { continue }
                let median = SIMD3(middle(points.map(\.x)), middle(points.map(\.y)), middle(points.map(\.z)))
                result[y * width + x] = points.min { simd_distance_squared($0, median) < simd_distance_squared($1, median) }
            }
        }
        return result
    }

    private static func middle(_ values: [Float]) -> Float {
        let sorted = values.sorted()
        return sorted.count % 2 == 1 ? sorted[sorted.count / 2] : (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
    }

    /// 주변 대부분이 다른 재질인 칸과 3칸보다 작은 조각을 주변 재질로 합쳐요.
    private static func cleanMaterials(_ material: inout [Int], opaque: [Int], width: Int, height: Int) throws {
        let initial = material
        for i in opaque {
            let x = i % width, y = i / width
            var votes: [Int: Int] = [:]
            for v in max(0, y - 1)...min(height - 1, y + 1) {
                for u in max(0, x - 1)...min(width - 1, x + 1) where u != x || v != y {
                    let m = initial[v * width + u]
                    if m >= 0 { votes[m, default: 0] += 1 }
                }
            }
            if let best = votes.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }),
               best.value >= 6, best.key != initial[i] {
                material[i] = best.key
            }
        }
        var seen = Array(repeating: false, count: material.count)
        let sides = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        for start in opaque where !seen[start] {
            try Task.checkCancellation()
            let label = material[start]
            var component = [start]
            seen[start] = true
            var head = 0
            while head < component.count {
                let j = component[head]; head += 1
                let x = j % width, y = j / width
                for (dx, dy) in sides {
                    let u = x + dx, v = y + dy
                    guard (0..<width).contains(u), (0..<height).contains(v) else { continue }
                    let n = v * width + u
                    if !seen[n] && material[n] == label { seen[n] = true; component.append(n) }
                }
            }
            guard component.count < 3 else { continue }
            var votes: [Int: Int] = [:]
            for j in component {
                let x = j % width, y = j / width
                for (dx, dy) in sides {
                    let u = x + dx, v = y + dy
                    guard (0..<width).contains(u), (0..<height).contains(v) else { continue }
                    let m = material[v * width + u]
                    if m >= 0 && m != label { votes[m, default: 0] += 1 }
                }
            }
            if let best = votes.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) {
                for j in component { material[j] = best.key }
            }
        }
    }

    /// 같은 재질 이웃 중 같은 단계가 하나도 없는 튀는 칸만 이웃 단계로 맞춰요.
    /// skip인 칸(가는 선)은 표를 던지지 않아요.
    private static func smoothTones(_ tone: inout [Int], material: [Int], opaque: [Int], skip: [Bool], width: Int,
                                    height: Int, allowed: Int) {
        let initial = tone
        for i in opaque {
            let x = i % width, y = i / width
            var votes: [Int: Int] = [:]
            var same = 0
            for v in max(0, y - 1)...min(height - 1, y + 1) {
                for u in max(0, x - 1)...min(width - 1, x + 1) where u != x || v != y {
                    let j = v * width + u
                    guard material[j] == material[i], !skip[j] else { continue }
                    same += 1
                    votes[initial[j], default: 0] += 1
                }
            }
            if same >= 5, (votes[initial[i]] ?? 0) <= allowed,
               let best = votes.max(by: { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }) {
                tone[i] = best.key
            }
        }
    }

    /// 평균 대신 가장 흔한 실제 색을 골라요. 평균은 채도를 떨어뜨려 탁해지거든요.
    private static func commonest(_ points: [SIMD3<Float>]) -> SIMD3<Float> {
        var bins: [SIMD3<Int32>: (total: SIMD3<Float>, count: Int)] = [:]
        for p in points {
            let key = SIMD3<Int32>(Int32((p.x / 0.03).rounded()), Int32((p.y / 0.02).rounded()), Int32((p.z / 0.02).rounded()))
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

    static func kmeans(_ points: [SIMD3<Float>], k: Int, rng: inout SplitMix, iterations: Int = 25) throws -> [Int] {
        guard k > 1, points.count > 1 else { return Array(repeating: 0, count: points.count) }
        // k-means++ 시작점
        var centers = [points[Int(rng.next() % UInt64(points.count))]]
        var nearest = points.map { simd_distance_squared($0, centers[0]) }
        while centers.count < k {
            try Task.checkCancellation()
            let total = nearest.reduce(0, +)
            guard total > 0 else { break }
            var target = Float(Double(rng.next() % 1_000_000) / 1_000_000) * total
            var chosen = points.count - 1
            for (n, d) in nearest.enumerated() {
                target -= d
                if target <= 0 { chosen = n; break }
            }
            centers.append(points[chosen])
            for n in points.indices { nearest[n] = min(nearest[n], simd_distance_squared(points[n], points[chosen])) }
        }
        var labels = Array(repeating: 0, count: points.count)
        for _ in 0..<iterations {
            try Task.checkCancellation()
            var changed = false
            for (n, p) in points.enumerated() {
                var best = 0, bestDistance = Float.infinity
                for (c, center) in centers.enumerated() {
                    let d = simd_distance_squared(p, center)
                    if d < bestDistance { bestDistance = d; best = c }
                }
                if labels[n] != best { labels[n] = best; changed = true }
            }
            var sums = Array(repeating: SIMD3<Float>.zero, count: centers.count)
            var counts = Array(repeating: 0, count: centers.count)
            for (n, p) in points.enumerated() { sums[labels[n]] += p; counts[labels[n]] += 1 }
            for c in centers.indices where counts[c] > 0 { centers[c] = sums[c] / Float(counts[c]) }
            if !changed { break }
        }
        return labels
    }

    // MARK: - 색 변환

    static func adjusted(_ lab: SIMD3<Float>, _ adjust: MaterialAdjust, neutral: Bool = false) -> SIMD3<Float> {
        guard !adjust.isIdentity else { return lab }
        let angle = Float(adjust.hue * .pi / 180)
        if neutral {
            // 무채색은 돌릴 색이 없으니, 채도를 올린 만큼 '색상' 방향으로 물들여요. (예: 검은 옷 → 남색 옷)
            let tint = Float(max(0, adjust.saturation - 1)) * 0.09
            let keep = Float(min(1, adjust.saturation))
            return SIMD3(min(1, max(0, lab.x + Float(adjust.lightness))),
                         lab.y * keep + tint * cosf(angle), lab.z * keep + tint * sinf(angle))
        }
        let a = lab.y * cosf(angle) - lab.z * sinf(angle)
        let b = lab.y * sinf(angle) + lab.z * cosf(angle)
        let s = Float(adjust.saturation)
        return SIMD3(min(1, max(0, lab.x + Float(adjust.lightness))), a * s, b * s)
    }

    /// 프리멀티플라이 RGBA 한 칸을 OKLab으로 바꿔요.
    static func decodeLab(_ rgba: UnsafePointer<UInt8>, alpha: Int) -> SIMD3<Float> { decode(rgba, alpha: alpha) }

    private static func decode(_ rgba: UnsafePointer<UInt8>, alpha: Int) -> SIMD3<Float> {
        let r = linearSRGB[min(255, (Int(rgba[0]) * 255 + alpha / 2) / alpha)]
        let g = linearSRGB[min(255, (Int(rgba[1]) * 255 + alpha / 2) / alpha)]
        let b = linearSRGB[min(255, (Int(rgba[2]) * 255 + alpha / 2) / alpha)]
        let l = cbrtf(0.41222147 * r + 0.53633255 * g + 0.05144599 * b)
        let m = cbrtf(0.21190350 * r + 0.68069955 * g + 0.10739696 * b)
        let s = cbrtf(0.08830246 * r + 0.28171884 * g + 0.62997870 * b)
        return SIMD3(0.21045426 * l + 0.79361779 * m - 0.00407205 * s,
                     1.97799850 * l - 2.42859221 * m + 0.45059371 * s,
                     0.02590404 * l + 0.78277177 * m - 0.80867577 * s)
    }

    static func encode(_ color: SIMD3<Float>) -> SIMD3<UInt8> {
        let l = color.x + 0.39633778 * color.y + 0.21580376 * color.z
        let m = color.x - 0.10556135 * color.y - 0.06385417 * color.z
        let s = color.x - 0.08948418 * color.y - 1.29148555 * color.z
        let ll = l * l * l, mm = m * m * m, ss = s * s * s
        func channel(_ linear: Float) -> UInt8 {
            let v = min(1, max(0, linear))
            let encoded = v <= 0.0031308 ? v * 12.92 : 1.055 * powf(v, 1 / 2.4) - 0.055
            return UInt8((encoded * 255).rounded())
        }
        return SIMD3(channel(4.07674166 * ll - 3.30771159 * mm + 0.23096993 * ss),
                     channel(-1.26843800 * ll + 2.60975740 * mm - 0.34131940 * ss),
                     channel(-0.00419609 * ll - 0.70341861 * mm + 1.70761470 * ss))
    }
}

/// 같은 입력이면 항상 같은 결과가 나오도록 고정된 씨앗의 난수를 써요.
struct SplitMix {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
