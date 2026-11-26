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

/// 밤 모드: 아이폰이 화면을 켠 채 서버를 지켜보다가, 요청이 오면 워치 앱을 깨움
@MainActor
final class NightModel: ObservableObject {
    @Published var on = false
    @Published var line = ""
    @Published var lastResult = ""
    private let store = HKHealthStore()
    private var loop: Task<Void, Never>?
    private var lastLaunch = Date.distantPast

    func toggle(_ v: Bool) {
        on = v
        UIApplication.shared.isIdleTimerDisabled = v   // 화면 안 꺼지게
        loop?.cancel(); loop = nil
        if v { loop = Task { await run() } } else { line = "" }
    }

    func launchWatch(reason: String) {
        lastLaunch = Date()
        let c = HKWorkoutConfiguration()
        c.activityType = .other
        c.locationType = .indoor
        store.startWatchApp(with: c) { ok, err in
            Task { @MainActor in
                let t = Date().formatted(date: .omitted, time: .standard)
                if ok { self.lastResult = "\(t) 워치 깨움 성공 (\(reason))" }
                else if let e = err as NSError? { self.lastResult = "\(t) 실패: \(e.localizedDescription) [\(e.code)]" }
            }
        }
    }

    private func run() async {
        while !Task.isCancelled {
            do {
                let r = try await Api.post("api/ping", ["src": "phone"])
                let now = r.now ?? Date().timeIntervalSince1970 * 1000
                let hrAge = (now - (r.lastHrTs ?? 0)) / 1000
                if r.watching == true {
                    line = "요청 들어옴 · 워치 심박 \(hrAge < 15 ? "수신 중" : "대기")"
                    // 워치 심박이 안 들어오고 있으면 깨우기 (20초마다 재시도)
                    if hrAge > 15, Date().timeIntervalSince(lastLaunch) > 20 { launchWatch(reason: "웹 요청") }
                } else {
                    line = "대기 중 · 웹 버튼을 기다리는 중"
                }
            } catch {
                line = "서버 연결 안 됨"
            }
            try? await Task.sleep(nanoseconds: 5_000_000_000)
        }
    }
}

struct ContentView: View {
    @State private var url = Settings.serverURL
    @State private var key = Settings.deviceKey
    @State private var log = ""
    @StateObject private var night = NightModel()
    private let store = HKHealthStore()

    var body: some View {
        if night.on { NightScreen(night: night) } else { setup }
    }

    private var setup: some View {
        NavigationStack {
            Form {
                Section {
                    Button("🌙 밤 모드 켜기") { night.toggle(true) }
                        .font(.headline)
                } footer: {
                    Text("자기 전에 켜고 아이폰을 충전기에 두세요. 화면이 켜진 채로 웹 버튼을 기다리다가, 누르면 워치를 깨워 5분 측정해요. 워치 센서는 평소엔 꺼져 있어요.")
                }
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
                            do { _ = try await Api.post("api/ping", ["src": "phone"]); log += "\n서버 연결 OK" }
                            catch { log += "\n서버 연결 실패: \(error.localizedDescription)" }
                        }
                    }
                }
                Section {
                    Button("워치 깨우기 테스트") { night.launchWatch(reason: "테스트") }
                    Button("건강 권한 요청") {
                        store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [HKQuantityType(.heartRate)]) { ok, err in
                            DispatchQueue.main.async { log = ok ? "권한 요청 완료" : "실패: \(err?.localizedDescription ?? "")" }
                        }
                    }
                }
                if !log.isEmpty || !night.lastResult.isEmpty {
                    Section("결과") { Text([log, night.lastResult].filter { !$0.isEmpty }.joined(separator: "\n")).font(.footnote) }
                }
            }
            .navigationTitle("HeartCheck")
        }
    }
}

struct NightScreen: View {
    @ObservedObject var night: NightModel
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack(spacing: 14) {
                Text("🌙").font(.system(size: 40))
                Text(night.line).font(.footnote).foregroundStyle(.gray)
                if !night.lastResult.isEmpty { Text(night.lastResult).font(.caption2).foregroundStyle(.gray.opacity(0.7)) }
                Button("밤 모드 끄기") { night.toggle(false) }
                    .font(.footnote).foregroundStyle(.gray).padding(.top, 30)
            }
            .multilineTextAlignment(.center).padding()
        }
        .onAppear { UIScreen.main.brightness = 0.05 }
    }
}
