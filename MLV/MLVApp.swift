//
//  MLVApp.swift
//  MLV
//
//  Created by DANNY on 26.03.2026.
//

import SwiftUI
import SwiftData

@main
struct MLVApp: App {
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
        WindowGroup {
            ContentView()
        }
        .modelContainer(sharedModelContainer)
        
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
