import CoreGraphics
import Foundation

/// 원본 색 살림: 원본의 색을 살리고 색 수만 줄인다. 선 1픽셀 정리·선명하게·테두리·색 면 정리를 고른다.
/// 윈도우판(core.js renderSoft)과 같은 계산이다.
enum SoftDot {
    static func render(subject: Raster, w: Int, h: Int, settings: DotSettings) throws -> Dotted {
        let image = try subject.image()
        let source = SourceImage(name: "subject", size: PixelSize(width: image.width, height: image.height), image: image)
        let size = PixelSize(width: w, height: h)
        let prepared = try PixelConverter.withoutLightBackground(source)
        var conversion = try PixelConverter.convert(prepared, size: size, colors: max(2, min(64, settings.softColors)))
        conversion = try SourceCheck.apply(to: conversion, prepared: prepared, size: size, shift: .zero).0
        try Task.checkCancellation()
        var raster = try Raster(conversion.pixelArt)
        if settings.softLines { try refineLines(&raster, prepared: prepared) }
        if settings.softVivid { vivid(&raster, factor: 1.25) }
        if settings.softClean {
            let flat = try FlatDot.outline(Conversion(size: size, baseline: conversion.baseline,
                                                      pixelArt: try raster.image(), colorCount: 0))
            raster = flattenColors(try Raster(flat.pixelArt))
        }
        let mask = raster.pixels.map { $0.a > 0 }
        let none = [Bool](repeating: false, count: mask.count)
        return Dotted(image: raster, mask: mask, outline: none, boundary: none, bodyCount: 0, headCount: 0)
    }

    /// 상태줄: 가장자리 반투명 칸은 같은 색도 알파에 따라 값이 달라 따로 세지 않는다(불투명 칸의 색 수).
    static func status(_ settings: DotSettings, _ dotted: Dotted) -> String {
        let colors = Set(dotted.image.pixels.filter { $0.a == 255 }.map(key)).count
        return "원본 색 살림" + (settings.softLines ? " · 선 1px 정리" : "") + (settings.softVivid ? " · 선명하게" : "")
            + (settings.softClean ? " · 테두리·색 면 정리" : "") + "  ·  \(colors)색 (가장자리 반투명 제외)"
    }

    private static func key(_ p: Pixel) -> Int { Int(p.r) << 16 | Int(p.g) << 8 | Int(p.b) }

    private static func lab(_ p: Pixel) -> SIMD3<Float> {
        let bytes: [UInt8] = [p.r, p.g, p.b, 255]
        return bytes.withUnsafeBufferPointer { MapleRamp.decodeLab($0.baseAddress!, alpha: 255) }
    }

    /// 이웃 가운데 가장 흔한 색(같은 수면 먼저 나온 색).
    private static func commonNeighbor(_ raster: Raster, _ i: Int, mask: [Bool], skip: (Int) -> Bool) -> Pixel? {
        var order: [Int] = [], counts: [Int: (Int, Pixel)] = [:]
        raster.grid.each8(i) { j in
            guard mask[j], !skip(j) else { return }
            let k = key(raster.pixels[j])
            if counts[k] == nil { order.append(k); counts[k] = (0, raster.pixels[j]) }
            counts[k]!.0 += 1
        }
        var best: (Int, Pixel)?
        for k in order where best == nil || counts[k]!.0 > best!.0 { best = counts[k] }
        return best?.1
    }

    /// 선 1픽셀 정리: 큰 원본에서 선의 가운데 줄기(뼈대)를 먼저 찾고, 그 줄기가 지나는 칸만 선으로 칠한다.
    static func refineLines(_ image: inout Raster, prepared: SourceImage) throws {
        let grid = image.grid, w = grid.w, h = grid.h
        let scale = min(Double(w) / Double(prepared.size.width), Double(h) / Double(prepared.size.height))
        let fw = max(1, min(w, Int((Double(prepared.size.width) * scale).rounded())))
        let fh = max(1, min(h, Int((Double(prepared.size.height) * scale).rounded())))
        let fx = (w - fw) / 2, top = (h - fh) / 2
        // 칸 하나를 6×6으로 나눠 뼈대를 찾는다. 큰 출력은 한 변 약 1500픽셀까지로 줄인다.
        let side = max(2, min(6, Int((1500.0 / Double(max(fw, fh))).rounded()))), bw = fw * side, bh = fh * side
        let context = try PixelConverter.rasterize(prepared.image, width: bw, height: bh,
                                                   rect: CGRect(x: 0, y: 0, width: bw, height: bh))
        guard let data = context.data else { throw DotError.render }
        let bytes = data.assumingMemoryBound(to: UInt8.self), stride = context.bytesPerRow
        var darkPx = [Bool](repeating: false, count: bw * bh)
        var dark = [Float](repeating: 0, count: grid.count)
        let share = 1.0 / Double(side * side)
        for y in 0..<bh {
            try Task.checkCancellation()
            for x in 0..<bw {
                let o = y * stride + x * 4, a = Int(bytes[o + 3])
                guard a > 127, SourceCheck.isDark(MapleRamp.decodeLab(bytes + o, alpha: a)) else { continue }
                darkPx[y * bw + x] = true
                let i = (y / side + top) * w + x / side + fx
                dark[i] = Float(Double(dark[i]) + share)
            }
        }
        LineCleanup.skeletonize(&darkPx, grid: Grid(w: bw, h: bh))
        let px = image.pixels
        let mask = px.map { $0.a > 0 }
        var line = [Bool](repeating: false, count: grid.count)
        for y in 0..<bh {
            for x in 0..<bw where darkPx[y * bw + x] { line[(y / side + top) * w + x / side + fx] = true }
        }
        // 넓게 어두운 면은 원래대로 둔다(자신과 이웃 대부분이 진함).
        let solid = mask.indices.map { i -> Bool in
            guard mask[i], dark[i] >= 0.6 else { return false }
            var n = 0
            grid.each8(i) { if dark[$0] >= 0.6 { n += 1 } }
            return n >= 6
        }
        // 바깥 테두리 선은 원래대로 둔다(뼈대가 한 칸 안쪽에 잡히면 실루엣 선이 끊긴다).
        let outside = PixelPerfect.touchesOutside(opaque: mask, width: w, height: h)
        for i in line.indices {
            if !mask[i] { line[i] = false }
            else if solid[i] || (outside[i] && LineCleanup.isInk(px[i])) { line[i] = true }
        }
        // 계단 모서리(ㄴ자) 칸을 덜어 1픽셀 선으로. 실루엣 바깥 테두리는 그대로.
        let cut = PixelPerfect.corners(isLine: line, protected: outside.indices.map { outside[$0] || solid[$0] },
                                       width: w, height: h)
        for i in cut.indices where cut[i] { line[i] = false }

        var inkOrder: [Int] = [], inkVotes: [Int: (Int, Pixel)] = [:]
        for i in px.indices where mask[i] && LineCleanup.isInk(px[i]) {
            let k = key(px[i])
            if inkVotes[k] == nil { inkOrder.append(k); inkVotes[k] = (0, px[i]) }
            inkVotes[k]!.0 += 1
        }
        var inkBest: (Int, Pixel)?
        for k in inkOrder where inkBest == nil || inkVotes[k]!.0 > inkBest!.0 { inkBest = inkVotes[k] }
        let inkColor = inkBest?.1 ?? .black
        var stale: [Int] = []
        for i in px.indices {
            let p = image.pixels[i]
            // 선 칸은 불투명하게(반투명 가장자리 칸에 잡힌 선이 흐려 보이지 않게)
            if line[i] && (!LineCleanup.isInk(p) || p.a < 255) {
                let c = LineCleanup.isInk(p) ? p : inkColor
                image.pixels[i] = Pixel(c.r, c.g, c.b, 255)
            } else if !line[i] && mask[i] && LineCleanup.isInk(p) {
                stale.append(i)
            }
        }
        // 선이 아니게 된 칸은 선이 아닌 이웃 중 가장 흔한 색으로 메운다(이웃이 모두 선이면 다음 차례에).
        for _ in 0..<3 where !stale.isEmpty {
            for k in stale.indices.reversed() {
                let i = stale[k]
                let current = image
                if let fill = commonNeighbor(current, i, mask: mask, skip: { line[$0] || LineCleanup.isInk(current.pixels[$0]) }) {
                    image.pixels[i] = Pixel(fill.r, fill.g, fill.b, image.pixels[i].a)
                    stale.remove(at: k)
                }
            }
        }
    }

    /// 선명하게: OKLab 채도를 factor배로. 흰색·검정·회색(채도 0.02 미만)은 그대로, 알파도 그대로.
    static func vivid(_ image: inout Raster, factor: Double) {
        var cache: [Int: Pixel?] = [:]
        for i in image.pixels.indices {
            let p = image.pixels[i]
            guard p.a > 0 else { continue }
            let k = key(p)
            if cache[k] == nil {
                let c = lab(p)
                let L = Double(c.x), a = Double(c.y), b = Double(c.z)
                cache[k] = hypot(a, b) < 0.02 ? Optional<Pixel>.none : oklabToRGB(L, a * factor, b * factor)
            }
            if let rgb = cache[k]! { image.pixels[i] = Pixel(rgb.r, rgb.g, rgb.b, p.a) }
        }
    }

    /// OKLab → sRGB 바이트(배정밀도, 범위 밖은 자름)
    private static func oklabToRGB(_ L: Double, _ a: Double, _ b: Double) -> Pixel {
        let l = pow(L + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m = pow(L - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s = pow(L - 0.0894841775 * a - 1.2914855480 * b, 3)
        func channel(_ value: Double) -> UInt8 {
            let v = min(1, max(0, value))
            return UInt8((255 * (v <= 0.0031308 ? 12.92 * v : 1.055 * pow(v, 1 / 2.4) - 0.055)).rounded(.toNearestOrAwayFromZero))
        }
        return Pixel(channel(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                     channel(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                     channel(-0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s))
    }

    /// 색 면 정리: 거의 같은 색(OKLab 거리 0.035 미만)을 더 많이 쓰인 색으로 합치고,
    /// 같은 색 이웃이 하나도 없는 점은 둘레 다수 색(8칸 중 5칸 이상)으로 메운다. 선(진한 색)끼리는 합치지 않는다.
    static func flattenColors(_ input: Raster, threshold: Double = 0.035) -> Raster {
        var image = input
        var order: [Int] = [], counts: [Int: Int] = [:]
        for p in image.pixels where p.a > 0 {
            let k = key(p)
            if counts[k] == nil { order.append(k) }
            counts[k, default: 0] += 1
        }
        // 많이 쓰인 색부터(같으면 먼저 나온 색부터)
        let rank = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let sorted = order.sorted { counts[$0]! != counts[$1]! ? counts[$0]! > counts[$1]! : rank[$0]! < rank[$1]! }
        var reps: [(key: Int, c: SIMD3<Double>)] = [], map: [Int: Int] = [:]
        for k in sorted {
            let p = Pixel(UInt8(k >> 16), UInt8((k >> 8) & 255), UInt8(k & 255))
            if LineCleanup.isInk(p) { map[k] = k; continue }
            let f = lab(p), c = SIMD3(Double(f.x), Double(f.y), Double(f.z))
            if let rep = reps.first(where: { hypot(hypot($0.c.x - c.x, $0.c.y - c.y), $0.c.z - c.z) < threshold }) {
                map[k] = rep.key
            } else {
                reps.append((k, c)); map[k] = k
            }
        }
        for i in image.pixels.indices where image.pixels[i].a > 0 {
            let k = map[key(image.pixels[i])]!
            image.pixels[i] = Pixel(UInt8(k >> 16), UInt8((k >> 8) & 255), UInt8(k & 255), image.pixels[i].a)
        }
        let grid = image.grid, before = image.pixels
        for i in before.indices where before[i].a > 0 && !grid.edge(i) {
            var same = 0, opaque = true
            var voteOrder: [Int] = [], votes: [Int: Int] = [:]
            grid.each8(i) { j in
                if before[j].a == 0 { opaque = false }
                if key(before[j]) == key(before[i]) { same += 1 } else {
                    let k = key(before[j])
                    if votes[k] == nil { voteOrder.append(k) }
                    votes[k, default: 0] += 1
                }
            }
            guard opaque, same == 0, let top = voteOrder.max(by: { votes[$0]! < votes[$1]! || (votes[$0]! == votes[$1]! && voteOrder.firstIndex(of: $0)! > voteOrder.firstIndex(of: $1)!) }),
                  votes[top]! >= 5 else { continue }
            image.pixels[i] = Pixel(UInt8(top >> 16), UInt8((top >> 8) & 255), UInt8(top & 255), before[i].a)
        }
        return image
    }
}
