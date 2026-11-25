import SwiftUI
import WatchKit
import HealthKit

@main
struct HeartCheckWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) var delegate
    var body: some Scene {
        WindowGroup { WatchView().environmentObject(WorkoutManager.shared) }
    }
}

final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    /// 아이폰의 startWatchApp(with:) 호출 시 워치 앱이 백그라운드로 깨어나며 여기로 들어옴
    func handle(_ workoutConfiguration: HKWorkoutConfiguration) {
        WorkoutManager.shared.start(mode: .onDemand, configuration: workoutConfiguration)
    }
}

struct WatchView: View {
    @EnvironmentObject var wm: WorkoutManager

    var body: some View {
        ScrollView {
        VStack(spacing: 8) {
            Image(systemName: "heart.fill").foregroundStyle(.pink)
            Text(wm.bpm.map { "\($0)" } ?? "--")
                .font(.system(size: 48, weight: .bold, design: .rounded))
                .monospacedDigit()
            Text(wm.statusText).font(.footnote).foregroundStyle(.secondary)
            if wm.isRunning {
                Button("중지", role: .destructive) { wm.stop() }
            } else {
                Button("밤새 모드 시작") { wm.start(mode: .overnight) }
                    .tint(.indigo)
            }
            // 진단 정보
            Text(wm.authText).font(.caption2).foregroundStyle(.secondary)
            if !wm.lastError.isEmpty {
                Text(wm.lastError).font(.caption2).foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            Button("권한 다시 요청") { wm.requestAuthorization() }
                .font(.footnote)
        }
        }
        .onAppear { wm.requestAuthorization() }
    }
}
