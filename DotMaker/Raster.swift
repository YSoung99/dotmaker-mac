import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum DotError: LocalizedError {
    case read, render, subject, write, dimensions
    case segment(String)

    var errorDescription: String? {
        switch self {
        case .read: "이미지를 읽을 수 없습니다."
        case .render: "이미지를 처리할 수 없습니다."
        case .subject: "캐릭터를 분리하지 못했습니다. 캐릭터 주위에 여백이 있는 원본이나 투명 PNG를 열어 주세요."
        case .write: "PNG를 저장하지 못했습니다."
        case .dimensions: "가로와 세로를 각각 16~512px로 입력해 주세요."
        case .segment(let message): "배경 분리 AI를 실행하지 못했습니다: \(message)"
        }
    }
}

struct Pixel: Equatable, Sendable {
    var r, g, b, a: UInt8

    init(_ r: UInt8, _ g: UInt8, _ b: UInt8, _ a: UInt8 = 255) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    static let clear = Pixel(0, 0, 0, 0)
    static let black = Pixel(0, 0, 0)
    var light: Int { (54 * Int(r) + 183 * Int(g) + 19 * Int(b)) / 256 }
    var chroma: Int { Int(max(r, g, b)) - Int(min(r, g, b)) }
    var pink: Bool { r >= 135 && Int(r) - Int(g) >= 20 && Int(b) - Int(g) >= 7 && b <= r }
    var paper: Bool { light >= 205 && chroma <= 24 }

    func distance(to other: Pixel) -> Int {
        let dr = Int(r) - Int(other.r), dg = Int(g) - Int(other.g), db = Int(b) - Int(other.b)
        return dr * dr + dg * dg * 2 + db * db
    }

    func mixed(with color: Pixel, percent: Int) -> Pixel {
        func mix(_ base: UInt8, _ overlay: UInt8) -> UInt8 {
            UInt8((Int(base) * (100 - percent) + Int(overlay) * percent + 50) / 100)
        }
        return Pixel(mix(r, color.r), mix(g, color.g), mix(b, color.b))
    }
}

struct Grid: Sendable {
    let w, h: Int
    var count: Int { w * h }

    func each4(_ i: Int, _ visit: (Int) -> Void) {
        let x = i % w
        if x > 0 { visit(i - 1) }
        if x + 1 < w { visit(i + 1) }
        if i >= w { visit(i - w) }
        if i + w < count { visit(i + w) }
    }

    func each8(_ i: Int, _ visit: (Int) -> Void) {
        let x = i % w, y = i / w
        for v in max(0, y - 1)...min(h - 1, y + 1) {
            for u in max(0, x - 1)...min(w - 1, x + 1) where u != x || v != y {
                visit(v * w + u)
            }
        }
    }

    func edge(_ i: Int) -> Bool {
        i < w || i >= count - w || i % w == 0 || i % w == w - 1
    }

    func components(_ mask: [Bool], diagonal: Bool = true) -> [[Int]] {
        var seen = mask
        var result: [[Int]] = []
        for i in seen.indices where seen[i] {
            var component = [i]
            seen[i] = false
            var next = 0
            while next < component.count {
                func add(_ j: Int) {
                    if seen[j] { seen[j] = false; component.append(j) }
                }
                if diagonal { each8(component[next], add) } else { each4(component[next], add) }
                next += 1
            }
            result.append(component)
        }
        return result
    }
}

struct Raster: Sendable {
    let grid: Grid
    var pixels: [Pixel]
    private static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
        CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    )

    init(w: Int, h: Int) {
        grid = Grid(w: w, h: h)
        pixels = Array(repeating: .clear, count: grid.count)
    }

    init(_ image: CGImage, width: Int? = nil, height: Int? = nil) throws {
        let w = width ?? image.width, h = height ?? image.height
        self.init(w: w, h: h)
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                      bytesPerRow: w * 4, space: Self.colorSpace,
                                      bitmapInfo: Self.bitmapInfo.rawValue),
              let data = context.data?.assumingMemoryBound(to: UInt8.self)
        else { throw DotError.render }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        for i in pixels.indices {
            let offset = i * 4, a = Int(data[offset + 3])
            if a == 0 { continue }
            func straight(_ channel: Int) -> UInt8 {
                UInt8(min(255, (Int(data[offset + channel]) * 255 + a / 2) / a))
            }
            pixels[i] = Pixel(straight(0), straight(1), straight(2), UInt8(a))
        }
    }

    func image() throws -> CGImage {
        var bytes = [UInt8]()
        bytes.reserveCapacity(pixels.count * 4)
        for p in pixels {
            let a = Int(p.a)
            bytes.append(UInt8((Int(p.r) * a + 127) / 255))
            bytes.append(UInt8((Int(p.g) * a + 127) / 255))
            bytes.append(UInt8((Int(p.b) * a + 127) / 255))
            bytes.append(p.a)
        }
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: grid.w, height: grid.h, bitsPerComponent: 8,
                                  bitsPerPixel: 32, bytesPerRow: grid.w * 4,
                                  space: Self.colorSpace, bitmapInfo: Self.bitmapInfo,
                                  provider: provider, decode: nil, shouldInterpolate: false,
                                  intent: .defaultIntent)
        else { throw DotError.render }
        return image
    }

    /// 정수배 확대: 한 픽셀을 k×k 칸으로 그대로 늘린다(번짐 없음).
    func scaled(by k: Int) -> Raster {
        guard k > 1 else { return self }
        var output = Raster(w: grid.w * k, h: grid.h * k)
        for y in 0..<output.grid.h {
            for x in 0..<output.grid.w { output.pixels[y * output.grid.w + x] = pixels[(y / k) * grid.w + x / k] }
        }
        return output
    }

    func crop(x: Int, y: Int, w: Int, h: Int) -> Raster {
        var output = Raster(w: w, h: h)
        for v in 0..<h {
            let start = (v + y) * grid.w + x
            output.pixels.replaceSubrange(v * w..<(v + 1) * w, with: pixels[start..<(start + w)])
        }
        return output
    }

    static func load(_ url: URL, originalResolution: Bool = false) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw DotError.read }
        var maxSide = 2048
        if originalResolution {
            let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
            if let orientation = properties?[kCGImagePropertyOrientation] as? Int, orientation > 1,
               let width = properties?[kCGImagePropertyPixelWidth] as? Int,
               let height = properties?[kCGImagePropertyPixelHeight] as? Int {
                maxSide = max(width, height)
            } else {
                guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw DotError.read }
                return image
            }
        }
        let options = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide
        ] as CFDictionary
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else { throw DotError.read }
        return image
    }

    static func save(_ image: CGImage, to url: URL) throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw DotError.write }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw DotError.write }
        try (data as Data).write(to: url, options: .atomic)
    }
}
