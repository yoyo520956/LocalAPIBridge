import SwiftUI

@main
struct LocalAPIBridgeApp: App {
    @StateObject private var engine = PollingEngine()
    @StateObject private var keeper = BackgroundKeeper()
    @StateObject private var pip = PiPStatusController()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(engine)
                .environmentObject(keeper)
                .environmentObject(pip)
        }
    }
}
