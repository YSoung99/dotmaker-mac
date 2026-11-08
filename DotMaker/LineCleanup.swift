/// 도트화 결과의 선과 색을 다듬는다. 새 색은 만들지 않고, 이미 쓰는 이웃 색으로만 바꾼다.
/// 1) 검은 외곽선 바로 안쪽(2칸 이내)에 겹쳐 붙은 잉크 선을 깎아 외곽선이 한 줄로 보이게 한다(Zhang-Suen 세선화).
///    얼굴·장미처럼 더 안쪽 그림은 표정이 바뀌므로 건드리지 않는다.
/// 2) 주변과 비슷한 색인데 혼자 떨어진 1픽셀 얼룩을 주변 색으로 흡수한다. 대비가 큰 점(눈 하이라이트 등)은 남긴다.
enum LineCleanup {
    static func apply(_ raster: inout Raster, mask: [Bool], outline: [Bool], width: Int) {
        thinInk(&raster, mask: mask, outline: outline, width: width)
        removeSpecks(&raster, mask: mask, outline: outline)
    }

    static func isInk(_ p: Pixel) -> Bool { p.a > 0 && p.light < 70 && p.chroma < 60 }

    private static func thinInk(_ raster: inout Raster, mask: [Bool], outline: [Bool], width: Int) {
        let grid = raster.grid, w = grid.w, h = grid.h
        var line = mask.indices.map { mask[$0] && (outline[$0] || isInk(raster.pixels[$0])) }
        let depth = grid.depths(mask)
        let keep = mask.indices.map { outline[$0] || depth[$0] > width + 2 }
        func at(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && line[y * w + x] }
        var removed: [Int] = []
        var changed = true
        while changed {
            changed = false
            for pass in 0..<2 {
                var drop: [Int] = []
                for i in line.indices where line[i] && !keep[i] {
                    let x = i % w, y = i / w
                    // P2..P9: 위부터 시계 방향
                    let n = [at(x, y - 1), at(x + 1, y - 1), at(x + 1, y), at(x + 1, y + 1),
                             at(x, y + 1), at(x - 1, y + 1), at(x - 1, y), at(x - 1, y - 1)]
                    let count = n.filter { $0 }.count
                    guard (2...6).contains(count) else { continue }
                    var transitions = 0
                    for k in 0..<8 where !n[k] && n[(k + 1) % 8] { transitions += 1 }
                    guard transitions == 1 else { continue }
                    let ok = pass == 0
                        ? !(n[0] && n[2] && n[4]) && !(n[2] && n[4] && n[6])
                        : !(n[0] && n[2] && n[6]) && !(n[0] && n[4] && n[6])
                    if ok { drop.append(i) }
                }
                for i in drop { line[i] = false }
                removed += drop
                if !drop.isEmpty { changed = true }
            }
        }
        // 깎인 칸은 선이 아닌 이웃 중 가장 흔한 색으로 채운다(바깥쪽부터 순서대로 이어받음).
        for i in removed {
            if let fill = commonNeighbor(raster, i, mask: mask, skip: { line[$0] || isInk(raster.pixels[$0]) }) {
                raster.pixels[i] = fill
            } else {
                line[i] = true
            }
        }
    }

    /// 참·거짓 지도를 1픽셀 뼈대로 줄인다(Zhang-Suen). 연결은 유지된다.
    static func skeletonize(_ on: inout [Bool], grid: Grid) {
        let w = grid.w, h = grid.h
        func at(_ x: Int, _ y: Int) -> Bool { x >= 0 && y >= 0 && x < w && y < h && on[y * w + x] }
        var changed = true
        while changed {
            changed = false
            for pass in 0..<2 {
                var drop: [Int] = []
                for i in on.indices where on[i] {
                    let x = i % w, y = i / w
                    let n = [at(x, y - 1), at(x + 1, y - 1), at(x + 1, y), at(x + 1, y + 1),
                             at(x, y + 1), at(x - 1, y + 1), at(x - 1, y), at(x - 1, y - 1)]
                    let count = n.filter { $0 }.count
                    guard (2...6).contains(count) else { continue }
                    var transitions = 0
                    for k in 0..<8 where !n[k] && n[(k + 1) % 8] { transitions += 1 }
                    guard transitions == 1 else { continue }
                    let ok = pass == 0
                        ? !(n[0] && n[2] && n[4]) && !(n[2] && n[4] && n[6])
                        : !(n[0] && n[2] && n[6]) && !(n[0] && n[4] && n[6])
                    if ok { drop.append(i) }
                }
                for i in drop { on[i] = false }
                if !drop.isEmpty { changed = true }
            }
        }
    }

    private static func removeSpecks(_ raster: inout Raster, mask: [Bool], outline: [Bool]) {
        let grid = raster.grid
        let before = raster.pixels
        for i in mask.indices where mask[i] && !outline[i] && !isInk(before[i]) {
            var opaque = true, alone = true
            grid.each8(i) { j in
                if !mask[j] { opaque = false }
                if before[j] == before[i] { alone = false }
            }
            guard opaque, alone, !grid.edge(i) else { continue }
            var counts: [Int: (Int, Pixel)] = [:]
            grid.each8(i) { j in
                let p = before[j]
                guard !outline[j], !isInk(p) else { return }
                counts[key(p), default: (0, p)].0 += 1
            }
            guard let (votes, fill) = counts.values.max(by: { $0.0 < $1.0 }), votes >= 4,
                  fill.distance(to: before[i]) < 3000 else { continue }
            raster.pixels[i] = fill
        }
    }

    private static func commonNeighbor(_ raster: Raster, _ i: Int, mask: [Bool], skip: (Int) -> Bool) -> Pixel? {
        var counts: [Int: (Int, Pixel)] = [:]
        raster.grid.each8(i) { j in
            guard mask[j], !skip(j) else { return }
            counts[key(raster.pixels[j]), default: (0, raster.pixels[j])].0 += 1
        }
        return counts.values.max(by: { $0.0 < $1.0 })?.1
    }

    private static func key(_ p: Pixel) -> Int { Int(p.r) << 16 | Int(p.g) << 8 | Int(p.b) }
}
