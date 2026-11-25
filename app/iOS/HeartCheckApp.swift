import SwiftUI
import UIKit
import HealthKit

@main
struct HeartCheckApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    static let healthStore = HKHealthStore()

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // 무음 푸시는 알림 권한이 없어도 받을 수 있음
        application.registerForRemoteNotifications()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        UserDefaults.standard.set(token, forKey: "apnsToken")
        Task { _ = try? await Api.post("api/register", ["deviceToken": token]) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        UserDefaults.standard.set("등록 실패: \(error.localizedDescription)", forKey: "apnsToken")
    }

    /// 사이트 버튼 → 서버 → 무음 푸시가 여기로 들어옴 (약 30초 실행 시간)
    func application(_ application: UIApplication,
                     didReceiveRemoteNotification userInfo: [AnyHashable: Any],
                     fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void) {
        Api.event("phone_woke")
        Self.launchWatch { ok, err in
            if !ok { Api.event("error", "워치 실행 실패: \(err?.localizedDescription ?? "알 수 없음")") }
            // 이벤트 전송이 끝날 시간을 조금 준 뒤 완료
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { completionHandler(ok ? .newData : .failed) }
        }
    }

    /// 아이폰에서 워치 앱을 백그라운드로 실행시키고 운동 세션 시작
    static func launchWatch(completion: @escaping (Bool, Error?) -> Void) {
        let config = HKWorkoutConfiguration()
        config.activityType = .mindAndBody
        config.locationType = .indoor
        healthStore.startWatchApp(with: config) { ok, err in completion(ok, err) }
    }
}

struct ContentView: View {
    @AppStorage("apnsToken") private var token = ""
    @State private var log = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("상태") {
                    LabeledContent("서버", value: Config.serverURL.host() ?? "-")
                    LabeledContent("푸시 등록", value: token.isEmpty ? "대기 중" : (token.hasPrefix("등록") ? token : "완료"))
                }
                Section {
                    Button("건강 권한 요청") { requestAuth() }
                    Button("워치 측정 테스트") {
                        AppDelegate.launchWatch { ok, err in
                            DispatchQueue.main.async {
                                if ok { log = "워치 실행 요청 성공" }
                                else if let e = err as NSError? { log = "실패: \(e.localizedDescription) [\(e.domain) \(e.code)]" }
                                else { log = "실패: 알 수 없음" }
                                log += "\n" + authStatusText()
                            }
                        }
                    }
                    Button("서버에 다시 등록") {
                        UIApplication.shared.registerForRemoteNotifications()
                        log = "재등록 요청함"
                    }
                } footer: {
                    Text("처음 한 번 '건강 권한 요청'을 누르고, 워치에서도 HeartCheck 앱을 한 번 열어 권한을 허용해 주세요. 이 앱을 앱 전환기에서 위로 밀어 강제종료하면 푸시를 못 받아요.")
                }
                if !log.isEmpty { Section("로그") { Text(log).font(.footnote) } }
            }
            .navigationTitle("HeartCheck")
        }
    }

    private func authStatusText() -> String {
        switch AppDelegate.healthStore.authorizationStatus(for: HKObjectType.workoutType()) {
        case .sharingAuthorized: return "아이폰 운동 권한: 허용됨"
        case .sharingDenied: return "아이폰 운동 권한: 거부됨"
        case .notDetermined: return "아이폰 운동 권한: 아직 안 물어봄"
        @unknown default: return "아이폰 운동 권한: 알 수 없음"
        }
    }

    private func requestAuth() {
        let hr = HKQuantityType(.heartRate)
        AppDelegate.healthStore.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [hr]) { ok, err in
            DispatchQueue.main.async {
                log = ok ? "권한 요청 완료" : "권한 실패: \(err?.localizedDescription ?? "")"
                log += "\n" + authStatusText()
            }
        }
    }
}
