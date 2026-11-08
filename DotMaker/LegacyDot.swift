import CoreGraphics

enum DotMethod: String, CaseIterable, Identifiable, Sendable {
    case berry = "베리 잉크"
    case basic = "2.0 방식"
    case direct = "원본 직행"
    case faithful = "원본 보존"

    var id: Self { self }
    var samplesOriginal: Bool { self == .direct || self == .faithful }
}

/// 이전 도트메이커(개선판 1.7.1)의 베리 잉크 변환을 배경이 지워진 캐릭터에 그대로 적용한다.
/// 검은 외곽선과 몸통 경계색은 새 앱의 설정(1·2줄, 투명도)을 따른다.
enum LegacyDot {
    static func render(subject: Raster, w: Int, h: Int, settings: DotSettings) throws -> Dotted {
        let image = try subject.image()
        let source = SourceImage(name: "subject", size: PixelSize(width: image.width, height: image.height), image: image)
        let size = PixelSize(width: w, height: h)
        let prepared = try PixelConverter.withoutLightBackground(source)

        let aligned = try GridAligner.bestGrid(for: source, size: size, removeLightBackground: true)
        let offset = SIMD2(aligned.x, -aligned.y)
        // 검은 외곽선·몸통 경계색 몫으로 팔레트 칸을 남겨 둔다.
        var conversion = try PixelConverter.convert(
            source, size: size, colors: max(2, min(64, settings.colors - (settings.boundary ? 2 : 1))), gameSprite: true,
            removeLightBackground: true, fineDetail: true, paletteStyle: .berryInk,
            gridOffset: offset, thinInk: true, shadeWhiteEdge: false)
        let shift = SIMD2(max(-2, min(2, offset.x)), max(-2, min(2, offset.y)))
        conversion = try SourceCheck.apply(to: conversion, prepared: prepared, size: size, shift: shift, cells: nil).0
        conversion = try PixelPerfect.apply(to: conversion)
        try Task.checkCancellation()
        return try finish(conversion, settings: settings)
    }

    /// 다 칠해진 도트 그림에 검은 외곽선(1·2줄), 겹선·얼룩 정리, 볼터치, 몸통 경계색을 입힌다.
    static func finish(_ converted: Conversion, settings: DotSettings) throws -> Dotted {
        let conversion = try FlatDot.outline(converted)
        var raster = try Raster(conversion.pixelArt)
        let grid = raster.grid
        let mask = raster.pixels.map { $0.a > 0 }
        var outline = grid.depths(mask).map { $0 == 1 }
        if settings.width == 2 {
            // 바깥 검은 줄 바로 안쪽 한 겹을 더 검게 칠해 2줄로 만든다.
            let inner = mask.indices.filter { i in
                guard mask[i] && !outline[i] else { return false }
                var touches = false
                grid.each4(i) { if outline[$0] { touches = true } }
                return touches
            }
            for i in inner { raster.pixels[i] = .black; outline[i] = true }
        }
        removeStrayInk(&raster, mask: mask, outline: outline, width: settings.width)
        LineCleanup.apply(&raster, mask: mask, outline: outline, width: settings.width)
        FaceDetail.apply(&raster, mask: mask)

        // 몸통 경계색: 검은 줄 바로 안쪽의 흰 몸통 칸만 2.0과 같은 공식으로 한 가지 색을 칠한다.
        var boundary = [Bool](repeating: false, count: grid.count)
        if settings.boundary && settings.transparency < 100 {
            let rim = mask.indices.filter { i in
                guard mask[i] && !outline[i] && raster.pixels[i].paper else { return false }
                var touches = false
                grid.each4(i) { if outline[$0] { touches = true } }
                return touches
            }
            var counts: [Int: (Int, Pixel)] = [:]
            for i in rim {
                let p = raster.pixels[i], key = Int(p.r) << 16 | Int(p.g) << 8 | Int(p.b)
                counts[key, default: (0, p)].0 += 1
            }
            if let paper = counts.values.max(by: { $0.0 < $1.0 })?.1 {
                let middle = paper.mixed(with: .black, percent: 50)
                let tint = paper.mixed(with: middle, percent: 100 - settings.transparency)
                for i in rim { raster.pixels[i] = tint; boundary[i] = true }
            }
        }
        return Dotted(image: raster, mask: mask, outline: outline, boundary: boundary, bodyCount: 0, headCount: 0)
    }
}

extension LegacyDot {
    /// 새 검은 외곽선 바로 안쪽에 원본의 옛 외곽선이 반 칸 어긋나 남으면 "검정·진한 점·흰색" 줄무늬가 된다.
    /// 안쪽으로 이어지지 않는(외곽선에서 3칸 안에서 끝나는) 잉크 덩어리만 옆 칸 색으로 메운다.
    static func removeStrayInk(_ raster: inout Raster, mask: [Bool], outline: [Bool], width: Int) {
        let grid = raster.grid
        let depth = grid.depths(mask)
        func ink(_ i: Int) -> Bool {
            let p = raster.pixels[i]
            return mask[i] && !outline[i] && p.light < 70 && p.chroma < 60
        }
        var seen = [Bool](repeating: false, count: grid.count)
        var stray: [Int] = []
        for start in 0..<grid.count where ink(start) && !seen[start] && depth[start] <= width + 2 {
            var piece = [start], next = 0
            seen[start] = true
            while next < piece.count {
                grid.each8(piece[next]) { j in
                    if ink(j) && !seen[j] { seen[j] = true; piece.append(j) }
                }
                next += 1
            }
            if piece.allSatisfy({ depth[$0] <= width + 3 }) { stray += piece }
        }
        // 바깥쪽부터 채워서, 안쪽 칸이 방금 메운 색을 이어받게 한다.
        for i in stray.sorted(by: { depth[$0] < depth[$1] }) {
            var counts: [Int: (Int, Pixel)] = [:]
            grid.each8(i) { j in
                let p = raster.pixels[j]
                guard mask[j], !outline[j], p.light >= 70 else { return }
                counts[Int(p.r) << 16 | Int(p.g) << 8 | Int(p.b), default: (0, p)].0 += 1
            }
            if let fill = counts.values.max(by: { $0.0 < $1.0 })?.1 { raster.pixels[i] = fill }
        }
    }
}

extension Grid {
    /// 투명 칸에서 몇 걸음 떨어졌는지(상하좌우). 캔버스 가장자리도 바깥으로 본다.
    func depths(_ mask: [Bool]) -> [Int] {
        var depth = [Int](repeating: 0, count: count)
        var queue: [Int] = []
        for i in mask.indices where mask[i] {
            var edge = self.edge(i)
            each4(i) { if !mask[$0] { edge = true } }
            if edge { depth[i] = 1; queue.append(i) }
        }
        var next = 0
        while next < queue.count {
            let i = queue[next]
            each4(i) { j in
                if mask[j] && depth[j] == 0 { depth[j] = depth[i] + 1; queue.append(j) }
            }
            next += 1
        }
        return depth
    }
}
