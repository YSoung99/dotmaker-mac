import CoreGraphics
import Foundation
import simd

/// 선 1px로 다듬기 (원탁회의 결론 1번: 아티스트·알고리즘 담당 공통)
///
/// 계단처럼 꺾이는 선에서 'ㄴ'자 모서리 칸이 있으면 선이 2칸 굵기로 보여요. 그 모서리 칸을 둘레 칠 색으로 바꿔
/// 대각선 1칸 선으로 만들어요. (모서리를 빼도 두 이웃 선 칸이 대각선으로 이어져 있어 끊기지 않아요)
/// 바깥 테두리(투명과 맞닿은 선)는 실루엣을 지키려고 그대로 두고, 선 끝 칸에 붙은 모서리도 그대로 둬요(입 ω 같은 짧은 선 보호).
/// 바깥 테두리가 2칸 굵기면 안쪽 겹을 칠 색으로 바꿔 1칸으로 만들어요.
enum PixelPerfect {
    /// 지울 모서리 칸을 골라요.
    static func corners(isLine: [Bool], protected: [Bool], width w: Int, height h: Int, passes: Int = 2) -> [Bool] {
        var line = isLine
        var removed = [Bool](repeating: false, count: w * h)
        func on(_ x: Int, _ y: Int) -> Bool { (0..<w).contains(x) && (0..<h).contains(y) && line[y * w + x] }
        func lineNeighbours(_ x: Int, _ y: Int, except ex: Int, _ ey: Int) -> Int {
            var n = 0
            for dy in -1...1 { for dx in -1...1 where (dx, dy) != (0, 0) && (x + dx, y + dy) != (ex, ey) && on(x + dx, y + dy) { n += 1 } }
            return n
        }
        let sides = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        for _ in 0..<passes {
            for y in 0..<h {
                for x in 0..<w where line[y * w + x] && !protected[y * w + x] {
                    let near = sides.filter { on(x + $0.0, y + $0.1) }
                    // 가로 하나·세로 하나(ㄴ자)일 때만
                    guard near.count == 2, near[0].0 + near[1].0 != 0, near[0].1 + near[1].1 != 0 else { continue }
                    // 두 이웃이 선 끝이면(나를 빼면 이웃 선이 없음) 짧은 모양이 무너지니 그대로 둬요.
                    guard near.allSatisfy({ lineNeighbours(x + $0.0, y + $0.1, except: x, y) >= 2 }) else { continue }
                    line[y * w + x] = false
                    removed[y * w + x] = true
                }
            }
        }
        return removed
    }

    /// 바깥 테두리가 2칸 굵기면 안쪽 겹을 지울 칸을 골라요: 투명과 안 닿은 선 칸인데, 바로 바깥쪽(위·아래·왼·오른쪽) 이웃이
    /// 바깥 테두리 선이고 반대쪽 이웃이 칠 칸일 때예요. (바깥 테두리 1칸은 그대로라 실루엣은 그대로예요)
    static func outerBand(isLine: [Bool], opaque: [Bool], outside: [Bool], width w: Int, height h: Int) -> [Bool] {
        (0..<(w * h)).map { i in
            guard isLine[i], !outside[i] else { return false }
            let x = i % w, y = i / w
            return [(-1, 0), (1, 0), (0, -1), (0, 1)].contains { dx, dy in
                let ox = x + dx, oy = y + dy, ix = x - dx, iy = y - dy
                guard (0..<w).contains(ox), (0..<h).contains(oy), (0..<w).contains(ix), (0..<h).contains(iy) else { return false }
                let o = oy * w + ox, n = iy * w + ix
                return isLine[o] && outside[o] && opaque[n] && !isLine[n]
            }
        }
    }

    /// 투명 칸(또는 그림 끝)과 위·아래·왼·오른쪽으로 맞닿은 칸이에요. 바깥 테두리라 건드리지 않아요.
    static func touchesOutside(opaque: [Bool], width w: Int, height h: Int) -> [Bool] {
        (0..<(w * h)).map { i in
            let x = i % w, y = i / w
            return opaque[i] && [(-1, 0), (1, 0), (0, -1), (0, 1)].contains { dx, dy in
                !(0..<w).contains(x + dx) || !(0..<h).contains(y + dy) || !opaque[(y + dy) * w + x + dx]
            }
        }
    }

    /// 보통(게임 스프라이트)·약하게 결과용: 가장 어두운 색을 선으로 보고 모서리 칸을 이웃 칠 색(가장 많은 색)으로 바꿔요.
    static func apply(to conversion: Conversion) throws -> Conversion {
        let image = conversion.pixelArt
        let w = image.width, h = image.height
        guard var bytes = PixelExport.rgbaBytes(image) else { return conversion }
        let count = w * h
        func key(_ i: Int) -> UInt32 { UInt32(bytes[i * 4]) << 16 | UInt32(bytes[i * 4 + 1]) << 8 | UInt32(bytes[i * 4 + 2]) }
        let opaque = (0..<count).map { bytes[$0 * 4 + 3] > 127 }
        var darkest: (key: UInt32, light: Float)?
        for i in 0..<count where opaque[i] {
            let l = bytes.withUnsafeBufferPointer { MapleRamp.decodeLab($0.baseAddress!.advanced(by: i * 4), alpha: Int(bytes[i * 4 + 3])).x }
            if l < (darkest?.light ?? 2) { darkest = (key(i), l) }
        }
        guard let ink = darkest, ink.light < 0.35 else { return conversion }
        let inked = (0..<count).map { opaque[$0] && key($0) == ink.key }
        // 모자·검은 옷처럼 넓게 어두운 면은 선이 아니에요: 둘레 5×5 안이 절반 넘게 같은 색이면 빼요.
        let isLine = (0..<count).map { i -> Bool in
            guard inked[i] else { return false }
            let x = i % w, y = i / w
            var dark = 0, cells = 0
            for v in max(0, y - 2)...min(h - 1, y + 2) {
                for u in max(0, x - 2)...min(w - 1, x + 2) { cells += 1; if inked[v * w + u] { dark += 1 } }
            }
            return dark * 2 <= cells
        }
        let outside = touchesOutside(opaque: opaque, width: w, height: h)
        let band = outerBand(isLine: isLine, opaque: opaque, outside: outside, width: w, height: h)
        let thinned = (0..<count).map { isLine[$0] && !band[$0] }
        let cornerCut = corners(isLine: thinned, protected: outside, width: w, height: h)
        let removed = (0..<count).map { band[$0] || cornerCut[$0] }
        let before = bytes
        var changed = 0
        for i in 0..<count where removed[i] {
            let x = i % w, y = i / w
            var votes: [UInt32: (n: Int, at: Int)] = [:]
            for v in max(0, y - 1)...min(h - 1, y + 1) {
                for u in max(0, x - 1)...min(w - 1, x + 1) {
                    let j = v * w + u
                    guard opaque[j], !isLine[j] else { continue }
                    let k = UInt32(before[j * 4]) << 16 | UInt32(before[j * 4 + 1]) << 8 | UInt32(before[j * 4 + 2])
                    votes[k, default: (0, j)].n += 1
                }
            }
            guard let best = votes.max(by: { $0.value.n != $1.value.n ? $0.value.n < $1.value.n : $0.key > $1.key }) else { continue }
            for c in 0..<4 { bytes[i * 4 + c] = before[best.value.at * 4 + c] }
            changed += 1
        }
        guard changed > 0, let result = PixelExport.image(from: bytes, width: w, height: h) else { return conversion }
        var used: Set<UInt32> = []
        for i in 0..<count where bytes[i * 4 + 3] > 0 { used.insert(key(i)) }
        return Conversion(size: conversion.size, baseline: conversion.baseline, pixelArt: result, colorCount: used.count)
    }
}

extension MapleRamp {
    /// 메이플 램프용: 선 칸(음영 -1)의 모서리를 둘레 칠(재질·음영) 중 가장 많은 쪽으로 바꿔요.
    static func pixelPerfect(_ sprite: MapleSprite) -> MapleSprite {
        let w = sprite.width, h = sprite.height
        let opaque = sprite.material.map { $0 >= 0 }
        let isLine = sprite.material.indices.map { sprite.material[$0] >= 0 && sprite.tone[$0] < 0 }
        let outside = PixelPerfect.touchesOutside(opaque: opaque, width: w, height: h)
        let band = PixelPerfect.outerBand(isLine: isLine, opaque: opaque, outside: outside, width: w, height: h)
        let thinned = isLine.indices.map { isLine[$0] && !band[$0] }
        let cornerCut = PixelPerfect.corners(isLine: thinned, protected: outside, width: w, height: h)
        let removed = isLine.indices.map { band[$0] || cornerCut[$0] }
        var material = sprite.material, tone = sprite.tone
        for i in removed.indices where removed[i] {
            let x = i % w, y = i / w
            var votes: [SIMD2<Int>: Int] = [:]
            for v in max(0, y - 1)...min(h - 1, y + 1) {
                for u in max(0, x - 1)...min(w - 1, x + 1) {
                    let j = v * w + u
                    if sprite.material[j] >= 0, sprite.tone[j] >= 0 { votes[SIMD2(sprite.material[j], sprite.tone[j]), default: 0] += 1 }
                }
            }
            guard let best = votes.max(by: { $0.value != $1.value ? $0.value < $1.value : ($0.key.x, $0.key.y) > ($1.key.x, $1.key.y) })
            else { continue }
            material[i] = best.key.x; tone[i] = best.key.y
        }
        var counts = [Int](repeating: 0, count: sprite.materialCount)
        for m in material where m >= 0 { counts[m] += 1 }
        var result = MapleSprite(size: sprite.size, width: w, height: h, xOffset: sprite.xOffset, yOffset: sprite.yOffset,
                                 material: material, tone: tone, ramps: sprite.ramps, outlines: sprite.outlines,
                                 counts: counts, baseline: sprite.baseline, fixedOutline: sprite.fixedOutline)
        result.rim = sprite.rim
        result.rimInk = sprite.rimInk
        return result
    }
}
