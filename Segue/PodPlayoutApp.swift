//
//  PodPlayoutApp.swift
//  PodPlayout
//
//  Created by Neil Pearce on 26/10/2025.
//

import SwiftUI

@main
struct SegueApp: App {
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
