/// 작게 줄이면 약해지는 볼터치를 살린다. 새 색은 만들지 않는다(볼터치 색 값만 진하게 바꾼다).
/// 볼터치 위치는 보라색 눈 두 개를 찾아 그 바로 아래로 본다. 눈 자체는 건드리지 않는다.
enum FaceDetail {
    static func apply(_ raster: inout Raster, mask: [Bool]) {
        deepenBlush(&raster, mask: mask, eyes: findEyes(raster, mask: mask))
    }

    /// Preserve an isolated dark stroke between a detected pair of eyes.
    static func preserveMouth(_ raster: inout Raster, source: Reduced) {
        let grid = raster.grid
        let eyes = findEyes(source.image, mask: source.cells.map { $0.cover >= 220 })
            .sorted { $0.minX < $1.minX }
        guard eyes.count == 2 else { return }
        let left = eyes[0], right = eyes[1]
        let x0 = left.maxX + 2, x1 = right.minX - 2
        let bottom = (left.maxY + right.maxY) / 2
        let height = max(2, min(left.maxY - left.minY, right.maxY - right.minY))
        let y0 = max(1, bottom - height / 3), y1 = min(grid.h - 2, bottom + height * 2 / 3)
        guard x1 - x0 >= 3, y0 <= y1 else { return }
        let candidates = source.cells.indices.map { i in
            let x = i % grid.w, y = i / grid.w, cell = source.cells[i]
            return x >= x0 && x <= x1 && y >= y0 && y <= y1 &&
                cell.cover >= 220 && cell.dark >= 20 && cell.ink.light < 85 &&
                (cell.dark >= 85 || cell.fill.light >= 180)
        }
        let pieces = grid.components(candidates).filter { piece in
            guard piece.count >= 3 else { return false }
            let xs = piece.map { $0 % grid.w }, ys = piece.map { $0 / grid.w }
            return xs.max()! - xs.min()! >= 2 && ys.max()! - ys.min()! <= height / 2
                && ys.min()! > y0 && ys.max()! < y1
        }
        guard pieces.count == 1, let mouth = pieces.first else { return }
        let columns = Dictionary(grouping: mouth, by: { $0 % grid.w })
        let stroke = columns.values.compactMap { column in
            column.max { source.cells[$0].dark < source.cells[$1].dark }
        }
        for i in stroke {
            let ink = source.cells[i].ink
            raster.pixels[i] = Pixel(ink.r, ink.g, ink.b, raster.pixels[i].a)
        }
    }

    private static func isEye(_ p: Pixel) -> Bool {
        p.a > 0 && !LineCleanup.isInk(p) && p.chroma > 24 && p.b > p.g && Int(p.b) >= Int(p.r) - 12
    }

    typealias Box = (minX: Int, maxX: Int, minY: Int, maxY: Int)

    /// 보라색 덩어리 중 크기가 비슷하고, 높이가 비슷하고, 옆으로 떨어진 두 개 가운데 가장 큰 짝을 눈으로 본다.
    /// (리본처럼 붙어 있는 작은 조각들은 제외된다)
    private static func findEyes(_ raster: Raster, mask: [Bool]) -> [Box] {
        let grid = raster.grid, w = grid.w
        let pieces = grid.components(mask.indices.map { mask[$0] && isEye(raster.pixels[$0]) })
            .filter { (12...260).contains($0.count) }
        func center(_ piece: [Int]) -> (x: Double, y: Double) {
            (Double(piece.map { $0 % w }.reduce(0, +)) / Double(piece.count),
             Double(piece.map { $0 / w }.reduce(0, +)) / Double(piece.count))
        }
        var best: (Int, [Int], [Int])?
        for a in pieces.indices {
            for b in pieces.indices where b > a {
                let p = pieces[a], q = pieces[b], cp = center(p), cq = center(q)
                let sizeGap = Double(abs(p.count - q.count)) / Double(max(p.count, q.count))
                let apart = abs(cp.x - cq.x) >= max(8, Double(min(p.count, q.count)).squareRoot() * 1.5)
                guard sizeGap < 0.6, abs(cp.y - cq.y) < 9, apart else { continue }
                let smaller = min(p.count, q.count)
                if smaller > (best?.0 ?? 0) { best = (smaller, p, q) }
            }
        }
        guard let (_, left, right) = best else { return [] }
        return [left, right].map { eye in
            let xs = eye.map { $0 % w }, ys = eye.map { $0 / w }
            return (xs.min()!, xs.max()!, ys.min()!, ys.max()!)
        }
    }

    /// 볼터치: 눈 바로 아래 영역에 가장 많은 연분홍.
    private static func deepenBlush(_ raster: inout Raster, mask: [Bool], eyes: [Box]) {
        guard !eyes.isEmpty else { return }
        let grid = raster.grid, w = grid.w
        var region = [Bool](repeating: false, count: grid.count)
        for eye in eyes {
            let ew = eye.maxX - eye.minX + 1, eh = eye.maxY - eye.minY + 1
            for y in max(0, eye.maxY - eh / 3)...min(grid.h - 1, eye.maxY + eh + eh / 2) {
                for x in max(0, eye.minX - ew / 2)...min(w - 1, eye.maxX + ew / 2) { region[y * w + x] = true }
            }
        }
        func pinkish(_ p: Pixel) -> Bool {
            p.a > 0 && p.light >= 185 && p.chroma >= 12 && p.chroma <= 70 && p.r > p.g && p.r >= p.b && !p.paper
        }
        var counts: [Int: (Int, Pixel)] = [:]
        for i in region.indices where region[i] && mask[i] && pinkish(raster.pixels[i]) {
            counts[key(raster.pixels[i]), default: (0, raster.pixels[i])].0 += 1
        }
        guard let (count, blush) = counts.values.max(by: { $0.0 < $1.0 }), count >= 4 else { return }
        let deeper = saturated(blush, by: 1.9)
        for i in raster.pixels.indices where raster.pixels[i] == blush { raster.pixels[i] = deeper }
    }

    /// 밝기(최댓값)는 두고 채도만 올린다.
    private static func saturated(_ p: Pixel, by factor: Double) -> Pixel {
        let maxC = Double(max(p.r, p.g, p.b)), minC = Double(min(p.r, p.g, p.b))
        guard maxC > 0 else { return p }
        let s = min(0.45, (maxC - minC) / maxC * factor)
        func channel(_ c: UInt8) -> UInt8 {
            let t = maxC == minC ? 0 : (maxC - Double(c)) / (maxC - minC)
            return UInt8(max(0, min(255, (maxC - t * s * maxC).rounded())))
        }
        return Pixel(channel(p.r), channel(p.g), channel(p.b), p.a)
    }

    private static func key(_ p: Pixel) -> Int { Int(p.r) << 16 | Int(p.g) << 8 | Int(p.b) }
}
