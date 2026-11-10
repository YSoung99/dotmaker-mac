import CoreGraphics
import Foundation
import ImageIO
import Security
import UniformTypeIdentifiers

/// 클라우드 AI 보정: 사용자가 넣은 자기 API 키로 각 서비스에 그림을 보내 'AI 그림'을 받는다(윈도우판 cloud.js와 같음).
/// 키는 맥 키체인에만 두고 파일·코드에 남기지 않는다. 보내기 전에 받는 곳과 대략의 요금을 묻는다.
enum CloudProvider: String, CaseIterable, Identifiable, Sendable {
    case pixellab, gemini, openai

    var id: Self { self }
    var name: String { switch self { case .pixellab: "PixelLab"; case .gemini: "Gemini"; case .openai: "OpenAI" } }
    var detail: String {
        switch self {
        case .pixellab: "도트 전용 · 결과가 바로 도트 그림"
        case .gemini: "나노 바나나 2.1 · 도트 느낌 그림 → 도트화"
        case .openai: "GPT Image 2.5 · 도트 느낌 그림 → 도트화"
        }
    }
    var host: String {
        switch self {
        case .pixellab: "api.pixellab.ai"
        case .gemini: "generativelanguage.googleapis.com"
        case .openai: "api.openai.com"
        }
    }
    var price: String { switch self { case .pixellab: "약 $0.01"; case .gemini: "약 $0.034"; case .openai: "약 $0.01~0.05" } }
    var keyPage: URL {
        switch self {
        case .pixellab: URL(string: "https://www.pixellab.ai/")!
        case .gemini: URL(string: "https://aistudio.google.com/apikey")!
        case .openai: URL(string: "https://platform.openai.com/api-keys")!
        }
    }
    var keyHint: String {
        switch self {
        case .pixellab: "PixelLab 계정의 API 토큰"
        case .gemini: "Google AI Studio의 API 키"
        case .openai: "OpenAI 플랫폼의 API 키(sk-…)"
        }
    }
}

struct CloudOptions: Sendable {
    var faithful = true
    var strength = 300
    var quality = "medium"
}

struct CloudError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum CloudKey {
    private static func query(_ provider: CloudProvider) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "local.dotmaker.cloud",
         kSecAttrAccount as String: provider.rawValue]
    }

    static func load(_ provider: CloudProvider) -> String? {
        var query = query(provider)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess, let data = result as? Data,
              let key = String(data: data, encoding: .utf8), !key.isEmpty else { return nil }
        return key
    }

    static func save(_ provider: CloudProvider, _ input: String) throws {
        let key = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        let value = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query(provider) as CFDictionary, value as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(provider)
            item[kSecValueData as String] = Data(key.utf8)
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw JevError.storage }
        } else if status != errSecSuccess { throw JevError.storage }
    }

    static func clear(_ provider: CloudProvider) { SecItemDelete(query(provider) as CFDictionary) }
}

enum Cloud {
    static let prompt = "Redraw this exact character as a clean pixel art sprite. Keep the same pose, face, expression, proportions and colors. "
        + "Crisp 1-pixel dark outlines, flat colors with a small palette, no anti-aliasing, no blur, plain white background, nothing else in the image."

    /// 그림을 흰 바탕 PNG로. width×height 칸에 비율 유지해 가운데 둔다(92% 크기).
    static func whitePNG(_ image: CGImage, width: Int, height: Int) throws -> Data {
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw DotError.render }
        context.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let scale = min(Double(width) / Double(image.width), Double(height) / Double(image.height)) * 0.92
        let dw = Int((Double(image.width) * scale).rounded()), dh = Int((Double(image.height) * scale).rounded())
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: Int((Double(width - dw) / 2).rounded()), y: Int((Double(height - dh) / 2).rounded()),
                                       width: dw, height: dh))
        guard let output = context.makeImage() else { throw DotError.render }
        return try png(output)
    }

    static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            throw DotError.render
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw DotError.render }
        return data as Data
    }

    static func image(base64: String) throws -> CGImage {
        guard let data = Data(base64Encoded: base64), let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw CloudError(message: "받은 그림을 열지 못했습니다.") }
        return image
    }

    private static func send(_ service: String, _ request: URLRequest) async throws -> (Data, Int) {
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CloudError(message: "\(service): 서버에 연결하지 못했습니다. 인터넷 연결을 확인해 주세요.")
        }
    }

    private static func failure(_ service: String, _ data: Data, _ status: Int) -> CloudError {
        var detail = ""
        if let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            detail = ((body["error"] as? [String: Any])?["message"] as? String)
                ?? (body["detail"].map { "\($0)" }) ?? (body["message"] as? String) ?? ""
        }
        let reasons = [400: "요청을 받아 주지 않았습니다", 401: "API 키가 맞지 않습니다", 402: "잔액·크레딧이 부족합니다",
                       403: "이 키로는 쓸 수 없습니다(권한·결제 설정 확인)", 404: "모델이나 주소를 찾지 못했습니다",
                       429: "요청이 너무 많거나 사용 한도를 넘었습니다"]
        let reason = reasons[status] ?? "서버 오류가 났습니다"
        return CloudError(message: "\(service): \(reason) (HTTP \(status))" + (detail.isEmpty ? "" : " — " + String(detail.prefix(200))))
    }

    /// 응답 JSON 어디에 있든 base64 그림 하나를 찾는다(서비스마다 모양이 달라서).
    static func findImage(_ node: Any?) -> String? {
        if let object = node as? [String: Any] {
            if let inline = (object["inline_data"] ?? object["inlineData"]) as? [String: Any], let data = inline["data"] as? String {
                return data
            }
            if object["type"] as? String == "image", let data = object["data"] as? String { return data }
            if let data = object["b64_json"] as? String { return data }
            for value in object.values { if let found = findImage(value) { return found } }
        } else if let array = node as? [Any] {
            for value in array { if let found = findImage(value) { return found } }
        }
        return nil
    }

    private static func json(_ url: String, key: (String, String), body: [String: Any]) throws -> URLRequest {
        var request = URLRequest(url: URL(string: url)!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(key.1, forHTTPHeaderField: key.0)
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    /// PixelLab 다듬기(correct-pixelart): 도트 그림을 크기 그대로 보내 잔점·계단 가장자리·색을 정리받는다. 투명은 유지된다.
    static func correct(key: String, picture: CGImage, strength: Double) async throws -> (image: CGImage, cost: Double?) {
        let request = try json("https://api.pixellab.ai/v2/correct-pixelart", key: ("authorization", "Bearer \(key)"), body: [
            "images": [["type": "base64", "base64": try png(picture).base64EncodedString(), "format": "png"]],
            "strength": strength,
        ])
        let (data, status) = try await send("PixelLab", request)
        guard status == 200 else { throw failure("PixelLab", data, status) }
        let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        let b64 = ((body?["images"] as? [[String: Any]])?.first?["base64"] as? String) ?? findImage(body)
        guard let b64 else { throw CloudError(message: "PixelLab: 응답에 그림이 없습니다.") }
        return (try image(base64: b64), (body?["usage"] as? [String: Any])?["usd"] as? Double)
    }

    /// 캐릭터 그림을 보내 AI 그림을 받는다. pixel: 이미 도트 그림인지(PixelLab).
    static func paint(_ provider: CloudProvider, key: String, subject: CGImage, size: (w: Int, h: Int),
                      options: CloudOptions) async throws -> (image: CGImage, pixel: Bool, cost: Double?) {
        if provider == .pixellab {
            // 입력은 출력의 약 4배가 좋다(PixelLab 안내). 한 변 2048px까지.
            let k = max(1, min(4, 2048 / max(size.w, size.h)))
            let input = try whitePNG(subject, width: size.w * k, height: size.h * k)
            let request = try json("https://api.pixellab.ai/v2/image-to-pixelart", key: ("authorization", "Bearer \(key)"), body: [
                "image": ["type": "base64", "base64": input.base64EncodedString(), "format": "png"],
                "image_size": ["width": size.w * k, "height": size.h * k],
                "output_size": ["width": size.w, "height": size.h],
                "text_guidance_scale": 8,
                "init_image_strength": options.strength,
                "fixer": options.faithful,
                "seed": 7,
            ])
            let (data, status) = try await send("PixelLab", request)
            guard status == 200 else { throw failure("PixelLab", data, status) }
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            let b64 = ((body?["image"] as? [String: Any])?["base64"] as? String) ?? findImage(body)
            guard let b64 else { throw CloudError(message: "PixelLab: 응답에 그림이 없습니다.") }
            return (try image(base64: b64), true, (body?["usage"] as? [String: Any])?["usd"] as? Double)
        }
        let input = try whitePNG(subject, width: 1024, height: 1024)
        if provider == .gemini {
            let base = "https://generativelanguage.googleapis.com/v1beta", header = ("x-goog-api-key", key)
            var (data, status) = try await send("Gemini", try json("\(base)/interactions", key: header, body: [
                "model": "gemini-nano-banana-2.1",
                "input": [["type": "text", "text": prompt], ["type": "image", "mime_type": "image/png", "data": input.base64EncodedString()]],
                "response_format": ["type": "image", "mime_type": "image/png", "aspect_ratio": "1:1", "image_size": "1K"],
            ]))
            // 새 방식(interactions)을 못 쓰는 키·지역이면 예전 방식(generateContent)으로 한 번 더
            if status == 400 || status == 404 {
                (data, status) = try await send("Gemini", try json("\(base)/models/gemini-nano-banana-2.1:generateContent", key: header, body: [
                    "contents": [["parts": [["text": prompt], ["inline_data": ["mime_type": "image/png", "data": input.base64EncodedString()]]]]],
                    "generationConfig": ["responseModalities": ["IMAGE"], "imageConfig": ["aspectRatio": "1:1", "imageSize": "1K"]],
                ]))
            }
            guard status == 200 else { throw failure("Gemini", data, status) }
            guard let b64 = findImage(try? JSONSerialization.jsonObject(with: data)) else {
                throw CloudError(message: "Gemini: 응답에 그림이 없습니다(안전 필터에 걸렸을 수 있어요).")
            }
            return (try image(base64: b64), false, nil)
        }
        let boundary = "dotmaker-\(UUID().uuidString)"
        var form = Data()
        func field(_ name: String, _ value: String) {
            form.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", "gpt-image-2.5-sunburst")
        form.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"image\"; filename=\"input.png\"\r\nContent-Type: image/png\r\n\r\n".utf8))
        form.append(input)
        form.append(Data("\r\n".utf8))
        field("prompt", prompt)
        field("size", "1024x1024")
        field("quality", options.quality)
        field("output_format", "png")
        form.append(Data("--\(boundary)--\r\n".utf8))
        var request = URLRequest(url: URL(string: "https://api.openai.com/v1/images/edits")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 180
        request.setValue("Bearer \(key)", forHTTPHeaderField: "authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "content-type")
        request.httpBody = form
        let (data, status) = try await send("OpenAI", request)
        guard status == 200 else { throw failure("OpenAI", data, status) }
        guard let b64 = findImage(try? JSONSerialization.jsonObject(with: data)) else {
            throw CloudError(message: "OpenAI: 응답에 그림이 없습니다.")
        }
        return (try image(base64: b64), false, nil)
    }
}
