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
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}

@main
struct MLVApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var sharedModelContainer: ModelContainer = {
        let schema = Schema([
            Item.self,
        ])
        let modelConfiguration = ModelConfiguration(schema: schema, isStoredInMemoryOnly: false)

        do {
            return try ModelContainer(for: schema, configurations: [modelConfiguration])
        } catch {
            fatalError("Could not create ModelContainer: \(error)")
        }
    }()

    var body: some Scene {
        WindowGroup(id: "main") {
            ContentView()
        }
        .modelContainer(sharedModelContainer)

        MenuBarExtra("MLV", systemImage: "cube.transparent") {
            MenuBarRootView()
        }
        
        WindowGroup(id: "console", for: UUID.self) { $vmID in
            if let id = vmID,
               let vm = VMManager.shared.virtualMachines.first(where: { $0.id == id }) {
                VMConsoleWindow(vm: vm)
            } else {
                // If macOS restores this window without a valid VM ID,
                // we return an EmptyView and the window will be tiny/invisible or we can close it.
                Color.clear
                    .frame(width: 1, height: 1)
                    .onAppear {
                        // Attempt to close the restored window if it has no VM context
                        DispatchQueue.main.async {
                            NSApp.keyWindow?.close()
                        }
                    }
            }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1024, height: 768)
        .handlesExternalEvents(matching: []) // Prevent automatic window restoration for consoles
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
