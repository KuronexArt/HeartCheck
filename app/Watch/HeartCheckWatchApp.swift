import SwiftUI
import HealthKit
import WatchConnectivity

@main
struct HeartCheckWatchApp: App {
    init() { PhoneLink.shared.activate() }
    var body: some Scene { WindowGroup { HeartView() } }
}

// MARK: - 아이폰에서 서버 주소·키 받기
final class PhoneLink: NSObject, WCSessionDelegate {
    static let shared = PhoneLink()
    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }
    func session(_ s: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) { apply(s.receivedApplicationContext) }
    func session(_ s: WCSession, didReceiveApplicationContext ctx: [String: Any]) { apply(ctx) }
    func session(_ s: WCSession, didReceiveUserInfo info: [String: Any] = [:]) { apply(info) }
    private func apply(_ d: [String: Any]) {
        if let u = d["serverURL"] as? String, !u.isEmpty { Settings.serverURL = u }
        if let k = d["deviceKey"] as? String, !k.isEmpty { Settings.deviceKey = k }
    }
}

// MARK: - 심박 측정 + 서버 전송
/// 앱을 열면 자동으로 '대기' — 센서를 켜두고 10초마다 서버에 생존 신호.
/// 웹에서 [측정 시작]을 누르면 2초 간격으로 심박 전송, 5분 뒤 자동으로 대기 복귀.
@MainActor
final class HeartModel: NSObject, ObservableObject {
    @Published var bpm: Int?
    @Published var live = false          // 운동 세션 살아 있음 (대기 포함)
    @Published var sensorOn = false      // 센서 켜짐 (세션 running)
    @Published var sending = false       // 웹 요청으로 실시간 전송 중
    @Published var keepUntil: Date?
    @Published var serverOK: Bool?
    @Published var note = ""

    private let store = HKHealthStore()
    private let hrType = HKQuantityType(.heartRate)
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var collectionStarted = false
    private var retries = 0
    private var lastHrAt = Date.distantPast
    private var loop: Task<Void, Never>?

    func start() {
        if loop == nil { loop = Task { await self.runLoop() } }
        store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [hrType]) { _, _ in
            Task { @MainActor in self.startSession() }
        }
    }

    private func startSession() {
        guard session == nil else { return }
        let config = HKWorkoutConfiguration()
        config.activityType = .other
        config.locationType = .indoor
        do {
            let s = try HKWorkoutSession(healthStore: store, configuration: config)
            let b = s.associatedWorkoutBuilder()
            let ds = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            ds.enableCollection(for: hrType, predicate: nil)
            b.dataSource = ds
            s.delegate = self
            b.delegate = self
            session = s; builder = b; collectionStarted = false
            s.startActivity(with: Date())
        } catch {
            note = "세션 시작 실패 (\((error as NSError).code))"
        }
    }

    fileprivate func onState(_ to: HKWorkoutSessionState, _ date: Date) {
        sensorOn = (to == .running)
        guard to == .running else { return }
        live = true; retries = 0; note = ""
        if !collectionStarted, let b = builder {
            collectionStarted = true
            b.beginCollection(withStart: date) { _, err in
                Task { @MainActor in
                    if let err { self.note = "수집 오류 (\((err as NSError).code))" }
                    // 요청이 없으면 바로 일시정지 → 센서 끔 (대기)
                    if !self.sending { self.session?.pause() }
                }
            }
        } else if !sending {
            session?.pause()
        }
    }

    fileprivate func onEnded(_ error: Error?) {
        if let error { note = "세션 오류 (\((error as NSError).code))" }
        live = false; sensorOn = false; sending = false
        builder?.discardWorkout()
        session = nil; builder = nil; collectionStarted = false
        // 대기는 '항상 켜짐' — 끊기면 자동 재시작 (최대 5회)
        guard retries < 5 else { return }
        retries += 1
        Task { try? await Task.sleep(nanoseconds: 3_000_000_000); self.startSession() }
    }

    fileprivate func onHeartRate(_ v: Int) {
        bpm = v
        lastHrAt = Date()
    }

    /// 서버와 통신: 대기 10초 / 실시간 2초 간격
    private func runLoop() async {
        while !Task.isCancelled {
            let fresh = Date().timeIntervalSince(lastHrAt) < 10
            let path = (sending && fresh) ? "api/hr" : "api/ping"
            var body: [String: Any] = ["ts": Date().timeIntervalSince1970 * 1000]
            if let b = bpm, fresh { body["bpm"] = b }
            do {
                let r = try await Api.post(path, body)
                serverOK = true
                keepUntil = r.keepUntil.map { Date(timeIntervalSince1970: $0 / 1000) }
                let want = r.watching ?? false
                if want != sending {
                    sending = want
                    if want { session?.resume() } else { session?.pause() }   // 센서 켜기/끄기
                }
            } catch {
                serverOK = false
            }
            try? await Task.sleep(nanoseconds: sending ? 2_000_000_000 : 10_000_000_000)
        }
    }
}

extension HeartModel: HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutSession(_ s: HKWorkoutSession, didChangeTo to: HKWorkoutSessionState, from: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in
            if to == .ended { self.onEnded(nil) } else { self.onState(to, date) }
        }
    }
    nonisolated func workoutSession(_ s: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in self.onEnded(error) }
    }
    nonisolated func workoutBuilderDidCollectEvent(_ b: HKLiveWorkoutBuilder) {}
    nonisolated func workoutBuilder(_ b: HKLiveWorkoutBuilder, didCollectDataOf types: Set<HKSampleType>) {
        let hr = HKQuantityType(.heartRate)
        guard types.contains(hr), let q = b.statistics(for: hr)?.mostRecentQuantity() else { return }
        let v = Int(q.doubleValue(for: HKUnit.count().unitDivided(by: .minute())).rounded())
        Task { @MainActor in self.onHeartRate(v) }
    }
}

// MARK: - 화면
struct HeartView: View {
    @StateObject private var m = HeartModel()

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 4) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(m.sending ? Color.pink : Color.gray)
                    .symbolEffect(.pulse, isActive: m.sensorOn)
                Text(m.bpm.map(String.init) ?? "--")
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(status(ctx.date))
                    .font(.footnote)
                    .foregroundStyle(m.sending ? Color.green : Color.secondary)
                if Settings.serverURL.isEmpty {
                    Text("아이폰 앱에서 서버 주소를 저장하세요").font(.caption2).foregroundStyle(.orange).multilineTextAlignment(.center)
                } else if m.serverOK == false {
                    Text("서버 연결 안 됨").font(.caption2).foregroundStyle(.orange)
                }
                if !m.note.isEmpty { Text(m.note).font(.caption2).foregroundStyle(.red) }
            }
        }
        .onAppear { m.start() }
    }

    private func status(_ now: Date) -> String {
        if !m.live { return "준비 중…" }
        if m.sending, let k = m.keepUntil {
            let s = max(0, Int(k.timeIntervalSince(now)))
            return String(format: "실시간 전송 %d:%02d", s / 60, s % 60)
        }
        return m.sensorOn ? "대기 중 · 센서 끄는 중" : "대기 중 · 센서 꺼짐"
    }
}
