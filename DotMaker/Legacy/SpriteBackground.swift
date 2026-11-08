import CoreGraphics

extension PixelConverter {
    // Remove only light, near-neutral regions reachable from the image border.
    // Closed white shapes inside the artwork are kept as part of the sprite.
    static func withoutLightBackground(_ source: SourceImage) throws -> SourceImage {
        let image = source.image
        let scale = min(1, 1024.0 / Double(max(image.width, image.height)))
        let w = max(1, Int((Double(image.width) * scale).rounded()))
        let h = max(1, Int((Double(image.height) * scale).rounded()))
        let context = try rasterize(image, width: w, height: h, rect: CGRect(x: 0, y: 0, width: w, height: h))
        guard w > 2, h > 2, let data = context.data else { return source }
        let bytes = data.assumingMemoryBound(to: UInt8.self)
        let count = w * h
        var state = [UInt8](repeating: 0, count: count)
        var hasAlpha = false
        var lightBorder = 0
        let borderCount = 2 * w + 2 * h - 4
        for y in 0..<h {
            try Task.checkCancellation()
            for x in 0..<w {
                let i = y * w + x
                let p = bytes.advanced(by: 4 * i)
                if p[3] < 250 { hasAlpha = true }
                let low = min(p[0], p[1], p[2])
                let high = max(p[0], p[1], p[2])
                if low >= 207 && high - low <= 30 {
                    state[i] = 1
                    if x == 0 || x == w - 1 || y == 0 || y == h - 1 { lightBorder += 1 }
                }
            }
        }
        guard !hasAlpha, lightBorder * 4 >= borderCount * 3 else { return source }

        var queue: [Int] = []
        func addBackground(_ i: Int) {
            guard state[i] == 1 else { return }
            state[i] = 2
            queue.append(i)
        }
        for x in 0..<w { addBackground(x); addBackground((h - 1) * w + x) }
        for y in 1..<(h - 1) { addBackground(y * w); addBackground(y * w + w - 1) }
        var head = 0
        while head < queue.count {
            if head % 4096 == 0 { try Task.checkCancellation() }
            let i = queue[head]
            let x = i % w
            if x > 0 { addBackground(i - 1) }
            if x + 1 < w { addBackground(i + 1) }
            if i >= w { addBackground(i - w) }
            if i + w < count { addBackground(i + w) }
            head += 1
        }
        guard queue.count > count / 12 else { return source }
        queue.removeAll(keepingCapacity: true)

        // Tiny disconnected marks, such as editing handles, should not determine the crop.
        var components: [[Int]] = []
        for i in 0..<count where state[i] < 2 {
            if i % 4096 == 0 { try Task.checkCancellation() }
            state[i] = 3
            queue.append(i)
            head = 0
            while head < queue.count {
                if head % 4096 == 0 { try Task.checkCancellation() }
                let p = queue[head]
                let x = p % w
                let y = p / w
                for v in max(0, y - 1)...min(h - 1, y + 1) {
                    for u in max(0, x - 1)...min(w - 1, x + 1) {
                        let n = v * w + u
                        if state[n] < 2 {
                            state[n] = 3
                            queue.append(n)
                        }
                    }
                }
                head += 1
            }
            if queue.count >= 4 { components.append(queue) }
            queue.removeAll(keepingCapacity: true)
        }
        let largest = components.map(\.count).max() ?? 0
        guard largest >= max(4, count / 100) else { return source }
        var minX = w, minY = h, maxX = 0, maxY = 0
        for component in components where component.count >= max(4, largest / 28) {
            for i in component {
                state[i] = 4
                minX = min(minX, i % w); maxX = max(maxX, i % w)
                minY = min(minY, i / w); maxY = max(maxY, i / w)
            }
        }
        let pad = max(1, Int((0.04 * Double(max(maxX - minX + 1, maxY - minY + 1))).rounded()))
        minX = max(0, minX - pad); maxX = min(w - 1, maxX + pad)
        minY = max(0, minY - pad); maxY = min(h - 1, maxY + pad)
        for i in 0..<count where state[i] != 4 {
            bytes.advanced(by: 4 * i).initialize(repeating: 0, count: 4)
        }
        let rect = CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
        guard let prepared = context.makeImage()?.cropping(to: rect) else { throw ConversionError.cannotRender }
        return SourceImage(name: source.name, size: PixelSize(width: prepared.width, height: prepared.height), image: prepared)
    }
}
