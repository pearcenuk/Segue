//
//  SegueCommands.swift
//  PodPlayout
//
//  Created by Neil Pearce on 26/10/2025.
//

import SwiftUI

struct SegueCommands: Commands {
    @FocusedObject private var vm: PlayoutViewModel?
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {

        // ── App menu: Settings ──────────────────────────────────────────────
        CommandGroup(after: .appSettings) {
            Button("Settings…") {
                vm?.showingSettings = true
            }
            .keyboardShortcut(",", modifiers: .command)
            .disabled(vm == nil)
        }

        // ── File menu ───────────────────────────────────────────────────────
        // Replace the default "New" with playlist-aware items
        CommandGroup(replacing: .newItem) {
            Button("New Playlist") {
                vm?.showingClearConfirm = true
            }
            .keyboardShortcut("n", modifiers: .command)
            .disabled(vm == nil || vm?.items.isEmpty == true)

            Divider()

            Button("Add Audio Files…") {
                vm?.openTrackPicker()
            }
            .keyboardShortcut("o", modifiers: .command)
            .disabled(vm == nil)

            Button("Add Pause") {
                vm?.addPause()
            }
            .disabled(vm == nil)
        }

        CommandGroup(after: .saveItem) {
            Divider()
            Button("Import Playlist…") {
                vm?.openImportPanel()
            }
            .keyboardShortcut("l", modifiers: .command)
            .disabled(vm == nil)

            Button("Export Playlist…") {
                vm?.openExportPanel()
            }
            .keyboardShortcut("s", modifiers: .command)
            .disabled(vm == nil)
        }

        // ── Playback menu ───────────────────────────────────────────────────
        CommandMenu("Playback") {
            Button(vm?.isPlaying == true ? "Pause" : "Play") {
                vm?.togglePlayPause()
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(vm == nil || vm?.items.isEmpty == true)

            Divider()

            Button("Next Track") {
                vm?.next()
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(vm?.isPlaying != true && vm?.currentIndex == nil)

            Button("Previous Track") {
                vm?.previous()
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(vm?.isPlaying != true && vm?.currentIndex == nil)

            Divider()

            Button("Seek Back 5 Seconds") {
                vm?.seekBackward()
            }
            .disabled(vm?.isPlaying != true)

            Button("Seek Forward 5 Seconds") {
                vm?.seekForward()
            }
            .disabled(vm?.isPlaying != true)

            Button("Skip to Near End") {
                vm?.seekToNearEnd()
            }
            .keyboardShortcut("e", modifiers: .command)
            .disabled(vm?.isPlaying != true)

            Divider()

            Button("Fade Out") {
                vm?.fadeOut()
            }
            .keyboardShortcut(".", modifiers: .command)
            .disabled(vm?.isPlaying != true)
        }

        // ── Session menu ────────────────────────────────────────────────────
        CommandMenu("Session") {
            Button("Reset Session") {
                vm?.resetSession()
            }
            .keyboardShortcut("r", modifiers: [.command, .shift])
            .help("Stop playback and clear played markers — keeps all tracks")
            .disabled(vm == nil || vm?.items.isEmpty == true)

            Button("Clear Playlist…") {
                vm?.showingClearConfirm = true
            }
            .disabled(vm == nil || vm?.items.isEmpty == true)
        }

        // ── Help menu ───────────────────────────────────────────────────────
        CommandGroup(replacing: .help) {
            Button("Keyboard Shortcuts") {
                vm?.showingKeyboardShortcuts = true
            }
            .keyboardShortcut("/", modifiers: .command)

            Button("Segue Help") {
                openWindow(id: "segue-help")
            }
        }
    }
}
