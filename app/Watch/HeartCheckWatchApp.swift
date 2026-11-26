import SwiftUI
import HealthKit

@main
struct HeartCheckWatchApp: App {
    var body: some Scene {
        WindowGroup { HeartView() }
    }
}

/// 앱을 열면 심박수를 보여줌.
/// 1) 운동 세션으로 센서를 켜서 실시간 측정을 시도하고
/// 2) 안 되면 워치가 기록한 최신 심박을 바로바로 보여줌.
@MainActor
final class HeartModel: NSObject, ObservableObject {
    @Published var bpm: Int?
    @Published var measuredAt: Date?
    @Published var live = false
    @Published var note = ""

    private let store = HKHealthStore()
    private let hrType = HKQuantityType(.heartRate)
    private let unit = HKUnit.count().unitDivided(by: .minute())
    private var session: HKWorkoutSession?
    private var builder: HKLiveWorkoutBuilder?
    private var query: HKAnchoredObjectQuery?

    func start() {
        store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [hrType]) { _, _ in
            Task { @MainActor in
                self.startQuery()
                self.startSession()
            }
        }
    }

    func stop() {
        session?.end()
        session = nil; builder = nil; live = false
    }

    // 워치가 저장하는 심박 샘플을 실시간으로 받아옴
    private func startQuery() {
        guard query == nil else { return }
        let since = Date().addingTimeInterval(-6 * 3600)
        let pred = HKQuery.predicateForSamples(withStart: since, end: nil)
        let handler: (HKAnchoredObjectQuery, [HKSample]?, [HKDeletedObject]?, HKQueryAnchor?, Error?) -> Void = { [weak self] _, samples, _, _, _ in
            guard let latest = (samples as? [HKQuantitySample])?.max(by: { $0.endDate < $1.endDate }) else { return }
            Task { @MainActor in
                guard let self else { return }
                if self.measuredAt == nil || latest.endDate > self.measuredAt! {
                    self.bpm = Int(latest.quantity.doubleValue(for: self.unit).rounded())
                    self.measuredAt = latest.endDate
                }
            }
        }
        let q = HKAnchoredObjectQuery(type: hrType, predicate: pred, anchor: nil, limit: HKObjectQueryNoLimit, resultsHandler: handler)
        q.updateHandler = handler
        store.execute(q)
        query = q
    }

    // 센서를 켜서 1~5초 간격 측정 시도
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
            session = s; builder = b
            s.startActivity(with: Date())
            b.beginCollection(withStart: Date()) { _, _ in }
        } catch {
            note = "실시간 측정 불가 — 워치 기록값 표시 중"
        }
    }
}

extension HeartModel: HKWorkoutSessionDelegate, HKLiveWorkoutBuilderDelegate {
    nonisolated func workoutSession(_ s: HKWorkoutSession, didChangeTo to: HKWorkoutSessionState, from: HKWorkoutSessionState, date: Date) {
        Task { @MainActor in self.live = (to == .running) }
    }
    nonisolated func workoutSession(_ s: HKWorkoutSession, didFailWithError error: Error) {
        Task { @MainActor in
            self.live = false; self.session = nil; self.builder = nil
            self.note = "실시간 측정 불가(\((error as NSError).code)) — 워치 기록값 표시 중"
        }
    }
    nonisolated func workoutBuilderDidCollectEvent(_ b: HKLiveWorkoutBuilder) {}
    nonisolated func workoutBuilder(_ b: HKLiveWorkoutBuilder, didCollectDataOf types: Set<HKSampleType>) {
        let hr = HKQuantityType(.heartRate)
        guard types.contains(hr), let q = b.statistics(for: hr)?.mostRecentQuantity() else { return }
        let v = Int(q.doubleValue(for: HKUnit.count().unitDivided(by: .minute())).rounded())
        Task { @MainActor in self.bpm = v; self.measuredAt = Date(); self.live = true }
    }
}

struct HeartView: View {
    @StateObject private var m = HeartModel()
    @Environment(\.scenePhase) private var phase

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            VStack(spacing: 6) {
                Image(systemName: "heart.fill")
                    .foregroundStyle(.pink)
                    .symbolEffect(.pulse, isActive: m.live)
                Text(m.bpm.map(String.init) ?? "--")
                    .font(.system(size: 56, weight: .bold, design: .rounded))
                    .monospacedDigit()
                Text("BPM").font(.caption).foregroundStyle(.secondary)
                if let t = m.measuredAt {
                    Text(m.live ? "실시간" : ago(ctx.date.timeIntervalSince(t)))
                        .font(.footnote).foregroundStyle(m.live ? .green : .secondary)
                }
                if !m.note.isEmpty {
                    Text(m.note).font(.system(size: 10)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        }
        .onAppear { m.start() }
        .onChange(of: phase) { _, p in if p == .active { m.start() } }
    }

    private func ago(_ s: TimeInterval) -> String {
        let s = Int(s)
        if s < 60 { return "\(s)초 전 측정" }
        if s < 3600 { return "\(s / 60)분 전 측정" }
        return "\(s / 3600)시간 전 측정"
    }
}
