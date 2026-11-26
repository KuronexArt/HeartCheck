import SwiftUI
import HealthKit
import WatchConnectivity

@main
struct HeartCheckApp: App {
    init() { WatchLink.shared.activate() }
    var body: some Scene { WindowGroup { ContentView() } }
}

/// 서버 주소·키를 워치로 전달
final class WatchLink: NSObject, WCSessionDelegate {
    static let shared = WatchLink()
    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }
    @discardableResult
    func push() -> String {
        let s = WCSession.default
        guard s.activationState == .activated else { return "워치 연결 준비 중 — 잠시 후 다시 저장하세요" }
        guard s.isPaired else { return "페어링된 워치가 없어요" }
        guard s.isWatchAppInstalled else { return "워치에 HeartCheck가 설치돼 있지 않아요" }
        let ctx: [String: Any] = ["serverURL": Settings.serverURL, "deviceKey": Settings.deviceKey, "t": Date().timeIntervalSince1970]
        try? s.updateApplicationContext(ctx)
        s.transferUserInfo(ctx)
        return "워치로 전달했어요"
    }
    func session(_ s: WCSession, activationDidCompleteWith st: WCSessionActivationState, error: Error?) { if !Settings.serverURL.isEmpty { push() } }
    func sessionDidBecomeInactive(_ s: WCSession) {}
    func sessionDidDeactivate(_ s: WCSession) { s.activate() }
}

struct ContentView: View {
    @State private var url = Settings.serverURL
    @State private var key = Settings.deviceKey
    @State private var log = ""
    private let store = HKHealthStore()

    var body: some View {
        NavigationStack {
            Form {
                Section("서버") {
                    TextField("https://xxxx.trycloudflare.com", text: $url)
                        .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    TextField("기기 키 (DEVICE_KEY)", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("저장하고 워치로 보내기") {
                        Settings.serverURL = url
                        Settings.deviceKey = key
                        log = WatchLink.shared.push()
                        Task {
                            do { _ = try await Api.post("api/ping"); log += "\n서버 연결 OK" }
                            catch { log += "\n서버 연결 실패: \(error.localizedDescription)" }
                        }
                    }
                }
                Section {
                    Button("건강 권한 요청") {
                        store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [HKQuantityType(.heartRate)]) { ok, err in
                            DispatchQueue.main.async { log = ok ? "권한 요청 완료" : "실패: \(err?.localizedDescription ?? "")" }
                        }
                    }
                } footer: {
                    Text("자기 전에 워치에서 HeartCheck를 열어두면 대기 상태가 돼요. 웹에서 [측정 시작]을 누르면 5분 동안 실시간으로 보내요.")
                }
                if !log.isEmpty { Section("결과") { Text(log).font(.footnote) } }
            }
            .navigationTitle("HeartCheck")
        }
    }
}
