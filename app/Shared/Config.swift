import Foundation

enum Config {
    /// NAS 주소 (HTTPS 권장 — 시놀로지 역방향 프록시 + 인증서)
    static let serverURL = URL(string: "https://heart.example.com")!
    /// docker-compose.yml 의 DEVICE_KEY 와 동일하게
    static let deviceKey = "여기에_앱용_긴_랜덤문자열"
    /// 푸시로 시작될 때 기본 측정 시간(분) — 서버가 keepUntil 로 연장/종료를 지시함
    static let defaultMinutes = 5
    /// 서버와 연락이 끊겨도 이 시간이 지나면 무조건 종료 (배터리 보호)
    static let hardLimitMinutes = 30
}

enum Api {
    struct HrResponse: Decodable { let ok: Bool?; let keepUntil: Double?; let watching: Bool? }

    static func post(_ path: String, _ body: [String: Any]) async throws -> Data {
        var req = URLRequest(url: Config.serverURL.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.timeoutInterval = 10
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(Config.deviceKey, forHTTPHeaderField: "X-Key")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: req)
        return data
    }

    static func event(_ type: String, _ detail: String = "") {
        Task { _ = try? await post("api/event", ["type": type, "detail": detail]) }
    }
}
