import CoreGraphics
import Foundation
import simd

/// 플랫 외곽선: 안쪽 그림(음영·안쪽 선·색)은 게임 스프라이트 결과 그대로 두고,
/// 바깥 테두리만 무조건 순검정(#000000) 1px로 바꿔요. (사용자 요청)
enum FlatDot {
    static let smallPiece = 12

    static func outline(_ conversion: Conversion) throws -> Conversion {
        let w = conversion.pixelArt.width, h = conversion.pixelArt.height
        guard var bytes = PixelExport.rgbaBytes(conversion.pixelArt) else { throw ConversionError.cannotRender }
        let count = w * h
        // 반투명 칸(기본 강도의 부드러운 가장자리)은 검정선 바깥에 흐리게 남아요. 반 넘게 보이면 불투명, 아니면 투명으로 정해요.
        for i in 0..<count where bytes[i * 4 + 3] < 255 {
            let alpha = Int(bytes[i * 4 + 3])
            for c in 0..<3 { bytes[i * 4 + c] = alpha > 127 ? UInt8(min(255, (Int(bytes[i * 4 + c]) * 255 + alpha / 2) / alpha)) : 0 }
            bytes[i * 4 + 3] = alpha > 127 ? 255 : 0
        }
        let sides = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        var opaque = (0..<count).map { bytes[$0 * 4 + 3] > 127 }
        func isOpaque(_ x: Int, _ y: Int) -> Bool { (0..<w).contains(x) && (0..<h).contains(y) && opaque[y * w + x] }
        func neighbors(_ i: Int) -> [Int] {
            sides.compactMap { isOpaque(i % w + $0, i / w + $1) ? (i / w + $1) * w + i % w + $0 : nil }
        }
        func key(_ i: Int) -> UInt32 { UInt32(bytes[i * 4]) << 16 | UInt32(bytes[i * 4 + 1]) << 8 | UInt32(bytes[i * 4 + 2]) }
        func setOpaque(_ i: Int, like j: Int) {
            for c in 0..<3 { bytes[i * 4 + c] = bytes[j * 4 + c] }
            bytes[i * 4 + 3] = 255
            opaque[i] = true
        }
        func clear(_ i: Int) {
            for c in 0..<4 { bytes[i * 4 + c] = 0 }
            opaque[i] = false
        }

        // 작은 조각(반짝이 등)은 따로 다뤄요. 칸 수를 세어 둬요.
        var piece = Array(repeating: -1, count: count)
        var pieceSize: [Int] = []
        for start in 0..<count where opaque[start] && piece[start] < 0 {
            let id = pieceSize.count
            var stack = [start], size = 0
            piece[start] = id
            while let i = stack.popLast() {
                size += 1
                for j in neighbors(i) where piece[j] < 0 { piece[j] = id; stack.append(j) }
            }
            pieceSize.append(size)
        }
        func small(_ i: Int) -> Bool { piece[i] >= 0 && pieceSize[piece[i]] <= smallPiece }

        // 1) 실루엣 다듬기: 1칸짜리 가시는 지우고, 1칸짜리 홈은 메워요. (검정이 삐죽 튀어나오거나 안으로 파이지 않게)
        for i in 0..<count where opaque[i] && !small(i) && neighbors(i).count <= 1 { clear(i) }
        for i in 0..<count where !opaque[i] {
            let around = neighbors(i)
            if around.count >= 3, !around.contains(where: small) { setOpaque(i, like: around[0]); piece[i] = piece[around[0]] }
        }

        // 2) 실루엣 가장자리: 위·아래·왼·오른쪽 중 하나라도 투명(또는 그림 끝)인 칸 / 작은 조각은 그 바깥 투명 칸
        var edge = (0..<count).map { i -> Bool in
            if opaque[i] { return !small(i) && neighbors(i).count < 4 }
            return neighbors(i).contains(where: small)
        }

        // 3) 계단 모서리: 가장자리 칸이 가로 하나·세로 하나의 가장자리 칸에만 붙어 있으면(ㄱ자) 검정이 2칸으로 겹쳐 보여요.
        //    그 모서리 칸을 비워서 대각선으로 1칸씩 이어지게 해요. (안쪽 칸이 바깥에 드러나지 않을 때만)
        for i in 0..<count where opaque[i] && edge[i] && !small(i) {
            let around = neighbors(i)
            guard around.count == 2, around.allSatisfy({ edge[$0] }),
                  abs(around[0] - around[1]) != 2, abs(around[0] - around[1]) != 2 * w else { continue }
            clear(i)
            edge[i] = false
        }

        // 4) 원래 테두리(가장자리에 가장 많던 색, 거의 검정, 또는 안쪽 이웃보다 확 어두운 색)가
        //    새 검정선 안쪽에 한 겹 더 남으면 2px처럼 보여요. 그런 칸은 안쪽 이웃 색으로 메워요.
        //    (최대 2겹, 안쪽 이웃이 없으면 그대로 둬요)
        var edgeColors: [UInt32: Int] = [:]
        for i in 0..<count where opaque[i] && edge[i] { edgeColors[key(i), default: 0] += 1 }
        let ink = edgeColors.max { $0.value != $1.value ? $0.value < $1.value : $0.key > $1.key }?.key
        func lab(_ i: Int) -> SIMD3<Float> {
            bytes.withUnsafeBufferPointer { MapleRamp.decodeLab($0.baseAddress!.advanced(by: i * 4), alpha: 255) }
        }
        func lineLike(_ i: Int) -> Bool {
            if key(i) == ink { return true }
            let c = lab(i)
            return c.x < 0.32 && simd_length(SIMD2(c.y, c.z)) < 0.07
        }
        var ring = edge
        for _ in 0..<2 {
            let before = bytes
            var next = ring
            for i in 0..<count where opaque[i] && !ring[i] {
                let x = i % w, y = i / w
                guard neighbors(i).contains(where: { ring[$0] }) else { continue }
                let own = key(i)
                var votes: [UInt32: (count: Int, index: Int)] = [:]
                for v in max(0, y - 1)...min(h - 1, y + 1) {
                    for u in max(0, x - 1)...min(w - 1, x + 1) {
                        let j = v * w + u
                        guard opaque[j], !ring[j], !lineLike(j), key(j) != own else { continue }
                        votes[key(j), default: (0, j)].count += 1
                    }
                }
                guard let best = votes.max(by: { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key > $1.key })
                else { continue }
                // 안쪽 색보다 확 어두운 테두리 색(예: 로켓 날개의 진한 청록 테두리)도 메워요.
                guard lineLike(i) || lab(i).x < lab(best.value.index).x - 0.12 else { continue }
                for c in 0..<3 { bytes[i * 4 + c] = before[best.value.index * 4 + c] }
                next[i] = true
            }
            ring = next
        }

        for i in 0..<count where edge[i] {
            bytes[i * 4] = 0; bytes[i * 4 + 1] = 0; bytes[i * 4 + 2] = 0; bytes[i * 4 + 3] = 255
        }
        guard let image = PixelExport.image(from: bytes, width: w, height: h) else { throw ConversionError.cannotRender }
        var used: Set<UInt32> = []
        for i in 0..<count where bytes[i * 4 + 3] > 0 { used.insert(key(i)) }
        return Conversion(size: conversion.size, baseline: conversion.baseline, pixelArt: image, colorCount: used.count)
    }
}
