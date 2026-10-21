import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Caption and keyword suggestions from a vision model. Four providers: Ollama on this
/// Mac (nothing leaves the machine), or Anthropic, xAI Grok and Google Gemini over HTTPS
/// with the user's own API key. Cloud keys live in the Keychain, never in settings.json.
enum AIProvider: String, CaseIterable, Codable, Identifiable {
    case ollama, anthropic, grok, gemini
    var id: String { rawValue }
    var label: String {
        switch self { case .ollama: return "Ollama (local)"; case .anthropic: return "Anthropic Claude"; case .grok: return "xAI Grok"; case .gemini: return "Google Gemini" }
    }
    var isCloud: Bool { self != .ollama }
    var defaultModel: String {
        switch self { case .ollama: return "qwen3.8:27b-q8_0"; case .anthropic: return "claude-opus-5-5"; case .grok: return "grok-4"; case .gemini: return "gemini-2.5-flash" }
    }
    var keyHelp: String {
        switch self {
        case .ollama: return "No key. Install Ollama and pull a vision model."
        case .anthropic: return "Create a key at console.anthropic.com → API keys."
        case .grok: return "Create a key at console.x.ai."
        case .gemini: return "Create a key at aistudio.google.com → Get API key."
        }
    }
}

enum CaptionAI {
    struct Suggestion: Decodable { var caption: String; var keywords: [String] }

    static let keychainService = "Darkslide.ai"

    static func setKey(_ key: String, for p: AIProvider) {
        let del = Process(); del.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        del.arguments = ["delete-generic-password", "-s", keychainService, "-a", p.rawValue]
        del.standardError = FileHandle.nullDevice; del.standardOutput = FileHandle.nullDevice
        try? del.run(); del.waitUntilExit()
        guard !key.isEmpty else { return }
        let add = Process(); add.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        add.arguments = ["add-generic-password", "-s", keychainService, "-a", p.rawValue, "-w", key, "-U"]
        add.standardError = FileHandle.nullDevice; add.standardOutput = FileHandle.nullDevice
        try? add.run(); add.waitUntilExit()
    }

    static func key(for p: AIProvider) -> String? {
        let f = Process(); f.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        f.arguments = ["find-generic-password", "-s", keychainService, "-a", p.rawValue, "-w"]
        let out = Pipe(); f.standardOutput = out; f.standardError = FileHandle.nullDevice
        try? f.run(); f.waitUntilExit()
        guard f.terminationStatus == 0 else { return nil }
        let k = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return k.isEmpty ? nil : k
    }

    static func hasKey(_ p: AIProvider) -> Bool { !p.isCloud || key(for: p) != nil }

    static let prompt = """
    You caption news and documentary photographs for a photographer's archive.
    Reply with JSON only, no prose, no code fence: {"caption": "<one or two factual sentences, present tense, no guesses about names>", "keywords": ["<8 to 15 lowercase keywords: subjects, actions, setting, lighting, objects>"]}
    """

    static func err(_ msg: String) -> NSError { NSError(domain: "darkslide.ai", code: 1, userInfo: [NSLocalizedDescriptionKey: msg]) }

    /// Suggest for one image. `context` is what the photo already says (event, place).
    static func suggest(provider: AIProvider, model: String, ollamaURL: String, image url: URL, context: String,
                        completion: @escaping (Result<Suggestion, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let jpeg = jpegData(for: url) else { DispatchQueue.main.async { completion(.failure(err("could not decode image"))) }; return }
            let b64 = jpeg.base64EncodedString()
            let text = prompt + (context.isEmpty ? "" : "\nKnown context: \(context)")
            let result: Result<Suggestion, Error>
            do {
                let req: URLRequest
                switch provider {
                case .ollama: req = try ollamaRequest(base: ollamaURL, model: model, b64: b64, text: text)
                case .anthropic: req = try anthropicRequest(model: model, b64: b64, text: text)
                case .grok: req = try grokRequest(model: model, b64: b64, text: text)
                case .gemini: req = try geminiRequest(model: model, b64: b64, text: text)
                }
                let (data, status) = try send(req)
                let reply = try extractText(provider: provider, data: data, status: status)
                result = .success(try parseSuggestion(reply))
            } catch { result = .failure(error) }
            DispatchQueue.main.async { completion(result) }
        }
    }

    // MARK: Requests

    static func ollamaRequest(base: String, model: String, b64: String, text: String) throws -> URLRequest {
        let b = base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let u = URL(string: b + "/api/generate") else { throw err("Ollama URL is not valid") }
        let body: [String: Any] = ["model": model, "prompt": text, "images": [b64], "stream": false, "format": "json", "think": false,
                                   "options": ["temperature": 0.3, "num_predict": 400]]
        return try json(u, body: body, headers: [:], timeout: 180)
    }

    static func anthropicRequest(model: String, b64: String, text: String) throws -> URLRequest {
        guard let key = key(for: .anthropic) else { throw err("No Anthropic API key. Add one in Preferences › AI.") }
        let body: [String: Any] = [
            "model": model, "max_tokens": 1024,
            "fallbacks": "default",
            "messages": [["role": "user", "content": [
                ["type": "image", "source": ["type": "base64", "media_type": "image/jpeg", "data": b64]],
                ["type": "text", "text": text]]]],
        ]
        return try json(URL(string: "https://api.anthropic.com/v1/messages")!, body: body,
                        headers: ["x-api-key": key, "anthropic-version": "2023-06-01", "anthropic-beta": "server-side-fallback-2026-07-01"], timeout: 120)
    }

    static func grokRequest(model: String, b64: String, text: String) throws -> URLRequest {
        guard let key = key(for: .grok) else { throw err("No xAI API key. Add one in Preferences › AI.") }
        let body: [String: Any] = [
            "model": model, "max_tokens": 1024, "temperature": 0.3,
            "messages": [["role": "user", "content": [
                ["type": "image_url", "image_url": ["url": "data:image/jpeg;base64," + b64, "detail": "high"]],
                ["type": "text", "text": text]]]],
        ]
        return try json(URL(string: "https://api.x.ai/v1/chat/completions")!, body: body, headers: ["Authorization": "Bearer " + key], timeout: 120)
    }

    static func geminiRequest(model: String, b64: String, text: String) throws -> URLRequest {
        guard let key = key(for: .gemini) else { throw err("No Gemini API key. Add one in Preferences › AI.") }
        let body: [String: Any] = [
            "contents": [["parts": [["inline_data": ["mime_type": "image/jpeg", "data": b64]], ["text": text]]]],
            "generationConfig": ["temperature": 0.3, "maxOutputTokens": 1024, "responseMimeType": "application/json"],
        ]
        let u = URL(string: "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent")!
        return try json(u, body: body, headers: ["x-goog-api-key": key], timeout: 120)
    }

    // MARK: Responses

    static func extractText(provider: AIProvider, data: Data, status: Int) throws -> String {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw err("HTTP \(status): unreadable response") }
        if let e = obj["error"] as? [String: Any], let m = (e["message"] as? String) ?? (e["type"] as? String) { throw err("HTTP \(status): \(m)") }
        if status >= 400 { throw err("HTTP \(status)") }
        switch provider {
        case .ollama:
            guard let t = obj["response"] as? String else { throw err("Ollama returned no response") }
            return t
        case .anthropic:
            if obj["stop_reason"] as? String == "refusal" { throw err("The model declined this image") }
            let blocks = obj["content"] as? [[String: Any]] ?? []
            let t = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }.joined()
            guard !t.isEmpty else { throw err("Anthropic returned no text") }
            return t
        case .grok:
            guard let c = (obj["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any], let t = c["content"] as? String else { throw err("Grok returned no text") }
            return t
        case .gemini:
            guard let cand = (obj["candidates"] as? [[String: Any]])?.first, let content = cand["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else { throw err("Gemini returned no text") }
            return parts.compactMap { $0["text"] as? String }.joined()
        }
    }

    /// Models return JSON, sometimes wrapped in a code fence or with prose around it.
    static func parseSuggestion(_ text: String) throws -> Suggestion {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let a = s.firstIndex(of: "{"), let b = s.lastIndex(of: "}") { s = String(s[a...b]) }
        guard let d = s.data(using: .utf8), let sug = try? JSONDecoder().decode(Suggestion.self, from: d) else {
            throw err("model did not return JSON: \(text.prefix(160))")
        }
        return sug
    }

    // MARK: Helpers

    static func jpegData(for url: URL) -> Data? {
        guard let cg = ImageLoader.embeddedPreview(for: url, maxPixel: 1024) ?? ImageLoader.decoded(for: url, maxPixel: 1024) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? data as Data : nil
    }

    static func json(_ url: URL, body: [String: Any], headers: [String: String], timeout: TimeInterval) throws -> URLRequest {
        var r = URLRequest(url: url); r.httpMethod = "POST"; r.timeoutInterval = timeout
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        r.httpBody = try JSONSerialization.data(withJSONObject: body)
        return r
    }

    static func send(_ req: URLRequest) throws -> (Data, Int) {
        let sem = DispatchSemaphore(value: 0)
        var out: (Data, Int)?; var failure: Error?
        URLSession.shared.dataTask(with: req) { d, resp, e in
            if let e { failure = e } else { out = (d ?? Data(), (resp as? HTTPURLResponse)?.statusCode ?? 0) }
            sem.signal()
        }.resume()
        sem.wait()
        if let failure { throw failure }
        return out ?? (Data(), 0)
    }

    /// List the models an Ollama server has, so Preferences can show the user what is there.
    static func ollamaModels(base: String, completion: @escaping (Result<[String], Error>) -> Void) {
        let b = base.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let u = URL(string: b + "/api/tags") else { completion(.failure(err("Ollama URL is not valid"))); return }
        var r = URLRequest(url: u); r.timeoutInterval = 5
        URLSession.shared.dataTask(with: r) { d, _, e in
            DispatchQueue.main.async {
                if let e { completion(.failure(e)); return }
                guard let d, let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let models = obj["models"] as? [[String: Any]] else { completion(.failure(err("not an Ollama server"))); return }
                completion(.success(models.compactMap { $0["name"] as? String }.sorted()))
            }
        }.resume()
    }
}
