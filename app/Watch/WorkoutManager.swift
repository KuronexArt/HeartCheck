import Foundation
import HealthKit
import WatchKit

/// 운동 세션으로 심박을 실시간(약 1~5초 간격) 측정해서 서버로 보냄.
/// 측정이 끝나면 운동 기록은 저장하지 않고 버림(건강 앱/활동 링에 안 남음).
@MainActor
final class WorkoutManager: NSObject, ObservableObject {
    static let shared = WorkoutManager()

    enum Mode { case onDemand, overnight }

    @Published private(set) var bpm: Int?
    @Published private(set) var isRunning = false
    @Published private(set) var statusText = "대기 중"
    @Published private(set) var lastError = ""        // 진단용: 마지막 오류를 화면에 표시
    @Published private(set) var authText = "권한 확인 중"

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var mode: Mode = .onDemand
    private var startedAt = Date()
    private var deadline = Date()          // onDemand: 서버 keepUntil 로 갱신됨
    private var lastSent = Date.distantPast
    private var watching = true            // 서버 응답: 누가 보고 있는지
    private var sending = false
    private var userStopped = false

    private let hrType = HKQuantityType(.heartRate)
    private let bpmUnit = HKUnit.count().unitDivided(by: .minute())

    func refreshAuthStatus() {
        guard HKHealthStore.isHealthDataAvailable() else { authText = "건강 데이터 사용 불가"; return }
        switch store.authorizationStatus(for: HKObjectType.workoutType()) {
        case .sharingAuthorized: authText = "운동 권한: 허용됨"
        case .sharingDenied: authText = "운동 권한: 거부됨"
        case .notDetermined: authText = "운동 권한: 아직 안 물어봄"
        @unknown default: authText = "운동 권한: 알 수 없음"
        }
    }

    func requestAuthorization() {
        store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [hrType]) { ok, err in
            Task { @MainActor in
                if let err { self.lastError = "권한 요청 오류: \(Self.describe(err))" }
                self.refreshAuthStatus()
            }
        }
    }

    static func describe(_ error: Error) -> String {
        let e = error as NSError
        return "\(e.localizedDescription) [\(e.domain) \(e.code)]"
    }

    func start(mode: Mode, configuration: HKWorkoutConfiguration? = nil) {
        // 이미 측정 중이면 시간만 연장
        if isRunning {
            if mode == .onDemand { deadline = max(deadline, Date().addingTimeInterval(Double(Config.defaultMinutes) * 60)) }
            return
        }
        let config = configuration ?? {
            let c = HKWorkoutConfiguration()
            c.activityType = .mindAndBody
            c.locationType = .indoor
            return c
        }()
        do {
            let s = try HKWorkoutSession(healthStore: store, configuration: config)
            let b = s.associatedWorkoutBuilder()
            b.dataSource = HKLiveWorkoutDataSource(healthStore: store, workoutConfiguration: config)
            s.delegate = self
            b.delegate = self
            session = s; builder = b
            self.mode = mode
            startedAt = Date()
            deadline = Date().addingTimeInterval(Double(Config.defaultMinutes) * 60)
            watching = true
            let now = Date()
            s.startActivity(with: now)
            b.beginCollection(withStart: now) { ok, err in
                if let err {
                    Task { @MainActor in
                        self.lastError = "수집 시작 오류: \(Self.describe(err))"
                        Api.event("error", self.lastError)
                    }
                }
            }
            lastError = ""
            userStopped = false
            isRunning = true
            statusText = mode == .overnight ? "밤새 모드" : "측정 중"
            Api.event("watch_started", mode == .overnight ? "overnight" : "onDemand")
        } catch {
            statusText = "시작 실패"
            lastError = "세션 생성 오류: \(Self.describe(error))"
            Api.event("error", lastError)
        }
    }

    func stop() {
        guard let session else { return }
        userStopped = true
        session.end()   // → didChangeTo .ended 에서 정리
    }

    private func cleanup(endDate: Date) {
        let b = builder
        b?.endCollection(withEnd: endDate) { _, _ in b?.discardWorkout() }
        session = nil; builder = nil
        isRunning = false
        statusText = "대기 중"
        Api.event("watch_ended")
    }

    // 새 심박이 들어올 때마다 호출
    private func handle(bpm value: Int) {
        bpm = value
        let now = Date()

        // 종료 조건
        if now.timeIntervalSince(startedAt) > Double(Config.hardLimitMinutes) * 60, mode == .onDemand { stop(); return }
        if mode == .onDemand, now > deadline { stop(); return }

        // 전송 간격: 보고 있으면 2초, 밤새 모드에서 아무도 안 보면 15초
        // (버튼 누른 뒤 실시간으로 바뀌기까지 최대 15초)
        let interval: TimeInterval = (mode == .overnight && !watching) ? 15 : 2
        guard !sending, now.timeIntervalSince(lastSent) >= interval else { return }
        sending = true
        lastSent = now
        let ts = now.timeIntervalSince1970 * 1000
        Task {
            defer { self.sending = false }
            guard let data = try? await Api.post("api/hr", ["bpm": value, "ts": ts]),
                  let r = try? JSONDecoder().decode(Api.HrResponse.self, from: data) else { return }
            if let w = r.watching { self.watching = w }
            if let ku = r.keepUntil, self.mode == .onDemand {
                // 서버가 연장/중지를 결정 (사이트의 '연장'·'그만하기' 버튼)
                self.deadline = Date(timeIntervalSince1970: ku / 1000)
                if Date() > self.deadline { self.stop() }
            }
        }
    }
}

extension WorkoutManager: HKWorkoutSessionDelegate {
    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didChangeTo toState: HKWorkoutSessionState,
                                    from fromState: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in
            if toState == .ended {
                if !self.userStopped, self.lastError.isEmpty {
                    self.lastError = "세션이 저절로 끝남 (이전 상태 \(fromState.rawValue), \(Int(Date().timeIntervalSince(self.startedAt)))초 만에)"
                }
                self.cleanup(endDate: date)
            }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.lastError = "세션 오류: \(Self.describe(error))"
            Api.event("error", self.lastError)
            self.cleanup(endDate: Date())
        }
    }
}

extension WorkoutManager: HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutBuilderDidCollectEvent(_ workoutBuilder: HKLiveWorkoutBuilder) {}

    nonisolated func workoutBuilder(_ workoutBuilder: HKLiveWorkoutBuilder, didCollectDataOf collectedTypes: Set<HKSampleType>) {
        let hrType = HKQuantityType(.heartRate)
        guard collectedTypes.contains(hrType),
              let q = workoutBuilder.statistics(for: hrType)?.mostRecentQuantity() else { return }
        let value = Int(q.doubleValue(for: HKUnit.count().unitDivided(by: .minute())).rounded())
        Task { @MainActor in self.handle(bpm: value) }
    }
}
