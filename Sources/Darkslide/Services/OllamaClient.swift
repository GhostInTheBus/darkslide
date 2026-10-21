import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Local LLM through Ollama's /api/generate with a vision model. Suggestions only: the
/// caption panel shows them for review, nothing is written until the user saves.
struct OllamaClient {
    var baseURL: String
    var model: String

    struct Suggestion: Decodable { var caption: String; var keywords: [String] }

    func suggest(for url: URL, context: String, completion: @escaping (Result<Suggestion, Error>) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                guard let cg = ImageLoader.embeddedPreview(for: url, maxPixel: 1024) ?? ImageLoader.decoded(for: url, maxPixel: 1024) else {
                    throw NSError(domain: "darkslide", code: 1, userInfo: [NSLocalizedDescriptionKey: "could not decode image"])
                }
                let data = NSMutableData()
                guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw NSError(domain: "darkslide", code: 2) }
                CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
                CGImageDestinationFinalize(dest)
                let prompt = """
                You caption news and documentary photographs for a photographer's archive.
                \(context.isEmpty ? "" : "Known context: \(context)")
                Reply with JSON only: {"caption": "<one or two factual sentences, present tense, no speculation about names>", "keywords": ["<8 to 15 lowercase keywords: subjects, actions, setting, lighting, objects>"]}
                """
                let body: [String: Any] = ["model": model, "prompt": prompt, "images": [(data as Data).base64EncodedString()],
                                           "stream": false, "format": "json", "think": false,
                                           "options": ["temperature": 0.3, "num_predict": 400]]
                var req = URLRequest(url: URL(string: baseURL + "/api/generate")!)
                req.httpMethod = "POST"
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                req.httpBody = try JSONSerialization.data(withJSONObject: body)
                req.timeoutInterval = 180
                let sem = DispatchSemaphore(value: 0)
                var result: Result<Suggestion, Error> = .failure(NSError(domain: "darkslide", code: 3, userInfo: [NSLocalizedDescriptionKey: "no response"]))
                URLSession.shared.dataTask(with: req) { d, _, e in
                    defer { sem.signal() }
                    if let e { result = .failure(e); return }
                    guard let d, let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
                          let text = obj["response"] as? String, let td = text.data(using: .utf8) else {
                        result = .failure(NSError(domain: "darkslide", code: 4, userInfo: [NSLocalizedDescriptionKey: "bad response"])); return
                    }
                    do { result = .success(try JSONDecoder().decode(Suggestion.self, from: td)) }
                    catch { result = .failure(NSError(domain: "darkslide", code: 5, userInfo: [NSLocalizedDescriptionKey: "model did not return JSON: \(text.prefix(200))"])) }
                }.resume()
                sem.wait()
                DispatchQueue.main.async { completion(result) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }
}
