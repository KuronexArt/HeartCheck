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
    func handleActiveWorkoutRecovery() {
        Task { @MainActor in HeartModel.shared.cleanupLeftover() }
    }
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        Task { @MainActor in HeartModel.shared.startRemote() }
    }
    /// 아이폰이 보낸 메시지 때문에 시스템이 백그라운드로 깨워줄 때
    func handle(_ backgroundTasks: Set<WKRefreshBackgroundTask>) {
        for task in backgroundTasks {
            if let t = task as? WKWatchConnectivityRefreshBackgroundTask {
                PhoneLink.shared.activate()
                PhoneLink.shared.hold(t)
            } else {
                task.setTaskCompletedWithSnapshot(false)
            }
        }
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
    private var pending: [WKWatchConnectivityRefreshBackgroundTask] = []
    func hold(_ t: WKWatchConnectivityRefreshBackgroundTask) {
        pending.append(t)
        finishIfDone()
    }
    private func finishIfDone() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
            guard !WCSession.default.hasContentPending else { self.finishIfDone(); return }
            let ts = self.pending; self.pending = []
            ts.forEach { $0.setTaskCompletedWithSnapshot(false) }
        }
    }
    func session(_ s: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) { apply(s.receivedApplicationContext) }
    func session(_ s: WCSession, didReceiveApplicationContext ctx: [String: Any]) { apply(ctx) }
    func session(_ s: WCSession, didReceiveUserInfo info: [String: Any] = [:]) { apply(info) }
    func session(_ s: WCSession, didReceiveMessage m: [String: Any]) { apply(m) }
    func session(_ s: WCSession, didReceiveMessage m: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) { apply(m); replyHandler(["ok": true]) }
    private func apply(_ d: [String: Any]) {
        if let u = d["serverURL"] as? String, !u.isEmpty { Settings.serverURL = u }
        if let k = d["deviceKey"] as? String, !k.isEmpty { Settings.deviceKey = k }
        // 아이폰의 측정 시작 명령 (1분 이내 것만)
        if d["cmd"] as? String == "start", let t = d["t"] as? Double, Date().timeIntervalSince1970 - t < 60 {
            Task { @MainActor in HeartModel.shared.startRemote() }
        }
    }
}

// MARK: - 측정
/// 평소엔 꺼져 있음(센서 꺼짐). 아이폰이 깨우거나 직접 열면 측정 → 서버가 그만하라 하면 세션 종료(센서 꺼짐).
@MainActor
final class HeartModel: NSObject, ObservableObject {
    static let shared = HeartModel()
    static let noStandby = true

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
    private var remote = false          // 아이폰/대기가 깨운 측정인지
    private var startedAt = Date()

    // 스마트 알람 대기 (센서 꺼진 채 백그라운드에서 서버 확인)
    @Published var standby = false
    @Published var standbyUntil: Date?
    private var runtime: WKExtendedRuntimeSession?

    func startStandby() {
        if Self.noStandby { return }   // 5.0: 워치 대기 안 씀 (아이폰이 깨움)
        if let r = runtime, r.state == .running || r.state == .scheduled { return }
        let r = WKExtendedRuntimeSession()
        r.delegate = self
        runtime = r
        r.start(at: Date().addingTimeInterval(3))   // 스마트 알람은 예약 방식으로만 시작
        note = "대기 예약함…"
        if loop == nil { loop = Task { await self.runLoop() } }
    }
    func stopStandby() { runtime?.invalidate() }

    fileprivate func onRuntime(_ running: Bool, _ why: String) {
        let was = standby
        standby = running
        standbyUntil = running ? (standbyUntil ?? Date().addingTimeInterval(30 * 60)) : nil
        if !why.isEmpty { note = why }
        // 대기가 끝나면 바로 다시 켜기 시도 (밤새 유지)
        if !running && was {
            Task { try? await Task.sleep(nanoseconds: 2_000_000_000); self.startStandby() }
        }
    }

    func requestAuth() {
        store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [hrType]) { _, _ in }
        cleanupLeftover()
    }

    /// 예전 버전이 남긴 운동 세션이 살아 있으면 찾아서 끔 (초록불 계속 켜짐 방지)
    func cleanupLeftover() {
        guard session == nil else { return }
        store.recoverActiveWorkoutSession { s, _ in
            guard let s else { return }
            Task { @MainActor in
                if self.session == nil {
                    s.delegate = self
                    s.end()
                    self.note = "남아 있던 측정 세션을 껐어요"
                }
            }
        }
    }

    /// 직접 열었을 때 — 화면에 떠 있는 동안 측정
    func startLocal() { remote = false; startSession() }
    /// 아이폰이 깨웠을 때 — 서버가 그만하라 할 때까지 측정
    func startRemote() { remote = true; startSession() }

    func stopIfIdle() {
        if !remote { endSession() }
    }
    /// 화면에서 직접 측정 끄기
    func stopLocal() { remote = false; endSession() }

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
            s.prepare()
            s.startActivity(with: Date())
            measuring = true
        } catch {
            note = "세션 시작 실패 \((error as NSError).code): \(error.localizedDescription)"
        }
    }

    func endSession() {
        session?.end()
    }

    fileprivate func onState(_ to: HKWorkoutSessionState, _ date: Date) {
        if to == .running, !collectionStarted, let b = builder {
            collectionStarted = true
            b.beginCollection(withStart: date) { _, err in
                if let err { Task { @MainActor in self.note = "수집 오류 \((err as NSError).code): \(err.localizedDescription)" } }
            }
        }
        if to == .ended {
            builder?.discardWorkout()
            session = nil; builder = nil; collectionStarted = false
            measuring = false; remote = false
            startStandby()   // 측정 끝나면 다시 대기
        }
    }

    private var retried = false
    fileprivate func onFail(_ error: Error) {
        let e = error as NSError
        let st = WKApplication.shared().applicationState
        let where_ = st == .active ? "화면" : (st == .inactive ? "비활성" : "백그라운드")
        note = "세션 오류 \(e.domain.replacingOccurrences(of: "com.apple.", with: "")) \(e.code) [\(where_)]: \(e.localizedDescription)"
        let wasRemote = remote
        session = nil; builder = nil; collectionStarted = false
        measuring = false; remote = false
        // 한 번만 재시도 (prepare 후 시작)
        if wasRemote && !retried {
            retried = true
            Task { try? await Task.sleep(nanoseconds: 2_000_000_000); self.startRemote() }
        } else { retried = false }
    }

    fileprivate func onHeartRate(_ v: Int) {
        bpm = v
        lastHrAt = Date()
    }

    /// 측정 중일 때만 2초마다 서버로 전송
    private func runLoop() async {
        while !Task.isCancelled {
            if !measuring && standby {
                do {
                    let r = try await Api.post("api/ping", ["src": "watch-standby"])
                    serverOK = true
                    if r.watching == true { startRemote() }
                } catch { serverOK = false }
            } else if measuring {
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
            try? await Task.sleep(nanoseconds: measuring ? 2_000_000_000 : 3_000_000_000)
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

extension HeartModel: WKExtendedRuntimeSessionDelegate {
    nonisolated func extendedRuntimeSessionDidStart(_ s: WKExtendedRuntimeSession) {
        Task { @MainActor in self.onRuntime(true, ""); self.note = "" }
    }
    nonisolated func extendedRuntimeSessionWillExpire(_ s: WKExtendedRuntimeSession) {
        Task { @MainActor in self.onRuntime(true, "대기 곧 끝남") }
    }
    nonisolated func extendedRuntimeSession(_ s: WKExtendedRuntimeSession, didInvalidateWith reason: WKExtendedRuntimeSessionInvalidationReason, error: Error?) {
        let code = (error as NSError?)?.code
        Task { @MainActor in self.onRuntime(false, code != nil ? "대기 종료 (오류 \(code!))" : "대기 종료 (\(reason.rawValue))") }
    }
}

// MARK: - 화면
struct HeartView: View {
    @ObservedObject private var m = HeartModel.shared
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 4) {
                if m.measuring {
                    Text(ctx.date, format: .dateTime.hour().minute())
                        .font(.system(size: 16, weight: .semibold, design: .rounded)).foregroundStyle(.secondary)
                    Image(systemName: "heart.fill")
                        .foregroundStyle(Color.pink)
                        .symbolEffect(.pulse, isActive: true)
                    Text(m.bpm.map(String.init) ?? "--")
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .monospacedDigit()
                } else {
                    // 대기 중엔 시계처럼 보이게
                    Text(ctx.date, format: .dateTime.hour().minute())
                        .font(.system(size: 54, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(ctx.date, format: .dateTime.month().day().weekday())
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Text(status(ctx.date)).font(.footnote).foregroundStyle(m.measuring ? Color.green : Color.secondary)
                if Settings.serverURL.isEmpty {
                    Text("아이폰 앱에서 서버 주소를 저장하세요").font(.caption2).foregroundStyle(.orange).multilineTextAlignment(.center)
                } else if m.serverOK == false {
                    Text("서버 연결 안 됨").font(.caption2).foregroundStyle(.orange)
                }
                if !m.note.isEmpty { Text(m.note).font(.caption2).foregroundStyle(.red) }
                if !m.measuring {
                    Text("아이폰 밤 모드가 켜져 있으면\n웹 요청 때 자동으로 측정해요").font(.caption2).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                if m.measuring { Button("측정 끄기") { m.stopLocal() }.tint(.red) }
            }
        }
        .onAppear { m.requestAuth(); m.startStandby() }
        .onChange(of: phase) { _, p in if p == .active { m.startStandby() } }
    }

    private func status(_ now: Date) -> String {
        if !m.measuring {
            if false, let u = m.standbyUntil {
                let s = max(0, Int(u.timeIntervalSince(now)))
                return String(format: "💤 대기 %d:%02d", s / 60, s % 60)
            }
            return "꺼짐 · 센서 꺼짐"
        }
        if let k = m.keepUntil, k > now {
            let s = Int(k.timeIntervalSince(now))
            return String(format: "실시간 전송 %d:%02d", s / 60, s % 60)
        }
        return "측정 중"
    }
}
