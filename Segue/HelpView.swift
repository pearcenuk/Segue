//
//  HelpView.swift
//  PodPlayout
//
//  Created by Neil Pearce on 26/10/2025.
//

import SwiftUI

// MARK: - Help Window

struct HelpView: View {
    @State private var selectedSection: HelpSection = .gettingStarted

    enum HelpSection: String, CaseIterable, Identifiable {
        case gettingStarted  = "Getting Started"
        case buildingPlaylist = "Building a Playlist"
        case playback         = "Playback"
        case trackOptions     = "Track Options"
        case pausesBeds       = "Pauses & Beds"
        case sessionManagement = "Session Management"
        case fileManagement   = "File Management"
        case keyboardShortcuts = "Keyboard Shortcuts"

        var id: String { rawValue }

        var icon: String {
            switch self {
            case .gettingStarted:    return "star.fill"
            case .buildingPlaylist:  return "music.note.list"
            case .playback:          return "play.circle.fill"
            case .trackOptions:      return "slider.horizontal.3"
            case .pausesBeds:        return "pause.rectangle.fill"
            case .sessionManagement: return "arrow.counterclockwise.circle.fill"
            case .fileManagement:    return "folder.fill"
            case .keyboardShortcuts: return "keyboard.fill"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(HelpSection.allCases, selection: $selectedSection) { section in
                Label(section.rawValue, systemImage: section.icon)
                    .tag(section)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
        } detail: {
            ScrollView {
                HelpSectionContent(section: selectedSection)
                    .padding(24)
                    .frame(maxWidth: 680, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 700, minHeight: 500)
        .navigationTitle("Segue Help")
    }
}

// MARK: - Section content dispatcher

private struct HelpSectionContent: View {
    let section: HelpView.HelpSection

    var body: some View {
        switch section {
        case .gettingStarted:    GettingStartedHelp()
        case .buildingPlaylist:  BuildingPlaylistHelp()
        case .playback:          PlaybackHelp()
        case .trackOptions:      TrackOptionsHelp()
        case .pausesBeds:        PausesBedsHelp()
        case .sessionManagement: SessionManagementHelp()
        case .fileManagement:    FileManagementHelp()
        case .keyboardShortcuts: KeyboardShortcutsHelp()
        }
    }
}

// MARK: - Shared help components

private struct HelpHeading: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.largeTitle.bold())
            .padding(.bottom, 4)
    }
}

private struct HelpSubheading: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.title2.bold())
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

private struct HelpBody: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.body)
            .foregroundStyle(.primary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct HelpTip: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(.yellow)
                .font(.body)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.08)))
    }
}

private struct HelpWarning: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.body)
            Text(text)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.08)))
    }
}

private struct HelpShortcutRow: View {
    let key: String
    let description: String
    var body: some View {
        HStack(spacing: 0) {
            Text(key)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 150, alignment: .leading)
            Text(description)
                .font(.body)
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Section views

private struct GettingStartedHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HelpHeading(text: "Getting Started")
            HelpBody(text: "Segue is a broadcast audio playout application designed for live radio, podcasts, and event production. It gives you precise control over a playlist of audio tracks with professional features like crossfade, trim, normalization, and pause beds.")

            HelpSubheading(text: "Basic workflow")
            VStack(alignment: .leading, spacing: 8) {
                Label("Add your audio files using the **+** button in the toolbar, or **File › Add Audio Files…** (⌘O)", systemImage: "1.circle.fill")
                Label("Reorder tracks by dragging. Add pauses between tracks using right-click › Insert Pause.", systemImage: "2.circle.fill")
                Label("Press **Space** or the Play button to begin playback from the current track.", systemImage: "3.circle.fill")
                Label("Segue automatically advances through the playlist. The **ON AIR** panel shows the current track; **NEXT** shows what's coming.", systemImage: "4.circle.fill")
            }
            .font(.body)
            .padding(.leading, 4)

            HelpSubheading(text: "The interface at a glance")
            HelpBody(text: "The window is split between the **playlist** and the **control area**. By default the controls sit above the playlist — use **View › Playlist at Bottom** to toggle the layout. Segue remembers your preference.")
            HelpBody(text: "The playlist shows each track's title, duration, and status. Green checkmarks mark played tracks; a red speaker marks the currently playing one.")
            HelpBody(text: "The control area contains the **Clock / Show Ends** bar, the progress scrubber, the large **ON AIR** and **NEXT** broadcast panels, and the transport buttons.")

            HelpTip(text: "Segue automatically saves your playlist between sessions. Your tracks, trim points, crossfade settings, and tag colours are all restored the next time you open the app.")
        }
    }
}

private struct BuildingPlaylistHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HelpHeading(text: "Building a Playlist")

            HelpSubheading(text: "Adding tracks")
            HelpBody(text: "Click the **+** button in the toolbar or use **File › Add Audio Files…** (⌘O). You can select multiple files at once — they're added in the order returned by the file picker.")
            HelpBody(text: "Supported formats: **MP3, WAV, AIFF, M4A, FLAC, AAC, CAF, MP4**. If your file isn't listed in the picker, check its extension is one of these.")

            HelpSubheading(text: "Reordering")
            HelpBody(text: "Drag any row by its handle (the three horizontal lines on the right) to move it. You can also drag a track to the very top or bottom and the list will scroll automatically.")

            HelpSubheading(text: "Removing tracks")
            HelpBody(text: "Right-click a track and choose **Remove**, or swipe left on a row. You can also select multiple rows and press Delete.")

            HelpSubheading(text: "Adding pauses")
            HelpBody(text: "Right-click any track and choose **Insert Pause Before** or **Insert Pause After**. A pause row appears in red italic text. When playback reaches a pause, Segue stops automatically and waits for you to press Space (or Next) to continue.")

            HelpSubheading(text: "Tag colours")
            HelpBody(text: "Right-click any track and choose **Tag Color** to assign a colour. The colour appears as a left-edge stripe on the row and tints the title. Use colours to group jingles, ads, music, or any other category.")

            HelpSubheading(text: "Track count and total time")
            HelpBody(text: "A summary bar at the bottom of the playlist shows the total number of tracks and the total remaining time. This updates in real time as the playlist plays.")
        }
    }
}

private struct PlaybackHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HelpHeading(text: "Playback")

            HelpSubheading(text: "Transport controls")
            HelpBody(text: "The transport row contains the main playback controls, centred with Play in the middle:")
            VStack(alignment: .leading, spacing: 6) {
                Label("**⏮** (⌘←)  — Jump to the previous track", systemImage: "backward.end.fill")
                Label("**▶ / ⏸** (Space)  — Play or pause the current track", systemImage: "play.fill")
                Label("**⏭** (⌘→)  — Skip to the next track", systemImage: "forward.end.fill")
                Label("**Fade Out** (⌘.)  — Fade to silence over 3 seconds then stop", systemImage: "stop.fill")
            }
            .font(.body)
            .padding(.leading, 4)

            HelpSubheading(text: "Progress scrubber")
            HelpBody(text: "The slider above the transport row shows the current position within the track. Drag it to seek. The time counter on the left shows elapsed time; the counter on the right shows remaining time. When the remaining time drops below the **nearing-end threshold** (default 30 seconds, adjustable in Settings), the panel background flashes red as a cue warning.")

            HelpSubheading(text: "Seek")
            HelpBody(text: "Press **←** or **→** (without modifier) to seek back or forward 5 seconds. Press **⌘E** to jump to 10 seconds before the end — useful for cueing up the next track's intro during a live show.")

            HelpSubheading(text: "Automatic advance")
            HelpBody(text: "When a track finishes, Segue automatically starts the next item. If the next item is a pause, playback stops and waits. If crossfade is enabled on the outgoing track, the fade begins before the track ends.")

            HelpSubheading(text: "VU meters")
            HelpBody(text: "The VU meters in the ON AIR panel show real-time audio levels. Peak indicators hold briefly before falling back. Aim to keep levels below the peak to avoid clipping.")

            HelpTip(text: "Double-clicking any track in the playlist immediately plays it from the beginning, regardless of what is currently playing.")
        }
    }
}

private struct TrackOptionsHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HelpHeading(text: "Track Options")

            HelpSubheading(text: "Crossfade (fade out into next track)")
            HelpBody(text: "Right-click a track and choose **Fade Out into Next Track** to enable crossfade. When the track nears its end, Segue fades it out while simultaneously fading in the next track. The duration defaults to your global setting but can be set per-track via **Set Fade-out Duration…**")
            HelpBody(text: "A blue **CF** badge appears on any track with crossfade enabled. The default duration and curve can be changed under **Settings** (⌘,).")
            HelpBody(text: "**Crossfade curve** controls the volume shape during the transition:")
            VStack(alignment: .leading, spacing: 4) {
                HelpShortcutRow(key: "Linear",      description: "Both tracks move in straight lines — simple and predictable")
                HelpShortcutRow(key: "Equal Power", description: "Volume follows a sine/cosine curve — perceptually smoother, recommended for music")
            }

            HelpSubheading(text: "Trim points")
            HelpBody(text: "Right-click a track and choose **Set Trim Points…** to set an In point (skip the start) and an Out point (stop early). The trimmed duration is shown in orange with a scissors icon. The progress scrubber and Show Ends calculation both honour your trim points.")

            HelpSubheading(text: "Loudness normalisation")
            HelpBody(text: "Segue scans each track in the background and calculates a gain adjustment to reach −23 dBFS RMS (EBU R128 / podcast standard). A green badge shows the adjustment in dB (e.g. +3.2 dB or −1.4 dB). Normalisation applies automatically during playback — you don't need to do anything.")
            HelpWarning(text: "Segue can only reduce gain to 0 dB (it cannot boost above AVAudioPlayer's maximum). Tracks that are already too quiet will show a positive dB value but may not reach the full target level.")

            HelpSubheading(text: "Tag colour")
            HelpBody(text: "Assign a colour via right-click › Tag Color. Choose from red, orange, yellow, green, blue, or purple. The colour appears as a left stripe and tints the title text. Clear removes the colour.")
        }
    }
}

private struct PausesBedsHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HelpHeading(text: "Pauses & Beds")

            HelpSubheading(text: "What is a pause?")
            HelpBody(text: "A pause is a special row that tells Segue to stop when it gets there. When playback reaches a pause, the current track ends and Segue waits. This is useful for live presenter segments, ad breaks, or any moment where you need to take control before the playlist continues.")
            HelpBody(text: "Press **Space** or **Next** (⌘→) to resume playback after a pause.")

            HelpSubheading(text: "Bed music")
            HelpBody(text: "You can assign a bed track to any pause. A bed is a music or ambient audio file that loops continuously while the pause is active. When playback reaches the pause, the bed fades in automatically.")
            HelpBody(text: "To assign a bed: right-click a pause row and choose **Assign Bed…**. Any supported audio format works (MP3, WAV, AIFF, M4A, FLAC, AAC, CAF, MP4). The filename appears next to the pause label.")
            HelpBody(text: "While a bed is playing you'll see a play/pause button next to the bed name in the ON AIR panel. Press **B** to toggle the bed without touching the mouse.")

            HelpSubheading(text: "Bed volume")
            HelpBody(text: "The default bed volume is set in **Settings** (⌘,). Adjust the Bed Volume slider to your preference. The setting applies to all beds.")

            HelpTip(text: "A common workflow: insert a pause before a news bulletin, assign a low-level music bed, let it loop during the bulletin, then press Space to continue the main playlist when the bulletin ends.")
        }
    }
}

private struct SessionManagementHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HelpHeading(text: "Session Management")

            HelpSubheading(text: "Played markers")
            HelpBody(text: "As tracks play, Segue marks them with a green checkmark and dims them slightly. These **played markers** let you see at a glance where you are in the show and how much of the playlist has run. The **Show Ends** clock calculation skips played tracks when the playlist is stopped.")

            HelpSubheading(text: "Reset Session (⇧⌘R)")
            HelpBody(text: "**Session › Reset Session** stops playback, clears all played markers, and resets the Show Ends calculation — but keeps your playlist intact. Use this to replay the same show or to do a rehearsal run before broadcast.")

            HelpSubheading(text: "Clear Playlist (⌘N)")
            HelpBody(text: "**File › New Playlist** removes all tracks and pauses from the playlist. This is permanent and cannot be undone. Export your playlist first if you want to keep it.")

            HelpSubheading(text: "Show Ends clock")
            HelpBody(text: "The Show Ends display in the control area estimates the wall-clock time when the playlist will finish, based on the remaining durations of unplayed tracks. It respects trim points.")
            HelpTip(text: "Show Ends is an estimate. Live mic segments (pauses) are not timed, so the estimate drifts whenever you stop for a presenter break.")

            HelpSubheading(text: "Play Log")
            HelpBody(text: "Segue keeps a timestamped log of every track event during your session: when tracks start, finish naturally, are skipped, or fade out. Open it via **Session › Show Play Log…**.")
            HelpBody(text: "The log is displayed in reverse-chronological order. Use **Export CSV…** to save it as a comma-separated file — useful for music licensing reports (APRA, PPL, BMI, etc.). The log is cleared when you quit the app or press **Clear** in the log sheet.")
            HelpTip(text: "Export the play log at the end of each show and archive it with the show recording. Licensing bodies typically require a track list with times to process your reporting.")

            HelpSubheading(text: "Auto-save")
            HelpBody(text: "Segue saves the playlist automatically every time you make a change. Your session is restored the next time you open the app, including file locations, trim points, crossfade settings, and tag colours.")
        }
    }
}

private struct FileManagementHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HelpHeading(text: "File Management")

            HelpSubheading(text: "Import and export")
            HelpBody(text: "Use **File › Export Playlist…** (⌘S) to save the current playlist as a JSON file. This file stores track locations, trim points, crossfade settings, tag colours, and normalization data — everything needed to restore your show on another machine.")
            HelpBody(text: "Use **File › Import Playlist…** (⌘L) to load a previously exported JSON file. This replaces the current playlist.")

            HelpSubheading(text: "Network volumes (SMB/NAS)")
            HelpBody(text: "Segue supports tracks stored on network drives. When a network drive is mounted, tracks on it play normally. If the network drive is not mounted when you open Segue, those tracks will show a yellow warning triangle but remain in the playlist. Reconnect the drive and Segue will pick them up without requiring a restart.")
            HelpWarning(text: "Segue will not prompt you to mount or authenticate a network drive — this is by design to avoid blocking the app during startup. If tracks are missing, connect the drive manually in Finder first.")

            HelpSubheading(text: "Supported formats")
            HelpBody(text: "Segue plays any format that macOS can decode. This includes:")
            VStack(alignment: .leading, spacing: 4) {
                HelpShortcutRow(key: "MP3",  description: ".mp3 — most common compressed format")
                HelpShortcutRow(key: "WAV",  description: ".wav — uncompressed PCM")
                HelpShortcutRow(key: "AIFF", description: ".aiff / .aif — Apple uncompressed, common in radio")
                HelpShortcutRow(key: "M4A",  description: ".m4a — iTunes / AAC in MPEG-4 container")
                HelpShortcutRow(key: "AAC",  description: ".aac — AAC standalone")
                HelpShortcutRow(key: "FLAC", description: ".flac — lossless compressed")
                HelpShortcutRow(key: "CAF",  description: ".caf — Core Audio Format (GarageBand etc.)")
                HelpShortcutRow(key: "MP4",  description: ".mp4 — audio in MPEG-4 container")
            }
            HelpBody(text: "All formats are supported equally for both tracks and bed music.")

            HelpSubheading(text: "Missing files")
            HelpBody(text: "A yellow triangle (⚠) appears next to any track whose file cannot be found. The track remains in the playlist and Segue will skip it during playback. Move the file back to its original location, or remove and re-add the track.")
        }
    }
}

private struct KeyboardShortcutsHelp: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HelpHeading(text: "Keyboard Shortcuts")

            HelpSubheading(text: "Playback")
            VStack(alignment: .leading, spacing: 4) {
                HelpShortcutRow(key: "Space",    description: "Play / Pause")
                HelpShortcutRow(key: "⌘ ←",     description: "Previous track")
                HelpShortcutRow(key: "⌘ →",     description: "Next track")
                HelpShortcutRow(key: "←",        description: "Seek back 5 seconds")
                HelpShortcutRow(key: "→",        description: "Seek forward 5 seconds")
                HelpShortcutRow(key: "⌘ .",      description: "Fade out and stop (3 seconds)")
                HelpShortcutRow(key: "⌘ E",      description: "Jump to 10 seconds before end")
                HelpShortcutRow(key: "B",         description: "Pause / resume bed")
            }

            HelpSubheading(text: "Files & Playlist")
            VStack(alignment: .leading, spacing: 4) {
                HelpShortcutRow(key: "⌘ O",       description: "Add audio files")
                HelpShortcutRow(key: "⌘ L",       description: "Import playlist from JSON")
                HelpShortcutRow(key: "⌘ S",       description: "Export playlist to JSON")
                HelpShortcutRow(key: "⌘ N",       description: "New playlist (clear all)")
            }

            HelpSubheading(text: "Session")
            VStack(alignment: .leading, spacing: 4) {
                HelpShortcutRow(key: "⇧ ⌘ R",    description: "Reset session (keep tracks, clear played)")
                HelpShortcutRow(key: "Session menu", description: "Show Play Log…")
            }

            HelpSubheading(text: "Track actions")
            VStack(alignment: .leading, spacing: 4) {
                HelpShortcutRow(key: "Double-click", description: "Play track immediately")
                HelpShortcutRow(key: "Right-click",  description: "Open track context menu")
            }

            HelpSubheading(text: "App")
            VStack(alignment: .leading, spacing: 4) {
                HelpShortcutRow(key: "⌘ ,",          description: "Settings")
                HelpShortcutRow(key: "⌘ /",          description: "Keyboard shortcuts panel")
                HelpShortcutRow(key: "?",             description: "Keyboard shortcuts panel")
            }

            HelpSubheading(text: "View")
            VStack(alignment: .leading, spacing: 4) {
                HelpShortcutRow(key: "View menu",     description: "Playlist at Bottom — toggle layout")
            }
            HelpTip(text: "Segue remembers the layout you choose. Controls-above-playlist suits a presenter who wants the broadcast panels front and centre; playlist-above-controls suits someone building and cueing the show.")
        }
    }
}
