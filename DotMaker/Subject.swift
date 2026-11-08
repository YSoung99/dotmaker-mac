import CoreGraphics

enum Subject {
    static func extract(_ source: CGImage, preserveTransparentArt: Bool = false) throws -> Raster {
        try Task.checkCancellation()
        var raster = try Raster(source)
        let grid = raster.grid
        let hasBackgroundAlpha = raster.pixels.indices.contains {
            grid.edge($0) && raster.pixels[$0].a < 32
        }
        // Existing transparency already identifies the artwork, including detached accents.
        if preserveTransparentArt && hasBackgroundAlpha {
            // Some transparent exports leave alpha 1 across the whole background.
            // Drop that nearly invisible floor before fitting the artwork.
            for i in raster.pixels.indices where raster.pixels[i].a == 1 {
                raster.pixels[i] = .clear
            }
            return try cropVisible(raster)
        }
        let removedPaleBackdrop = try removePaleBackdrop(&raster)
        if !removedPaleBackdrop && !hasBackgroundAlpha {
            raster = try AnimeSeg.subject(source)
        }

        try Task.checkCancellation()
        let components = grid.components(raster.pixels.map { $0.a >= 48 })
        guard let main = components.max(by: { $0.count < $1.count }), main.count >= 4 else {
            throw DotError.subject
        }

        // Keep the main character, including enclosed white areas and attached accessories.
        // Keep the original antialiasing at its perimeter but drop unrelated islands.
        var keep = [Bool](repeating: false, count: grid.count)
        for i in main {
            keep[i] = true
            grid.each8(i) { j in
                if raster.pixels[j].a < 48 { keep[j] = true }
            }
        }
        for i in keep.indices where !keep[i] { raster.pixels[i] = .clear }
        return try cropVisible(raster)
    }

    private static func cropVisible(_ raster: Raster) throws -> Raster {
        let grid = raster.grid
        var left = grid.w, top = grid.h, right = -1, bottom = -1
        for y in 0..<grid.h {
            try Task.checkCancellation()
            for x in 0..<grid.w where raster.pixels[y * grid.w + x].a > 0 {
                left = min(left, x); right = max(right, x)
                top = min(top, y); bottom = max(bottom, y)
            }
        }
        guard right >= left else { throw DotError.subject }
        return raster.crop(x: left, y: top, w: right - left + 1, h: bottom - top + 1)
    }

    private static func removePaleBackdrop(_ raster: inout Raster) throws -> Bool {
        let grid = raster.grid
        // Flood only near-neutral, light pixels connected to a border. This protects white
        // fills inside the drawn contour and handles a pale canvas inside a screenshot.
        let pale = raster.pixels.map { $0.light >= 185 && $0.chroma <= 34 }
        let edges = (0..<grid.count).filter(grid.edge)
        var queue = edges.filter { pale[$0] }
        guard queue.count * 5 >= edges.count * 4 else { return false }
        var background = [Bool](repeating: false, count: grid.count)
        for i in queue { background[i] = true }
        var next = 0
        while next < queue.count {
            if next.isMultiple(of: 4096) { try Task.checkCancellation() }
            grid.each4(queue[next]) { j in
                if pale[j] && !background[j] { background[j] = true; queue.append(j) }
            }
            next += 1
        }
        guard queue.count > grid.count / 12 else { return false }
        // A white matte is already baked into the remaining antialiased perimeter.
        // Bring the light fringe toward the darker contour next to it.
        let original = raster.pixels
        for i in raster.pixels.indices {
            if i.isMultiple(of: 4096) { try Task.checkCancellation() }
            if background[i] {
                raster.pixels[i] = .clear
            } else if original[i].light > 95 && original[i].chroma < 40 {
                var touchesBackdrop = false
                var darkest = original[i]
                grid.each8(i) { j in
                    if background[j] { touchesBackdrop = true }
                    else if original[j].light < darkest.light { darkest = original[j] }
                }
                if touchesBackdrop && darkest.light < 65 {
                    raster.pixels[i] = original[i].mixed(with: darkest, percent: 65)
                }
            }
        }
        return true
    }
}
