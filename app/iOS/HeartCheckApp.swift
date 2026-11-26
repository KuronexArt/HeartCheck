import SwiftUI
import HealthKit

@main
struct HeartCheckApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}

struct ContentView: View {
    @State private var log = ""
    private let store = HKHealthStore()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button("건강 권한 요청") {
                        store.requestAuthorization(toShare: [HKObjectType.workoutType()], read: [HKQuantityType(.heartRate)]) { ok, err in
                            DispatchQueue.main.async { log = ok ? "권한 요청 완료" : "실패: \(err?.localizedDescription ?? "")" }
                        }
                    }
                } footer: {
                    Text("워치에서 HeartCheck를 열면 심박수가 바로 표시돼요.")
                }
                if !log.isEmpty { Section { Text(log).font(.footnote) } }
            }
            .navigationTitle("HeartCheck")
        }
    }
}
