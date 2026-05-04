//
//  PodPlayoutApp.swift
//  PodPlayout
//
//  Created by Neil Pearce on 26/10/2025.
//

import SwiftUI
import AppKit

@main
struct SegueApp: App {
    init() {
        // Remove "Show Tab Bar" / "Show All Tabs" from the View menu —
        // Segue is a single-window app and tabs make no sense here.
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
                .frame(minWidth: 800, minHeight: 600)
        }
        .defaultSize(width: 1100, height: 760)
        .commands { SegueCommands() }

        Window("Segue Help", id: "segue-help") {
            HelpView()
                .preferredColorScheme(.dark)
        }
        .defaultSize(width: 800, height: 580)
    }
}
