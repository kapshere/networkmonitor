import AppKit
import SwiftUI

@main
struct NetworkMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate: AppDelegate
    @State private var chat = ChatViewModel(agent: AgentFactory.makeAgent())

    var body: some Scene {
        MenuBarExtra("Network Monitor", systemImage: "network") {
            ChatView(model: chat)
                .frame(width: 380, height: 520)
        }
        .menuBarExtraStyle(.window)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu bar only: no Dock icon or app menu. (Equivalent to LSUIElement for an SPM executable.)
        NSApp.setActivationPolicy(.accessory)
    }
}
