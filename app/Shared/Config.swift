import Foundation

/// 서버 주소·키 — 아이폰 앱에서 입력하면 워치로 자동 전달됨
enum Settings {
    private static let d = UserDefaults.standard
    static var serverURL: String {
        get { d.string(forKey: "serverURL") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "serverURL") }
    }
    static var deviceKey: String {
        get { d.string(forKey: "deviceKey") ?? "" }
        set { d.set(newValue.trimmingCharacters(in: .whitespacesAndNewlines), forKey: "deviceKey") }
    }
}

enum Api {
    struct Reply: Decodable { let keepUntil: Double?; let watching: Bool?; var lastHrTs: Double? = nil; var now: Double? = nil }

    static func post(_ path: String, _ body: [String: Any] = [:]) async throws -> Reply {
        guard !Settings.serverURL.isEmpty, let base = URL(string: Settings.serverURL) else { throw URLError(.badURL) }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 8
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Settings.deviceKey, forHTTPHeaderField: "X-Key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let h = resp as? HTTPURLResponse, h.statusCode == 401 { throw URLError(.userAuthenticationRequired) }
        return (try? JSONDecoder().decode(Reply.self, from: data)) ?? Reply(keepUntil: nil, watching: nil)
    }
}
