import CoreGraphics
import Foundation
import simd

/// 칸 색 '두 단계' (깃허브 Pixel Art Fixer의 two-stage를 원리만 따라 직접 만듦) — AI 도트화의 색 줄이기에 써요.
///
/// 1단계(구조): 원본 표본을 24색으로 단순하게 나눠 칸마다 가운데 가중 투표 → 경계 위치가 또렷해져요.
/// 2단계(색): 이긴 묶음에 든 '원본 표본'만 가중 평균 → 색은 원본의 실제 색이에요.
/// 칸이 반 넘게 덮였을 때만 칸을 만들어서 가장자리에 반투명 칸이 안 생겨요.
enum CellSampler {
    static let side = 6

    static func twoStage(_ image: CGImage, width: Int, height: Int) throws -> [SIMD3<Float>?] {
        let samples = try PixelConverter.rasterize(image, width: width * side, height: height * side,
                                                   rect: CGRect(x: 0, y: 0, width: width * side, height: height * side))
        guard let data = samples.data else { throw ConversionError.cannotRender }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let stride = samples.bytesPerRow
        let center = Float(side - 1) / 2
        // 칸 가운데에 가까운 표본일수록 무겁게 쳐요.
        let weight = (0..<(side * side)).map { n -> Float in
            let dx = Float(n % side) - center, dy = Float(n / side) - center
            return 1 / (1 + (dx * dx + dy * dy) / 4)
        }
        var cells = [[(lab: SIMD3<Float>, w: Float)]?](repeating: nil, count: width * height)
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                var coverage = 0
                var points: [(lab: SIMD3<Float>, w: Float)] = []
                for sy in 0..<side {
                    for sx in 0..<side {
                        let offset = (y * side + sy) * stride + (x * side + sx) * 4
                        let a = Int(bytes[offset + 3])
                        coverage += a
                        guard a > 127 else { continue }
                        points.append((MapleRamp.decodeLab(bytes.advanced(by: offset), alpha: a), weight[sy * side + sx]))
                    }
                }
                if coverage * 2 >= 255 * side * side, !points.isEmpty { cells[y * width + x] = points }
            }
        }
        // 1단계: 구조용 24색 (출력에는 안 써요)
        var pool: [SIMD3<Float>] = []
        for points in cells.compactMap({ $0 }) { for (n, p) in points.enumerated() where n % 3 == 0 { pool.append(p.lab) } }
        guard !pool.isEmpty else { return cells.map { _ in nil } }
        var rng = SplitMix(seed: 7)
        let k = min(24, pool.count)
        let labels = try MapleRamp.kmeans(pool, k: k, rng: &rng, iterations: 15)
        var sums = [SIMD3<Float>](repeating: .zero, count: k), counts = [Float](repeating: 0, count: k)
        for (n, p) in pool.enumerated() { sums[labels[n]] += p; counts[labels[n]] += 1 }
        let centers = (0..<k).map { counts[$0] > 0 ? sums[$0] / counts[$0] : SIMD3<Float>(9, 9, 9) }
        func label(_ p: SIMD3<Float>) -> Int {
            var best = 0, distance = Float.infinity
            for (c, center) in centers.enumerated() {
                let d = simd_distance_squared(p, center)
                if d < distance { distance = d; best = c }
            }
            return best
        }
        // 2단계: 이긴 묶음의 원본 표본만 가중 평균
        return try cells.map { points in
            try Task.checkCancellation()
            guard let points else { return nil }
            let tagged = points.map { (label($0.lab), $0) }
            var votes = [Float](repeating: 0, count: k)
            for (l, p) in tagged { votes[l] += p.w }
            let winner = votes.indices.max { votes[$0] < votes[$1] }!
            var total = SIMD3<Float>.zero, wsum: Float = 0
            for (l, p) in tagged where l == winner { total += p.lab * p.w; wsum += p.w }
            return total / wsum
        }
    }

    /// '약하게' 강도용: 두 단계로 칸 색을 고른 뒤 OKLab k-means로 최대 색 수에 맞춰 칠해요.
    static func convert(_ source: SourceImage, size: PixelSize, colors: Int) throws -> Conversion {
        let scale = min(Double(size.width) / Double(source.size.width), Double(size.height) / Double(source.size.height))
        let width = max(1, min(size.width, Int((Double(source.size.width) * scale).rounded())))
        let height = max(1, min(size.height, Int((Double(source.size.height) * scale).rounded())))
        let xOffset = (size.width - width) / 2, top = (size.height - height) / 2
        let fitted = CGRect(x: xOffset, y: size.height - height - top, width: width, height: height)
        guard let baseline = try PixelConverter.rasterize(source.image, width: size.width, height: size.height, rect: fitted)
            .makeImage() else { throw ConversionError.cannotRender }
        let cells = try twoStage(source.image, width: width, height: height)
        let opaque = cells.indices.filter { cells[$0] != nil }
        var rng = SplitMix(seed: 0)
        let points = opaque.map { cells[$0]! }
        let labels = try MapleRamp.kmeans(points, k: min(colors, points.count), rng: &rng)
        // 묶음 색은 평균 대신 묶음 안 중앙값에 가장 가까운 실제 칸 색으로 해서 탁해지지 않게 해요.
        let groups = (labels.max() ?? -1) + 1
        var members = [[SIMD3<Float>]](repeating: [], count: groups)
        for (n, l) in labels.enumerated() { members[l].append(points[n]) }
        func middle(_ v: [Float]) -> Float { let s = v.sorted(); return s[s.count / 2] }
        let palette = members.map { m -> SIMD3<Float> in
            guard !m.isEmpty else { return .zero }
            let target = SIMD3(middle(m.map(\.x)), middle(m.map(\.y)), middle(m.map(\.z)))
            return m.min { simd_distance_squared($0, target) < simd_distance_squared($1, target) }!
        }
        var bytes = [UInt8](repeating: 0, count: size.width * size.height * 4)
        var used: Set<UInt32> = []
        for (n, i) in opaque.enumerated() {
            let rgb = MapleRamp.encode(palette[labels[n]])
            let o = ((i / width + top) * size.width + i % width + xOffset) * 4
            bytes[o] = rgb.x; bytes[o + 1] = rgb.y; bytes[o + 2] = rgb.z; bytes[o + 3] = 255
            used.insert(UInt32(rgb.x) << 16 | UInt32(rgb.y) << 8 | UInt32(rgb.z))
        }
        guard let image = PixelExport.image(from: bytes, width: size.width, height: size.height) else { throw ConversionError.cannotRender }
        return Conversion(size: size, baseline: baseline, pixelArt: image, colorCount: used.count)
    }
}
