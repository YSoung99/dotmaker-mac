import CoreGraphics
import Foundation
import simd

/// 선과 그림 사이 중간색: 선 바로 안쪽 1칸을 '그림 색 80% + 선 색 20%'에 가장 가까운, 이미 쓰는 더 어두운 색으로 칠해요.
/// (사용자 요청: 하얀 몸통과 검은 선 사이 등)
///
/// 게임 스프라이트처럼 이미 다 그려진 결과에 써요. 선은 결과에서 가장 어두운 색이에요.
/// 그 안쪽 칸도 같은 색일 때만 칠해서, 1칸짜리 가는 부분(눈동자, 가는 머리카락)은 그대로 둬요.
/// 그림 바깥 테두리 선 안쪽에만 칠해요. 눈·입·머리카락 같은 안쪽 선 둘레는 그대로 둬요. (사용자 요청)
enum RimShade {
    static let defaultInk: Float = 0.2
    /// 바깥 테두리로 치는 선: 투명(또는 그림 끝)에서 이 칸 수 안에 있는 선이에요. 굵은 테두리(2칸)까지 넣어요.
    static let outerLineDepth = 2

    /// 칸마다 가장 가까운 투명 칸(그림 밖 포함)까지의 거리(위·아래·왼·오른쪽 걸음 수). 투명 칸은 0이에요.
    static func edgeDistance(opaque: [Bool], width w: Int, height h: Int) -> [Int] {
        var distance = opaque.map { $0 ? Int.max : 0 }
        var queue: [Int] = []
        for i in 0..<(w * h) {
            let x = i % w, y = i / w
            if !opaque[i] { queue.append(i) } else if x == 0 || y == 0 || x == w - 1 || y == h - 1 { distance[i] = 1; queue.append(i) }
        }
        var head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            let x = i % w, y = i / w
            for (dx, dy) in [(-1, 0), (1, 0), (0, -1), (0, 1)] {
                let u = x + dx, v = y + dy
                guard (0..<w).contains(u), (0..<h).contains(v) else { continue }
                let j = v * w + u
                if distance[j] > distance[i] + 1 { distance[j] = distance[i] + 1; queue.append(j) }
            }
        }
        return distance
    }

    static func apply(to conversion: Conversion, ink share: Float) throws -> Conversion {
        let image = conversion.pixelArt
        let w = image.width, h = image.height
        guard share > 0, var bytes = PixelExport.rgbaBytes(image) else { return conversion }
        func key(_ i: Int) -> UInt32 {
            (UInt32(bytes[i * 4]) << 16) | (UInt32(bytes[i * 4 + 1]) << 8) | UInt32(bytes[i * 4 + 2])
        }
        func lab(_ i: Int) -> SIMD3<Float> {
            bytes.withUnsafeBufferPointer { MapleRamp.decodeLab($0.baseAddress!.advanced(by: i * 4), alpha: Int(bytes[i * 4 + 3])) }
        }
        // 선 색: 쓰인 색 중 가장 어두운 색 (충분히 어두울 때만)
        var darkest: (key: UInt32, lab: SIMD3<Float>)?
        for i in 0..<(w * h) where bytes[i * 4 + 3] > 127 {
            let c = lab(i)
            if c.x < (darkest?.lab.x ?? 2) { darkest = (key(i), c) }
        }
        guard let ink = darkest, ink.lab.x < 0.35 else { return conversion }
        let original = bytes
        // 새 색을 만들지 않게, 섞은 색에 가장 가까운 '이미 쓰는 더 어두운 색'으로 맞춰요. (원탁회의 결론 3번)
        var palette: [UInt32: SIMD3<Float>] = [:]
        for i in 0..<(w * h) where bytes[i * 4 + 3] > 127 && palette[key(i)] == nil { palette[key(i)] = lab(i) }
        let choices = palette.filter { $0.key != ink.key }.sorted { $0.key < $1.key }
        let distance = edgeDistance(opaque: (0..<(w * h)).map { original[$0 * 4 + 3] > 127 }, width: w, height: h)
        func opaque(_ x: Int, _ y: Int) -> Bool { (0..<w).contains(x) && (0..<h).contains(y) && original[(y * w + x) * 4 + 3] > 127 }
        func colorKey(_ x: Int, _ y: Int) -> UInt32 {
            let i = (y * w + x) * 4
            return (UInt32(original[i]) << 16) | (UInt32(original[i + 1]) << 8) | UInt32(original[i + 2])
        }
        for y in 0..<h {
            for x in 0..<w where opaque(x, y) {
                let own = colorKey(x, y)
                guard own != ink.key else { continue }
                let rim = [(-1, 0), (1, 0), (0, -1), (0, 1)].contains { dx, dy in
                    opaque(x + dx, y + dy) && colorKey(x + dx, y + dy) == ink.key
                        && distance[(y + dy) * w + x + dx] <= outerLineDepth
                        && distance[y * w + x] > distance[(y + dy) * w + x + dx]
                        && opaque(x - dx, y - dy) && colorKey(x - dx, y - dy) == own
                }
                guard rim else { continue }
                let i = y * w + x
                let fill = lab(i)
                let mixed = fill * (1 - share) + ink.lab * share
                // 더 어둡고, 색감(a·b)이 섞은 색과 거의 같고(0.015 안), 밝기도 가까운(0.12 안) 색만.
                // 없으면 그대로 둬요. (흰 몸통에 분홍 띠 같은 엉뚱한 색 방지)
                guard let pick = choices.filter({
                    $0.value.x < fill.x - 0.01 && abs($0.value.x - mixed.x) < 0.12
                        && simd_distance(SIMD2($0.value.y, $0.value.z), SIMD2(mixed.y, mixed.z)) < 0.015
                })
                    .min(by: { simd_distance($0.value, mixed) < simd_distance($1.value, mixed) }) else { continue }
                bytes[i * 4] = UInt8(pick.key >> 16 & 0xFF); bytes[i * 4 + 1] = UInt8(pick.key >> 8 & 0xFF)
                bytes[i * 4 + 2] = UInt8(pick.key & 0xFF); bytes[i * 4 + 3] = 255
            }
        }
        guard let shaded = PixelExport.image(from: bytes, width: w, height: h) else { return conversion }
        var used: Set<UInt32> = []
        for i in 0..<(w * h) where bytes[i * 4 + 3] > 0 { used.insert(key(i)) }
        return Conversion(size: conversion.size, baseline: conversion.baseline, pixelArt: shaded, colorCount: used.count)
    }
}
