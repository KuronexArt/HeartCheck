import SwiftUI
import HealthKit
import WatchKit
import WatchConnectivity

@main
struct HeartCheckWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchDelegate.self) var delegate
    init() { PhoneLink.shared.activate() }
    var body: some Scene { WindowGroup { HeartView() } }
}

/// 아이폰이 startWatchApp으로 깨우면 여기로 들어옴 → 측정 시작
final class WatchDelegate: NSObject, WKApplicationDelegate {
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Task { @MainActor in HeartModel.shared.startRemote() }
    }
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

// MARK: - 측정
/// 평소엔 꺼져 있음(센서 꺼짐). 아이폰이 깨우거나 직접 열면 측정 → 서버가 그만하라 하면 세션 종료(센서 꺼짐).
@MainActor
final class HeartModel: NSObject, ObservableObject {
    static let shared = HeartModel()

    @Published var bpm: Int?
    @Published var measuring = false
    @Published var keepUntil: Date?
    @Published var serverOK: Bool?
    @Published var note = ""

    private let store = HKHealthStore()
    private let hrType = HKQuantityType(.heartRate)
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var collectionStarted = false
    private var lastHrAt = Date.distantPast
    private var loop: Task<Void, Never>?
    private var remote = false          // 아이폰이 깨운 측정인지
    private var startedAt = Date()

    func requestAuth() {
        store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [hrType]) { _, _ in }
    }

    /// 직접 열었을 때 — 화면에 떠 있는 동안 측정
    func startLocal() { remote = false; startSession() }
    /// 아이폰이 깨웠을 때 — 서버가 그만하라 할 때까지 측정
    func startRemote() { remote = true; startSession() }

    func stopIfIdle() {
        if !remote { endSession() }
    }

    private func startSession() {
        if loop == nil { loop = Task { await self.runLoop() } }
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
            startedAt = Date()
            s.startActivity(with: Date())
            measuring = true
        } catch {
            note = "세션 시작 실패 (\((error as NSError).code))"
        }
    }

    func endSession() {
        session?.end()
    }

    fileprivate func onState(_ to: HKWorkoutSessionState, _ date: Date) {
        if to == .running, !collectionStarted, let b = builder {
            collectionStarted = true
            b.beginCollection(withStart: date) { _, err in
                if let err { Task { @MainActor in self.note = "수집 오류 (\((err as NSError).code))" } }
            }
        }
        if to == .ended {
            builder?.discardWorkout()
            session = nil; builder = nil; collectionStarted = false
            measuring = false; remote = false
        }
    }

    fileprivate func onFail(_ error: Error) {
        note = "세션 오류 (\((error as NSError).code))"
        session = nil; builder = nil; collectionStarted = false
        measuring = false; remote = false
    }

    fileprivate func onHeartRate(_ v: Int) {
        bpm = v
        lastHrAt = Date()
    }

    /// 측정 중일 때만 2초마다 서버로 전송
    private func runLoop() async {
        while !Task.isCancelled {
            if measuring {
                let fresh = Date().timeIntervalSince(lastHrAt) < 10
                var body: [String: Any] = ["ts": Date().timeIntervalSince1970 * 1000, "src": "watch"]
                if let b = bpm, fresh { body["bpm"] = b }
                do {
                    let r = try await Api.post(fresh ? "api/hr" : "api/ping", body)
                    serverOK = true
                    keepUntil = r.keepUntil.map { Date(timeIntervalSince1970: $0 / 1000) }
                    // 아이폰이 깨운 측정: 요청이 끝나면 세션 종료 → 센서 꺼짐
                    if remote, r.watching == false, Date().timeIntervalSince(startedAt) > 15 { endSession() }
                } catch {
                    serverOK = false
                }
                // 안전장치: 원격 측정은 최대 6분
                if remote, Date().timeIntervalSince(startedAt) > 360 { endSession() }
            }
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }
}

extension HeartModel: HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutSession(_ s: HKWorkoutSession, didChangeTo to: HKWorkoutSessionState, from: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in self.onState(to, date) }
    }
    nonisolated func workoutSession(_ s: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in self.onFail(error) }
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
    @ObservedObject private var m = HeartModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 4) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(m.measuring ? Color.pink : Color.gray)
                    .symbolEffect(.pulse, isActive: m.measuring)
                Text(m.bpm.map(String.init) ?? "--")
                    .font(.system(size: 52, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text(status(ctx.date)).font(.footnote).foregroundStyle(m.measuring ? Color.green : Color.secondary)
                if Settings.serverURL.isEmpty {
                    Text("아이폰 앱에서 서버 주소를 저장하세요").font(.caption2).foregroundStyle(.orange).multilineTextAlignment(.center)
                } else if m.serverOK == false {
                    Text("서버 연결 안 됨").font(.caption2).foregroundStyle(.orange)
                }
                if !m.note.isEmpty { Text(m.note).font(.caption2).foregroundStyle(.red) }
            }
        }
        .onAppear { m.requestAuth(); m.startLocal() }
        .onChange(of: phase) { _, p in
            if p == .active { m.startLocal() }
            if p == .background { m.stopIfIdle() }
        }
    }

    private func status(_ now: Date) -> String {
        if !m.measuring { return "꺼짐 · 센서 꺼짐" }
        if let k = m.keepUntil, k > now {
            let s = Int(k.timeIntervalSince(now))
            return String(format: "실시간 전송 %d:%02d", s / 60, s % 60)
        }
        return "측정 중"
    }
}
