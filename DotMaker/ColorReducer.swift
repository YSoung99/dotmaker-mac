import Foundation

enum ColorReducer {
    static func count(_ image: Raster) -> Int {
        Set(image.pixels.filter { $0.a > 0 }.map(key)).count
    }

    static func key(_ pixel: Pixel) -> Int {
        Int(pixel.r) << 16 | Int(pixel.g) << 8 | Int(pixel.b)
    }

    static func apply(_ source: Raster, outline: [Bool], boundary: [Bool], settings: DotSettings,
                      preserving protected: [Bool]? = nil) throws -> Raster {
        let limit = max(6, min(32, settings.colors))
        var image = source
        let visible = image.pixels.indices.filter { image.pixels[$0].a > 0 && protected?[$0] != true }
        guard !visible.isEmpty else { return image }
        var histogram: [Int: Int] = [:]
        for i in visible where !outline[i] && !boundary[i] {
            histogram[key(image.pixels[i]), default: 0] += 1
        }
        let samples = histogram.sorted { $0.key < $1.key }.map { entry in
            (color: Pixel(UInt8(entry.key >> 16), UInt8((entry.key >> 8) & 255), UInt8(entry.key & 255)),
             weight: entry.value)
        }
        let paper = samples.filter { $0.color.paper }.max {
            $0.weight == $1.weight ? $0.color.light < $1.color.light : $0.weight < $1.weight
        }?.color
        var palette: [Pixel] = [.black]
        if let paper { palette.append(paper) }
        let hasRim = settings.boundary && visible.contains { boundary[$0] }
        var rim: Pixel?
        if hasRim, let paper {
            let middle = paper.mixed(with: .black, percent: 50)
            let color = paper.mixed(with: middle, percent: 100 - settings.transparency)
            rim = color
            if !palette.contains(color) { palette.append(color) }
        }
        let rimIndex = rim.flatMap { color in palette.firstIndex(of: color) }
        let interiorPalette = palette.enumerated().filter { index, color in
            index != rimIndex || color == paper || color == .black
        }.map(\.element)
        let fixedCount = palette.count
        // Seed each material so a small purple ribbon can compete with a large pink head.
        for family in 1...3 where palette.count < limit {
            if let sample = samples.filter({ category($0.color) == family }).max(by: { $0.weight < $1.weight }),
               !palette.contains(sample.color) {
                palette.append(sample.color)
            }
        }
        while palette.count < limit {
            let next = samples.max { a, b in
                importance(a.color, weight: a.weight, palette: palette) <
                importance(b.color, weight: b.weight, palette: palette)
            }
            guard let next, !palette.contains(next.color) else { break }
            palette.append(next.color)
        }
        // Weighted medoids keep representative colors from the actual image.
        let interiorIndices = palette.indices.filter { $0 != rimIndex || palette[$0] == paper || palette[$0] == .black }
        for _ in 0..<5 {
            try Task.checkCancellation()
            let allowed = interiorIndices.map { palette[$0] }
            var groups = Array(repeating: [Int](), count: palette.count)
            for i in samples.indices {
                groups[interiorIndices[nearest(samples[i].color, palette: allowed)]].append(i)
            }
            var changed = false
            for group in fixedCount..<palette.count where !groups[group].isEmpty {
                var r = 0, g = 0, b = 0, weight = 0
                for i in groups[group] {
                    let item = samples[i]
                    r += Int(item.color.r) * item.weight
                    g += Int(item.color.g) * item.weight
                    b += Int(item.color.b) * item.weight
                    weight += item.weight
                }
                let mean = Pixel(UInt8(r / weight), UInt8(g / weight), UInt8(b / weight))
                let best = groups[group].min { samples[$0].color.distance(to: mean) < samples[$1].color.distance(to: mean) }!
                let color = samples[best].color
                changed = changed || color != palette[group]
                palette[group] = color
            }
            if !changed { break }
        }
        let fillPalette = interiorPalette + Array(palette.dropFirst(fixedCount))
        var mapping: [Int: Pixel] = [:]
        for sample in samples {
            // Pale neutral antialiasing inside the white material belongs to the white fill.
            // The independently reserved rim tone is used only by the boundary mask.
            let color = sample.color
            if let paper, color.light >= 195 && color.chroma <= 24 {
                mapping[key(color)] = paper
            } else {
                mapping[key(color)] = fillPalette[nearest(color, palette: fillPalette)]
            }
        }
        for i in visible {
            let old = image.pixels[i]
            var color: Pixel
            if outline[i] { color = .black }
            else if boundary[i], let rim { color = rim }
            else { color = mapping[key(old)] ?? fillPalette[nearest(old, palette: fillPalette)] }
            color.a = old.a
            image.pixels[i] = color
        }
        guard settings.cleanup > 0 else { return image }
        let mapped = image.pixels
        let tolerance = settings.cleanup == 1 ? 1600 : 3600
        for i in visible where !outline[i] && !boundary[i] && mapped[i].light > 110 {
            var neighbors: [Int: Int] = [:]
            image.grid.each8(i) { j in
                let p = mapped[j]
                if p.a > 0 && protected?[j] != true && !outline[j] && !boundary[j] && category(p) == category(mapped[i]) {
                    neighbors[key(p), default: 0] += 1
                }
            }
            let own = neighbors[key(mapped[i]), default: 0]
            guard own <= settings.cleanup,
                  let majority = neighbors.sorted(by: { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }).first,
                  majority.value >= 5,
                  let color = palette.first(where: { key($0) == majority.key }),
                  color.distance(to: mapped[i]) <= tolerance
            else { continue }
            image.pixels[i] = Pixel(color.r, color.g, color.b, mapped[i].a)
        }
        return image
    }

    private static func nearest(_ color: Pixel, palette: [Pixel]) -> Int {
        let family = category(color)
        let sameMaterial = palette.indices.filter { category(palette[$0]) == family && palette[$0].light > 105 }
        let choices = color.light > 110 && !sameMaterial.isEmpty
            ? sameMaterial + palette.indices.filter { palette[$0] == .black } : Array(palette.indices)
        return choices.min { color.distance(to: palette[$0]) < color.distance(to: palette[$1]) }!
    }

    private static func importance(_ color: Pixel, weight: Int, palette: [Pixel]) -> Double {
        Double(color.distance(to: palette[nearest(color, palette: palette)])) * sqrt(Double(weight))
    }

    private static func category(_ color: Pixel) -> Int {
        if color.chroma <= 12 || color.paper { return 0 }
        if color.pink { return 1 }
        if color.b > color.g && Int(color.b) >= Int(color.r) - 12 { return 2 }
        return 3
    }
}
