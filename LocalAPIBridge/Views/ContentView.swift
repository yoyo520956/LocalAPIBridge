import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject private var engine: PollingEngine
    @EnvironmentObject private var keeper: BackgroundKeeper
    @EnvironmentObject private var pip: PiPStatusController
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("localapibridge.keepAlive") private var keepAlive = false
    @AppStorage("localapibridge.screenAlwaysOn") private var screenAlwaysOn = false
    @AppStorage("localapibridge.pipKeepAlive") private var pipKeepAlive = false

    var body: some View {
        TabView {
            HomeView()
                .tabItem {
                    Label("概览", systemImage: "antenna.radiowaves.left.and.right")
                }

            HistoryView()
                .tabItem {
                    Label("记录", systemImage: "clock.arrow.circlepath")
                }

            SettingsView()
                .tabItem {
                    Label("设置", systemImage: "gearshape")
                }
        }
        .overlay(alignment: .topLeading) {
            PiPAnchorView()
                .frame(width: 44, height: 28)
                .opacity(0.05)
                .allowsHitTesting(false)
        }
        .onAppear {
            keeper.setScreenAlwaysOn(screenAlwaysOn)
            pip.setEnabled(pipKeepAlive)
            if pipKeepAlive, !pip.isEnabled {
                pipKeepAlive = false
            }
            engine.bootstrap()
            if keepAlive, !keeper.start() {
                keepAlive = false
            }
        }
        .onChange(of: pipKeepAlive) { newValue in
            pip.setEnabled(newValue)
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .inactive || newPhase == .background {
                pip.startIfPossible()
            }
            if newPhase == .active {
                engine.refreshAddresses()
                engine.ensureServerRunning()
                keeper.setScreenAlwaysOn(screenAlwaysOn)
                if keepAlive, !keeper.start() {
                    keepAlive = false
                }
            }
        }
    }
}

private struct PiPAnchorView: UIViewRepresentable {
    @EnvironmentObject private var pip: PiPStatusController
    @EnvironmentObject private var engine: PollingEngine

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        pip.attach(sourceView: view) {
            engine.pipStatusData()
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
