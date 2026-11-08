import CoreGraphics

struct Cell: Sendable {
    var fill = Pixel.clear
    var ink = Pixel.black
    var cover = 0
    var dark = 0
    var accent = 0
    var accentColor = Pixel.clear
}

struct Reduced: Sendable {
    let image: Raster
    let cells: [Cell]

    let direct: Bool
    let contentRect: CGRect

    init(subject: Raster, w: Int, h: Int, direct: Bool = false) throws {
        guard (16...512).contains(w), (16...512).contains(h) else { throw DotError.dimensions }
        let scale = min(Double(w - 4) / Double(subject.grid.w), Double(h - 4) / Double(subject.grid.h))
        let sw = max(1, Int((Double(subject.grid.w) * scale).rounded()))
        let sh = max(1, Int((Double(subject.grid.h) * scale).rounded()))
        let x = (w - sw) / 2, y = (h - sh) / 2
        let factor = 6
        let sampled = direct ? subject : try Raster(subject.image(), width: sw * factor, height: sh * factor)
        let columns = Self.overlaps(source: sampled.grid.w, target: sw)
        let rows = Self.overlaps(source: sampled.grid.h, target: sh)
        let area = sampled.grid.w * sampled.grid.h
        var output = Raster(w: w, h: h)
        var cells = [Cell](repeating: Cell(), count: output.grid.count)

        for v in 0..<sh {
            try Task.checkCancellation()
            for u in 0..<sw {
                var average = Accumulator(), fill = Accumulator(), ink = Accumulator(), accent = Accumulator()
                for row in rows[v] {
                    for column in columns[u] {
                        let p = sampled.pixels[row.index * sampled.grid.w + column.index]
                        if p.a == 0 { continue }
                        let weight = row.length * column.length
                        average.add(p, area: weight)
                        if p.light < 110 { ink.add(p, area: weight) } else { fill.add(p, area: weight) }
                        if p.chroma >= 28 && p.light >= 100 { accent.add(p, area: weight) }
                    }
                }
                let cover = average.weight / area
                guard cover > 0 else { continue }
                let dark = ink.weight * 100 / average.weight
                let accentShare = accent.weight * 100 / average.weight
                let mean = average.color, fillColor = fill.weight == 0 ? mean : fill.color
                let i = (v + y) * w + u + x
                cells[i] = Cell(fill: fillColor, ink: ink.color, cover: cover, dark: dark,
                                accent: accentShare, accentColor: accent.color)
                // Restore contrast on strokes supported by multiple subpixels.
                let p = dark >= 25 && dark < 75 && cover >= 150
                    ? mean.mixed(with: ink.color, percent: (dark - 20) / 2)
                    : mean
                output.pixels[i] = Pixel(p.r, p.g, p.b, UInt8(cover))
            }
        }

        self.image = output
        self.cells = cells
        self.direct = direct
        self.contentRect = CGRect(x: x, y: y, width: sw, height: sh)
    }

    // Integer coordinates in units of 1/target source pixels give exact overlaps.
    // Each target cell has total area sourceWidth × sourceHeight in these units.
    private static func overlaps(source: Int, target: Int) -> [[(index: Int, length: Int)]] {
        (0..<target).map { cell in
            let start = cell * source, end = (cell + 1) * source
            return (start / target ... (end - 1) / target).map { pixel in
                let length = min(end, (pixel + 1) * target) - max(start, pixel * target)
                return (pixel, length)
            }
        }
    }
}

private struct Accumulator {
    var r = 0, g = 0, b = 0, weight = 0
    mutating func add(_ p: Pixel, area: Int = 1) {
        let a = Int(p.a) * area
        r += Int(p.r) * a; g += Int(p.g) * a; b += Int(p.b) * a; weight += a
    }
    var color: Pixel {
        guard weight > 0 else { return .black }
        return Pixel(UInt8(r / weight), UInt8(g / weight), UInt8(b / weight))
    }
}

struct DotSettings: Equatable, Sendable {
    var width = 1
    var boundary = true
    var transparency = 80
    var colors = 12
    var cleanup = 1
    var method = DotMethod.berry
    /// 원본 보존: 가장 바깥 외곽선을 검은 1픽셀로 또렷하게
    var crispOutline = false
    /// 원본 보존: 경계에서 양쪽 색이 섞여 생긴 중간색을 가까운 쪽 색으로
    var cleanBlends = false

}

struct Dotted: Sendable {
    let image: Raster
    let mask: [Bool]
    let outline: [Bool]
    let boundary: [Bool]
    let bodyCount: Int
    let headCount: Int
}

enum Dotting {
    static func preserve(_ input: Reduced) throws -> Dotted {
        try preserve(image: input.image)
    }

    /// Averaging a cell that straddles two very different colors leaves a muddy in-between color
    /// (red + black → maroon). Snap such a cell to whichever neighbor color it is closer to.
    /// Neighbors closer than `minGap` (gentle shading ramps) are left alone.
    static func cleanBlends(_ input: Raster) -> Raster {
        var output = input
        for (i, pick) in blendCandidates(input) { output.pixels[i] = pick.near }
        return output
    }

    /// For each muddy in-between cell: the nearer of the two source colors, and the darker one (the line side).
    static func blendCandidates(_ input: Raster) -> [Int: (near: Pixel, dark: Pixel)] {
        let minGap = 120.0, maxOff = 28.0, minAway = 30.0
        func vec(_ p: Pixel) -> SIMD3<Double> { SIMD3(Double(p.r), Double(p.g), Double(p.b)) }
        func length(_ v: SIMD3<Double>) -> Double { (v * v).sum().squareRoot() }
        var picks: [Int: (near: Pixel, dark: Pixel)] = [:]
        for i in input.pixels.indices where input.pixels[i].a >= 128 {
            let c = vec(input.pixels[i])
            var around: [Pixel] = []
            input.grid.each8(i) { j in if input.pixels[j].a >= 128 { around.append(input.pixels[j]) } }
            var best: (off: Double, near: Pixel, dark: Pixel)?
            for m in around.indices {
                for n in around.indices where n > m {
                    let a = vec(around[m]), b = vec(around[n]), ab = b - a
                    let gap = length(ab)
                    guard gap >= minGap, length(c - a) >= minAway, length(c - b) >= minAway else { continue }
                    let t = ((c - a) * ab).sum() / (gap * gap)
                    guard (0.15...0.85).contains(t) else { continue }
                    let off = length(c - (a + ab * t))
                    // Gray triples are nearly collinear, so many pairs tie; a margin keeps float noise from reordering them.
                    if off <= maxOff, off < (best?.off ?? .infinity) - 1e-6 {
                        let dark = around[m].light <= around[n].light ? around[m] : around[n]
                        best = (off, t < 0.5 ? around[m] : around[n], dark)
                    }
                }
            }
            if let best {
                let a = input.pixels[i].a
                picks[i] = (Pixel(best.near.r, best.near.g, best.near.b, a), Pixel(best.dark.r, best.dark.g, best.dark.b, a))
            }
        }
        return picks
    }

    /// Redraws the outermost silhouette as a crisp one-pixel black line and drops faint pixels outside it.
    /// A piece whose rim is mostly light (an intentional white outline) keeps its own rim colors.
    static func crispOutline(_ input: Raster) -> Raster {
        var output = Raster(w: input.grid.w, h: input.grid.h)
        let solid = input.pixels.map { $0.a >= 128 }
        for piece in input.grid.components(solid) {
            let rim = piece.filter { i in
                var edge = false
                input.grid.each4(i) { j in if !solid[j] { edge = true } }
                return edge
            }
            let lightRim = rim.filter { input.pixels[$0].light >= 170 }.count * 2 > rim.count
            // A mid-gray rim along the bottom of a piece is a ground shadow, not part of the outline.
            let rows = piece.map { $0 / input.grid.w }
            let top = rows.min()!, bottom = rows.max()!
            let floor = bottom - max(3, (bottom - top) * 8 / 100)
            func shadow(_ i: Int) -> Bool {
                let p = input.pixels[i]
                return i / input.grid.w >= floor && p.chroma <= 24 && (45...180).contains(p.light)
            }
            let outline = Set(lightRim ? [] : rim.filter { !shadow($0) })
            for i in piece {
                let p = input.pixels[i]
                output.pixels[i] = outline.contains(i) ? .black : Pixel(p.r, p.g, p.b)
            }
        }
        return output
    }

    static func preserve(image: Raster) throws -> Dotted {
        let mask = image.pixels.map { $0.a > 0 }
        guard mask.contains(true) else { throw DotError.subject }
        return Dotted(image: image, mask: mask, outline: image.grid.depths(mask).map { $0 == 1 },
                      boundary: [Bool](repeating: false, count: mask.count), bodyCount: 0, headCount: 0)
    }

    static func render(_ input: Reduced, settings: DotSettings, mask: [Bool]? = nil,
                       details: [Int: Pixel] = [:]) throws -> Dotted {
        try Task.checkCancellation()
        let grid = input.image.grid
        let cells = input.cells
        let mask = mask ?? input.cells.map { $0.cover >= 116 }
        guard mask.contains(true) else { throw DotError.subject }

        // A Manhattan distance band gives one pixel on horizontal and vertical edges.
        // Derive both widths from the same silhouette so the extra ring goes inward.
        var depth = [Int](repeating: 0, count: grid.count)
        var frontier: [Int] = []
        for i in mask.indices where mask[i] {
            var edge = grid.edge(i)
            grid.each4(i) { if !mask[$0] { edge = true } }
            if edge { depth[i] = 1; frontier.append(i) }
        }
        var next = 0
        while next < frontier.count {
            if next.isMultiple(of: 4096) { try Task.checkCancellation() }
            let i = frontier[next]
            grid.each4(i) { j in
                if mask[j] && depth[j] == 0 { depth[j] = depth[i] + 1; frontier.append(j) }
            }
            next += 1
        }
        let outline = depth.map { (1...settings.width).contains($0) }
        let head = grid.components(mask.indices.map { mask[$0] && cells[$0].fill.pink })
            .max { $0.count < $1.count } ?? []
        let headY = head.isEmpty ? 0 : head.map { $0 / grid.w }.reduce(0, +) / head.count
        let body = grid.components(mask.indices.map {
            depth[$0] > settings.width && $0 / grid.w > headY && cells[$0].fill.paper
        }, diagonal: false).max { $0.count < $1.count } ?? []
        let isBody = Set(body)
        var boundary = [Bool](repeating: false, count: grid.count)
        let palette = Palette(mask.indices.compactMap { i in
            mask[i] && !outline[i] && cells[i].dark < 57 ? cells[i].fill : nil
        })

        // Remove the original stroke only where it clings to the new silhouette.
        // Interior strokes with support deeper in the character remain available.
        var rim = outline
        for layer in (settings.width + 1)...(settings.width + 2) {
            for i in mask.indices where depth[i] == layer && cells[i].dark >= 18 {
                var attached = false
                grid.each4(i) { j in
                    if depth[j] == layer - 1 && rim[j] { attached = true }
                }
                if attached { rim[i] = true }
            }
        }

        var output = Raster(w: grid.w, h: grid.h)
        for i in mask.indices where mask[i] {
            if i.isMultiple(of: 4096) { try Task.checkCancellation() }
            if outline[i] { output.pixels[i] = .black; continue }
            let cell = cells[i]
            let color: Pixel
            var bodyEdge = isBody.contains(i)
            if let detail = details[i] {
                color = detail.light < 100 ? detail : palette.nearest(to: detail, preservingSmallColor: true)
            } else if cell.dark >= 48 && !rim[i] {
                color = Pixel(max(13, cell.ink.r), max(10, cell.ink.g), max(13, cell.ink.b))
            } else {
                var fill = cell.fill
                if depth[i] <= settings.width + 2 {
                    var anchors: [Int] = []
                    grid.each8(i) { j in
                        if depth[j] > depth[i] && cells[j].dark < 30 { anchors.append(j) }
                    }
                    let hairAnchors = anchors.filter { cells[$0].fill.pink }
                    let bodyAnchors = anchors.filter(isBody.contains)
                    if !fill.pink && !bodyAnchors.isEmpty && bodyAnchors.count > hairAnchors.count &&
                        (fill.paper || (rim[i] && fill.chroma < 38)) {
                        bodyEdge = true
                        fill = cells[bodyAnchors[0]].fill
                    } else if rim[i] && !fill.pink && hairAnchors.count * 2 > anchors.count &&
                                (fill.chroma < 36 || fill.light < 158) {
                        fill = cells[hairAnchors[0]].fill
                    } else if rim[i] && (cell.dark > 45 || fill.light < 158),
                              let nearest = anchors.min(by: {
                                  cells[$0].fill.distance(to: fill) < cells[$1].fill.distance(to: fill)
                              }) {
                        fill = cells[nearest].fill
                    }
                }
                color = palette.nearest(to: fill)
            }
            boundary[i] = depth[i] == settings.width + 1 && bodyEdge && color.paper
            if settings.boundary && boundary[i] {
                let intermediate = color.mixed(with: .black, percent: 50)
                output.pixels[i] = color.mixed(with: intermediate, percent: 100 - settings.transparency)
            } else {
                output.pixels[i] = color
            }
        }
        LineCleanup.apply(&output, mask: mask, outline: outline, width: settings.width)
        FaceDetail.apply(&output, mask: mask)
        output = try ColorReducer.apply(output, outline: outline, boundary: boundary, settings: settings)
        return Dotted(image: output, mask: mask, outline: outline, boundary: boundary, bodyCount: body.count, headCount: head.count)
    }
}

private struct Palette {
    let colors: [[Pixel]]

    init(_ pixels: [Pixel]) {
        var counts = Array(repeating: [Int: Accumulator](), count: 4)
        for p in pixels {
            let key = Int(p.r / 22) * 144 + Int(p.g / 22) * 12 + Int(p.b / 22)
            let family = Self.family(p)
            counts[family][key, default: Accumulator()].add(p)
        }
        let limits = [4, 6, 5, 6]
        colors = counts.enumerated().map { family, bins in
            var chosen: [Pixel] = []
            let ranked = bins.sorted {
                $0.value.weight == $1.value.weight ? $0.key < $1.key : $0.value.weight > $1.value.weight
            }
            for (_, bin) in ranked where chosen.count < limits[family] {
                let color = bin.color
                if !chosen.contains(where: { $0.distance(to: color) < 380 }) {
                    chosen.append(color)
                }
            }
            return chosen
        }
    }

    func nearest(to p: Pixel, preservingSmallColor: Bool = false) -> Pixel {
        let choices = colors[Self.family(p)]
        guard let closest = choices.min(by: { $0.distance(to: p) < $1.distance(to: p) }) else { return p }
        if preservingSmallColor && closest.distance(to: p) > 2700 { return p }
        return closest
    }

    private static func family(_ p: Pixel) -> Int {
        if p.chroma <= 24 { return 0 }
        if p.pink { return 1 }
        if p.b > p.g && Int(p.b) >= Int(p.r) - 12 { return 2 }
        return 3
    }
}
