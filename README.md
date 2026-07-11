# Segue

Broadcast audio playout for macOS. Segue manages a playlist of audio tracks for live radio, podcasts, and event production — with crossfade, trim, ramp timers, pause beds, loudness normalisation, and a timestamped play log.

**Requires macOS 26 (Tahoe) or later.**

---

## Features

- Playlist of audio tracks with drag-to-reorder
- Per-track crossfade (linear or equal-power curve, configurable duration)
- Per-track trim: set In and Out points with a waveform editor
- Ramp timer: on-air countdown to a cue point, displayed as time from the In point
- Loudness normalisation to −23 dBFS RMS (EBU R128) applied silently during playback
- Pause rows with optional looping bed music
- Colour tags for grouping tracks (jingles, ads, music, etc.)
- Show Ends clock: estimated finish time based on remaining track durations
- Timestamped play log, exportable as CSV for music licensing (APRA, PPL, BMI)
- Auto-save: playlist restores on next launch with all settings intact
- Import / export playlist as JSON for moving shows between machines
- Network drive (SMB / NAS) support via security-scoped bookmarks
- VU meters with peak hold on the ON AIR panel
- Undo / redo for playlist edits

---

## Installing

Download the latest `Segue-x.x.zip` from [Releases](https://github.com/pearcenuk/Segue/releases), unzip it, and drag `Segue.app` into your Applications folder.

> **First launch:** Segue is not notarized by Apple, so macOS will block it the first time. Right-click `Segue.app` and choose **Open**, then confirm. If that option doesn't appear, go to **System Settings › Privacy & Security** and click **Open Anyway**. You only need to do this once.

## Requirements

- macOS 26 (Tahoe) or later
- Xcode 26 or later (to build from source)

---

## Building from source

1. Clone the repository.
2. Open `Segue.xcodeproj` in Xcode.
3. Select the **Segue** scheme and your Mac as the run destination.
4. Press **⌘R** to build and run.

No third-party dependencies — Segue uses only Apple frameworks (SwiftUI, AVFoundation, Accelerate).

---

## Quick start

1. Press the **+** button in the toolbar, or use **File › Add Audio Files…** (`⌘O`), and select your audio files.
2. Reorder tracks by dragging the handle on the right of each row.
3. Press **Space** to begin playback. Segue advances through the playlist automatically.
4. The **ON AIR** panel shows the current track; **NEXT** shows what's coming.
5. Right-click any track to set crossfade, trim points, tag colour, or insert a pause.

---

## Track options

### Crossfade

Enable crossfade on a track via right-click › **Edit Track…**. When that track nears its end, Segue fades it out while simultaneously fading in the next track. A blue **CF** badge appears on crossfade-enabled rows.

Two curve shapes are available under **Settings** (`⌘,`):

| Curve | Behaviour |
|-------|-----------|
| Linear | Both tracks move in straight lines — simple and predictable |
| Equal Power | Sine/cosine volume curve — perceptually smoother, recommended for music |

### Trim

Set an In point (skip the start) and an Out point (stop early) using the waveform editor in **Edit Track…**. The progress scrubber and Show Ends calculation both honour trim points. An orange scissors badge marks trimmed tracks.

### Ramp timer

Set a cue point in the waveform editor. When the current track is playing, a countdown appears in the ON AIR panel showing the time remaining until the cue — measured from the In point. An orange timer badge on the row shows the same time at a glance. Use this to signal the presenter when to stop talking before the music comes up.

### Loudness normalisation

Segue calculates a gain adjustment per track to reach −23 dBFS RMS and applies it automatically during playback. No action is required. Tracks that are already above target are attenuated; tracks that are too quiet are boosted to the extent AVAudioPlayer allows (0 dB ceiling).

### Tag colours

Right-click › **Tag Color** to assign red, orange, yellow, green, blue, or purple. The colour appears as a left-edge stripe on the row and tints the title text.

---

## Pauses & beds

A pause row tells Segue to stop when playback reaches it. Press **Space** or **Next** (`⌘→`) to resume.

Assign a looping bed track to any pause via right-click › **Assign Bed…**. The bed fades in when the pause is reached and loops until you resume. Press **B** to toggle the bed without leaving the keyboard. Bed volume is set globally in **Settings**.

---

## Export and import

- **File › Export Playlist…** (`⌘S`) — save the current playlist as JSON. Stores track locations, trim points, crossfade settings, ramp timers, and tag colours.
- **File › Import Playlist…** (`⌘L`) — load a previously exported JSON file, replacing the current playlist.

Export before moving to a different machine. The JSON file is the complete show file.

---

## Network volumes

Segue supports audio files on mounted network drives (SMB, NAS). If a drive is unmounted when Segue opens, affected tracks show a yellow warning triangle but remain in the playlist. Mount the drive in Finder and Segue picks it up without a restart.

> Segue does not prompt you to connect a network drive at startup. Connect the drive manually in Finder if tracks are showing as missing.

---

## Supported formats

| Format | Extension | Notes |
|--------|-----------|-------|
| MP3    | `.mp3`    | Most common compressed format |
| WAV    | `.wav`    | Uncompressed PCM |
| AIFF   | `.aiff`, `.aif` | Apple uncompressed, common in radio |
| M4A    | `.m4a`    | AAC in MPEG-4 container |
| AAC    | `.aac`    | AAC standalone |
| FLAC   | `.flac`   | Lossless compressed |
| CAF    | `.caf`    | Core Audio Format |
| MP4    | `.mp4`    | Audio in MPEG-4 container |

All formats work for both tracks and bed music.

---

## Keyboard shortcuts

### Playback

| Key | Action |
|-----|--------|
| `Space` | Play / Pause |
| `⌘ ←` | Previous track |
| `⌘ →` | Next track |
| `←` | Seek back 5 seconds |
| `→` | Seek forward 5 seconds |
| `⌘ .` | Fade out and stop (3 seconds) |
| `⌘ E` | Jump to 10 seconds before end |
| `B` | Toggle bed play / pause |

### Files & playlist

| Key | Action |
|-----|--------|
| `⌘ O` | Add audio files |
| `⌘ L` | Import playlist from JSON |
| `⌘ S` | Export playlist to JSON |
| `⌘ N` | New playlist (clear all) |

### Session

| Key | Action |
|-----|--------|
| `⇧ ⌘ R` | Reset session — clear played markers, keep tracks |

### Track actions

| Key | Action |
|-----|--------|
| Double-click | Play track immediately |
| Right-click | Open track context menu |

### App

| Key | Action |
|-----|--------|
| `⌘ ,` | Settings |
| `⌘ /` or `?` | Keyboard shortcuts panel |

---

## Play log

Segue records a timestamped entry each time a track starts, ends, is skipped, or fades out. Open it via **Session › Show Play Log…**.

Export as CSV at the end of each show for music licensing submissions (APRA, PPL, BMI, and similar). The log clears when you quit or press **Clear** in the log sheet — export before closing.

---

## Session reset

**Session › Reset Session** (`⇧⌘R`) stops playback, clears all played markers, and resets the Show Ends calculation, but keeps your playlist intact. Use this to replay the same show or run a rehearsal.

---

## Licence

[MIT](LICENSE) — © 2025–2026 Neil Pearce
