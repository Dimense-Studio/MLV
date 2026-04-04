//
//  MLVApp.swift
//  MLV
//
//  Created by DANNY on 26.03.2026.
//

import SwiftUI
import SwiftData

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task { @MainActor in
            AppNotifications.shared.requestIfNeeded()
            LoginItemManager.shared.setEnabled(AppSettingsStore.shared.launchAtLogin)
            await VMManager.shared.handleRuntimeModeChange()
            VMManager.shared.refreshBackgroundExecution()
            VMManager.shared.autoStartVMsIfNeeded()
            ClusterManager.shared.start()
            AppUpdateManager.shared.start()
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct MLVApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
        }
        .modelContainer(for: Item.self, inMemory: false)

        MenuBarExtra("MLV", systemImage: "cube.transparent") {
            MenuBarRootView()
        }
        
        Settings {
            SettingsView()
        }
        
        WindowGroup(id: "console", for: UUID.self) { $vmID in
            if let id = vmID,
               let vm = VMManager.shared.virtualMachines.first(where: { $0.id == id }) {
                VMConsoleWindow(vm: vm)
            } else {
                ContentUnavailableView("VM not found", systemImage: "questionmark")
                    .frame(minWidth: 600, minHeight: 400)
            }
        }
    }
}

private struct MenuBarRootView: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open MLV") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Button("Close All Windows") {
            for window in NSApp.windows {
                window.close()
            }
        }
        Divider()
        Button("Quit") {
            NSApp.terminate(nil)
        }
    }
}
