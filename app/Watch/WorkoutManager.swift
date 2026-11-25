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

    private let store = HKHealthStore()
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var mode: Mode = .onDemand
    private var startedAt = Date()
    private var deadline = Date()          // onDemand: 서버 keepUntil 로 갱신됨
    private var lastSent = Date.distantPast
    private var watching = true            // 서버 응답: 누가 보고 있는지
    private var sending = false

    private let hrType = HKQuantityType(.heartRate)
    private let bpmUnit = HKUnit.count().unitDivided(by: .minute())

    func requestAuthorization() {
        store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [hrType]) { _, _ in }
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
            b.beginCollection(withStart: now) { _, _ in }
            isRunning = true
            statusText = mode == .overnight ? "밤새 모드" : "측정 중"
            Api.event("watch_started", mode == .overnight ? "overnight" : "onDemand")
        } catch {
            statusText = "시작 실패"
            Api.event("error", "워치 세션 시작 실패: \(error.localizedDescription)")
        }
    }

    func stop() {
        guard let session else { return }
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

        // 전송 간격: 보고 있으면 2초, 밤새 모드에서 아무도 안 보면 60초
        let interval: TimeInterval = (mode == .overnight && !watching) ? 60 : 2
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
        if toState == .ended {
            Task { @MainActor in self.cleanup(endDate: date) }
        }
    }

    nonisolated func workoutSession(_ workoutSession: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            Api.event("error", "워치 세션 오류: \(error.localizedDescription)")
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
