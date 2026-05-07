//
//  ContentView.swift
//  PodPlayout
//
//  Created by Neil Pearce on 26/10/2025.
//

import SwiftUI
import AVFoundation
import Combine
import UniformTypeIdentifiers

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

// MARK: - Models

struct PauseItem: Identifiable, Equatable {
    let id = UUID()
    var bedBookmark: Data? = nil
    var bedURL: URL? = nil
    var bedNormalizeGain: Float? = nil   // linear gain to reach -23 dBFS RMS; nil = not yet scanned

    var bedFilename: String? { bedURL?.deletingPathExtension().lastPathComponent }

    static func == (lhs: PauseItem, rhs: PauseItem) -> Bool { lhs.id == rhs.id }
}

enum PlaylistItem: Identifiable, Equatable {
    case track(Track)
    case pause(PauseItem)

    var id: UUID {
        switch self {
        case .track(let t): return t.id
        case .pause(let p): return p.id
        }
    }

    var displayName: String {
        switch self {
        case .track(let t): return t.title
        case .pause: return "Pause"
        }
    }

    var isPause: Bool {
        if case .pause = self { return true } else { return false }
    }
}

struct Track: Identifiable, Equatable {
    let id = UUID()
    let url: URL

    var crossfadeEnabled: Bool = false
    var crossfadeDuration: TimeInterval = 1.0

    var usesDefaultCrossfadeEnabled: Bool = true
    var usesDefaultCrossfadeDuration: Bool = true

    var tagColor: RGBAColor? = nil
    var durationSeconds: TimeInterval? = nil
    var trimStart: TimeInterval = 0
    var trimEnd: TimeInterval? = nil
    var isMissing: Bool = false
    var normalizeGain: Float? = nil  // linear gain to reach -23 dBFS RMS target; nil = not yet scanned
    var cachedBookmark: Data? = nil  // last known-good bookmark; used as fallback when volume is unreachable

    var effectiveDuration: TimeInterval? {
        guard let d = durationSeconds else { return nil }
        return max(0, (trimEnd ?? d) - trimStart)
    }

    var title: String {
        url.deletingPathExtension().lastPathComponent
    }
}

extension Track {
    static func from(bookmarkData: Data) -> (Track, Bool)? {
        var isStale = false
        // .withoutUI prevents macOS from showing mount/credential dialogs for
        // network volumes (e.g. SMB) that are not currently mounted.
        if let url = try? URL(resolvingBookmarkData: bookmarkData, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale) {
            return (Track(url: url), isStale)
        }
        if let url = try? URL(resolvingBookmarkData: bookmarkData, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &isStale) {
            return (Track(url: url), isStale)
        }
        return nil
    }
    func makeBookmark() -> Data? {
        try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
    }
}

struct RGBAColor: Codable, Equatable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double
}

extension Color {
    init(_ rgba: RGBAColor) {
        self = Color(.sRGB, red: rgba.r, green: rgba.g, blue: rgba.b, opacity: rgba.a)
    }
}

extension RGBAColor {
    init(_ color: Color) {
        #if os(iOS)
        let ui = UIColor(color)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, &g, &b, &a)
        self.r = Double(r); self.g = Double(g); self.b = Double(b); self.a = Double(a)
        #elseif os(macOS)
        let ns = NSColor(color)
        let c = ns.usingColorSpace(.sRGB) ?? ns
        self.r = Double(c.redComponent)
        self.g = Double(c.greenComponent)
        self.b = Double(c.blueComponent)
        self.a = Double(c.alphaComponent)
        #else
        self.r = 0; self.g = 0; self.b = 0; self.a = 0
        #endif
    }
}

// MARK: - Play Log

enum PlayLogEvent: String, Codable {
    case started, finished, skipped, fadedOut

    var displayName: String {
        switch self {
        case .started:  return "Started"
        case .finished: return "Finished"
        case .skipped:  return "Skipped"
        case .fadedOut: return "Faded Out"
        }
    }

    var icon: String {
        switch self {
        case .started:  return "play.fill"
        case .finished: return "checkmark.circle.fill"
        case .skipped:  return "forward.end.fill"
        case .fadedOut: return "speaker.slash.fill"
        }
    }

    var color: Color {
        switch self {
        case .started:  return .green
        case .finished: return .accentColor
        case .skipped:  return .orange
        case .fadedOut: return .secondary
        }
    }
}

struct PlayLogEntry: Identifiable {
    let id = UUID()
    let timestamp: Date
    let trackTitle: String
    let event: PlayLogEvent
}

// MARK: - Crossfade Curve

enum CrossfadeCurve: String, Codable, CaseIterable {
    case linear
    case equalPower

    var displayName: String {
        switch self {
        case .linear:     return "Linear"
        case .equalPower: return "Equal Power"
        }
    }
}

// MARK: - DisplayLink Protocol & Platform Specifics

protocol CADisplayLinkLike {
    func invalidate()
}
#if os(iOS) || os(tvOS) || os(visionOS)
final class DisplayLinkBox: CADisplayLinkLike {
    private var link: CADisplayLink?
    init(_ callback: @escaping () -> Void) {
        let l = CADisplayLink(target: BlockTarget(callback), selector: #selector(BlockTarget.fire))
        l.add(to: .main, forMode: .common)
        self.link = l
    }
    func invalidate() { link?.invalidate() }
    private class BlockTarget: NSObject {
        let cb: () -> Void
        init(_ cb: @escaping () -> Void) { self.cb = cb }
        @objc func fire() { cb() }
    }
}
#else
final class DisplayLinkBox: CADisplayLinkLike {
    private var timer: Timer?
    init(_ callback: @escaping () -> Void) {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { _ in callback() }
        RunLoop.main.add(timer!, forMode: .common)
    }
    func invalidate() { timer?.invalidate() }
}
#endif

// MARK: - View Model

@MainActor
final class PlayoutViewModel: NSObject, ObservableObject {
    @Published var items: [PlaylistItem] = []
    @Published var currentIndex: Int? = nil
    @Published var isPlaying: Bool = false
    private var isCrossfading = false

    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var effectiveEnd: TimeInterval = 0
    @Published var currentTrimStart: TimeInterval = 0
    @Published var isNearingEnd: Bool = false
    
    @Published var defaultCrossfadeEnabled: Bool = false
    @Published var defaultCrossfadeDuration: TimeInterval = 1.0
    @Published var playedTrackIDs: Set<UUID> = []

    @Published var meterLevels: [Float] = [0, 0]
    @Published var meterPeaks: [Float] = [0, 0]
    private var peakHoldCounters: [Int] = [0, 0]

    @Published var scanningTrackIDs: Set<UUID> = []
    @Published var defaultBedVolume: Float = 0.4 {
        didSet { applyBedVolumeChange() }
    }

    // UI state that commands + toolbar both need to trigger
    @Published var showingSettings: Bool = false
    @Published var showingClearConfirm: Bool = false
    @Published var showingKeyboardShortcuts: Bool = false
    var lastExportDirectory: URL? = nil

    // Currently loaded playlist file name (without .json extension), nil when unsaved
    @Published var currentPlaylistName: String? = nil

    // Play log — timestamped record of track events
    @Published var playLog: [PlayLogEntry] = []
    @Published var showingPlayLog: Bool = false

    // Crossfade curve applied when fading between tracks
    @Published var crossfadeCurve: CrossfadeCurve = .linear

    // Seconds before the effective end at which the nearing-end warning fires
    @Published var nearingEndThreshold: TimeInterval = 30

    // Layout preference — persisted to UserDefaults (default: playlist at bottom)
    @Published var playlistAtBottom: Bool = {
        let ud = UserDefaults.standard
        // If the key has never been set, default to true (playlist at bottom)
        guard ud.object(forKey: "playlistAtBottom") != nil else { return true }
        return ud.bool(forKey: "playlistAtBottom")
    }() {
        didSet { UserDefaults.standard.set(playlistAtBottom, forKey: "playlistAtBottom") }
    }

    @Published var bedIsPlaying: Bool = false
    @Published var pauseEnteredAt: Date? = nil   // set when playback lands on a pause row
    private var bedPlayer: AVAudioPlayer? = nil
    private var bedScopedURL: URL? = nil
    private var currentBedTargetVolume: Float = 0.4   // normalised + scaled target for the active bed
    private var currentBedNormGain: Float = 1.0       // RMS normalisation factor for the current bed

    private var player: AVAudioPlayer?
    private var altPlayer: AVAudioPlayer?
    private var timeLink: CADisplayLinkLike?

    private var currentScopedURL: URL? = nil
    private var currentScopeActive: Bool = false

    private let storageKey = "playlist.bookmarks.v1"
    private let defaultsKey = "playlist.defaults.v1"

    // Load files — all formats AVAudioPlayer supports on macOS
    func addFiles(urls: [URL]) {
        insertFiles(urls: urls, at: items.count)
    }

    func insertFiles(urls: [URL], at index: Int) {
        let supported: Set<String> = ["mp3", "wav", "aiff", "aif", "m4a", "flac", "aac", "caf", "mp4"]
        let newItems: [PlaylistItem] = urls
            .filter { supported.contains($0.pathExtension.lowercased()) }
            .map { url in
                var t = Track(url: url)
                t.crossfadeEnabled = self.defaultCrossfadeEnabled
                t.crossfadeDuration = self.defaultCrossfadeDuration
                t.usesDefaultCrossfadeEnabled = true
                t.usesDefaultCrossfadeDuration = true
                let asset = AVURLAsset(url: url)
                let seconds = CMTimeGetSeconds(asset.duration)
                if seconds.isFinite && seconds > 0 { t.durationSeconds = seconds }
                return PlaylistItem.track(t)
            }
        guard !newItems.isEmpty else { return }
        let safeIndex = max(0, min(index, items.count))
        items.insert(contentsOf: newItems, at: safeIndex)
        savePlaylist()
        let newIDs = newItems.compactMap { if case .track(let t) = $0 { return t.id } else { return nil } }
        scanTracks(newIDs)
    }

    func resetSession() {
        stopPlayback()
        stopBed(fadeDuration: 0.3)
        playedTrackIDs.removeAll()
    }

    func addPause(at index: Int? = nil) {
        if let index, items.indices.contains(index) {
            items.insert(.pause(PauseItem()), at: index)
        } else {
            items.append(.pause(PauseItem()))
        }
        savePlaylist()
    }

    func remove(atOffsets offsets: IndexSet) {
        if let current = currentIndex, offsets.contains(current) {
            stopPlayback()
            stopBed(fadeDuration: 0.3)
        }
        let currentID: UUID? = currentIndex.flatMap { offsets.contains($0) ? nil : items[$0].id }
        items.remove(atOffsets: offsets)
        currentIndex = currentID.flatMap { id in items.firstIndex(where: { $0.id == id }) }
        savePlaylist()
    }

    func move(from source: IndexSet, to destination: Int) {
        let currentID = currentIndex.flatMap { items.indices.contains($0) ? items[$0].id : nil }
        items.move(fromOffsets: source, toOffset: destination)
        if let id = currentID {
            currentIndex = items.firstIndex(where: { $0.id == id })
        }
        savePlaylist()
    }

    private func markCurrentAsPlayed() {
        if let idx = currentIndex, case .track(let t) = items[idx] {
            playedTrackIDs.insert(t.id)
        }
    }

    private func appendLog(trackTitle: String, event: PlayLogEvent) {
        playLog.append(PlayLogEntry(timestamp: Date(), trackTitle: trackTitle, event: event))
    }

    func play(at index: Int? = nil) {
        // Mark current track as played when switching to a different one
        if let newIdx = index, newIdx != currentIndex { markCurrentAsPlayed() }
        // If an index provided, set it
        if let idx = index { currentIndex = idx }
        guard let idx = currentIndex ?? items.indices.first else { return }
        currentIndex = idx

        let item = items[idx]
        switch item {
        case .pause(let p):
            stopPlayback(keepIndex: true)
            startBed(for: p)
            pauseEnteredAt = Date()
        case .track(let track):
            startPlayback(url: track.url)
        }
    }

    func togglePlayPause() {
        // When sitting on a pause item, Space ends the pause and plays next
        if let idx = currentIndex, case .pause = items[idx] {
            stopBed()
            next()
            return
        }
        if isPlaying {
            pause()
        } else {
            // If we have a paused player, resume it instead of restarting
            if let p = player {
                p.play()
                isPlaying = true
                startTimeUpdates()
                let resumeVol: Float
                if let idx = currentIndex, case .track(let t) = items[idx] {
                    resumeVol = normVolume(for: t)
                } else {
                    resumeVol = 1.0
                }
                fade(to: resumeVol)
            } else {
                // No player exists, start fresh
                if currentIndex == nil { currentIndex = items.isEmpty ? nil : 0 }
                play()
            }
        }
    }

    func pause() {
        fade(to: 0.0, duration: 0.3) {
            self.player?.pause()
            self.isPlaying = false
        }
    }

    func stopPlayback(keepIndex: Bool = false) {
        pauseEnteredAt = nil
        fade(to: 0.0, duration: 0.2) {
            self.player?.stop()
            self.player = nil
            self.altPlayer?.stop()
            self.altPlayer = nil
            self.endScopedAccess()
            self.isPlaying = false
            if !keepIndex { self.currentIndex = nil }
            self.stopTimeUpdates(resetDisplay: true)
        }
    }

    func next() {
        guard let idx = currentIndex else { return }
        markCurrentAsPlayed()
        let nextIdx = idx + 1
        if items.indices.contains(nextIdx) {
            currentIndex = nextIdx
            play()
        } else {
            stopPlayback()
        }
    }

    func previous() {
        guard let idx = currentIndex else { return }
        markCurrentAsPlayed()
        let prevIdx = max(0, idx - 1)
        if items.indices.contains(prevIdx) {
            fade(to: 0.0, duration: 0.2) {
                self.player?.stop()
                self.player = nil
                self.isPlaying = false
                self.stopTimeUpdates()
                self.currentIndex = prevIdx
                self.play()
            }
        }
    }

    /// Called when the user manually presses Next — logs a skip event, then advances.
    /// If the current track has crossfade enabled and we're actively playing,
    /// the manual skip uses the crossfade transition instead of a hard cut.
    func nextManual() {
        guard let idx = currentIndex else { next(); return }

        // If sitting on a pause, fade the bed out before advancing —
        // mirrors the Space-bar path in togglePlayPause().
        if case .pause = items[idx] {
            stopBed()
            next()
            return
        }

        if case .track(let current) = items[idx] {
            appendLog(trackTitle: current.title, event: .skipped)

            let nextIdx = idx + 1
            if items.indices.contains(nextIdx) {

                // Next item is a pause — fade out properly then start bed
                if case .pause(let p) = items[nextIdx], isPlaying {
                    markCurrentAsPlayed()
                    currentIndex = nextIdx
                    pauseEnteredAt = Date()
                    stopTimeUpdates()
                    isPlaying = false
                    fade(to: 0.0, duration: 0.8) {
                        self.player?.stop()
                        self.player = nil
                        self.endScopedAccess()
                        self.startBed(for: p)
                    }
                    return
                }

                // Next item is a track with crossfade enabled
                if isPlaying, current.crossfadeEnabled, !isCrossfading,
                   case .track(let incoming) = items[nextIdx] {
                    isCrossfading = true
                    markCurrentAsPlayed()
                    currentIndex = nextIdx
                    crossfadeTo(url: incoming.url,
                                duration: max(0.1, current.crossfadeDuration),
                                targetVolume: normVolume(for: incoming))
                    DispatchQueue.main.asyncAfter(deadline: .now() + current.crossfadeDuration + 0.1) {
                        self.isCrossfading = false
                    }
                    return
                }
            }
        }

        next()
    }

    /// Called when the user manually presses Previous — logs a skip event, then goes back.
    func previousManual() {
        if let idx = currentIndex, case .track(let t) = items[idx] {
            appendLog(trackTitle: t.title, event: .skipped)
        }
        previous()
    }

    func seek(to time: TimeInterval) {
        guard let p = player else { return }
        p.currentTime = max(0, min(time, p.duration))
        currentTime = p.currentTime
    }

    func seekBackward(by seconds: TimeInterval = 5) {
        guard let p = player else { return }
        let lower = currentTrimStart
        p.currentTime = max(lower, p.currentTime - seconds)
        currentTime = p.currentTime
    }

    func seekForward(by seconds: TimeInterval = 5) {
        guard let p = player else { return }
        let upper = effectiveEnd > 0 ? effectiveEnd : p.duration
        p.currentTime = min(upper, p.currentTime + seconds)
        currentTime = p.currentTime
    }

    func fadeOut(duration: TimeInterval = 3.0) {
        if let idx = currentIndex, case .track(let t) = items[idx] {
            appendLog(trackTitle: t.title, event: .fadedOut)
        }
        fade(to: 0.0, duration: duration) {
            self.player?.stop()
            self.player = nil
            self.altPlayer?.stop()
            self.altPlayer = nil
            self.endScopedAccess()
            self.isPlaying = false
            self.stopTimeUpdates(resetDisplay: true)
        }
    }

    func seekToNearEnd(secondsFromEnd: TimeInterval = 10) {
        guard let p = player else { return }
        let end: TimeInterval
        if let idx = currentIndex, case .track(let t) = items[idx], let trimEnd = t.trimEnd {
            end = trimEnd
        } else {
            end = p.duration
        }
        p.currentTime = max(0, end - secondsFromEnd)
        currentTime = p.currentTime
    }

    private func beginScopedAccess(for url: URL) {
        endScopedAccess()
        #if os(iOS) || os(macOS)
        currentScopedURL = url
        currentScopeActive = url.startAccessingSecurityScopedResource()
        #endif
    }

    private func endScopedAccess() {
        #if os(iOS) || os(macOS)
        if currentScopeActive, let u = currentScopedURL {
            u.stopAccessingSecurityScopedResource()
        }
        currentScopedURL = nil
        currentScopeActive = false
        #endif
    }

    private func startPlayback(url: URL) {
#if os(iOS) || os(tvOS) || os(visionOS)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            // Non-fatal for macOS, required for iOS
        }
#endif
        beginScopedAccess(for: url)
        do {
            player = try AVAudioPlayer(contentsOf: url)
            player?.delegate = self
            player?.isMeteringEnabled = true
            player?.prepareToPlay()
            player?.volume = 0
            let targetVol: Float
            if let idx = currentIndex, case .track(let t) = items[idx] {
                if t.trimStart > 0 { player?.currentTime = t.trimStart }
                targetVol = normVolume(for: t)
            } else {
                targetVol = 1.0
            }
            player?.play()
            isPlaying = true
            startTimeUpdates()
            fade(to: targetVol)
            // Log start event
            if let idx = currentIndex, case .track(let t) = items[idx] {
                appendLog(trackTitle: t.title, event: .started)
            }
        } catch {
            print("Failed to play: \(error)")
            isPlaying = false
        }
    }

    private func makePlayer(url: URL, volume: Float) throws -> AVAudioPlayer {
        beginScopedAccess(for: url)
        let p = try AVAudioPlayer(contentsOf: url)
        p.delegate = self
        p.isMeteringEnabled = true
        p.prepareToPlay()
        p.volume = volume
        return p
    }

    private static func dbToNorm(_ db: Float, floor: Float = -60) -> Float {
        guard db > floor else { return 0 }
        return (db - floor) / (-floor)
    }

    private func normVolume(for track: Track) -> Float {
        guard let g = track.normalizeGain else { return 1.0 }
        return min(1.0, g)  // AVAudioPlayer can't exceed 1.0, so we cut but never boost
    }

    func scanTracks(_ ids: [UUID]) {
        for id in ids { scanTrack(id) }
    }

    private func scanTrack(_ trackID: UUID) {
        guard !scanningTrackIDs.contains(trackID),
              let idx = items.firstIndex(where: { $0.id == trackID }),
              case .track(let t) = items[idx],
              t.normalizeGain == nil else { return }
        scanningTrackIDs.insert(trackID)
        let url = t.url
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            let accessing = url.startAccessingSecurityScopedResource()
            let gain = self.computeNormalizeGain(url: url)
            if accessing { url.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                guard let idx = self.items.firstIndex(where: { $0.id == trackID }),
                      case .track(var track) = self.items[idx] else {
                    self.scanningTrackIDs.remove(trackID)
                    return
                }
                track.normalizeGain = gain
                self.items[idx] = .track(track)
                self.scanningTrackIDs.remove(trackID)
                if gain != nil { self.savePlaylist() }
            }
        }
    }

    private func scanBed(pauseID: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == pauseID }),
              case .pause(let p) = items[idx],
              let url = p.bedURL,
              p.bedNormalizeGain == nil else { return }
        let urlCopy = url
        DispatchQueue.global(qos: .background).async { [weak self] in
            guard let self else { return }
            let accessing = urlCopy.startAccessingSecurityScopedResource()
            let gain = self.computeNormalizeGain(url: urlCopy)
            if accessing { urlCopy.stopAccessingSecurityScopedResource() }
            DispatchQueue.main.async {
                guard let idx = self.items.firstIndex(where: { $0.id == pauseID }),
                      case .pause(var p) = self.items[idx] else { return }
                p.bedNormalizeGain = gain
                self.items[idx] = .pause(p)
                self.savePlaylist()
            }
        }
    }

    private func computeNormalizeGain(url: URL) -> Float? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let format = file.processingFormat
        let chunkFrames: AVAudioFrameCount = 44100
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: chunkFrames) else { return nil }
        var sumSquares: Double = 0
        var totalSamples: Int = 0
        let channelCount = Int(format.channelCount)
        while file.framePosition < file.length {
            let remaining = AVAudioFrameCount(file.length - file.framePosition)
            let toRead = min(chunkFrames, remaining)
            buffer.frameLength = toRead
            guard (try? file.read(into: buffer, frameCount: toRead)) != nil,
                  let floatData = buffer.floatChannelData else { break }
            for ch in 0..<channelCount {
                for i in 0..<Int(toRead) {
                    let s = Double(floatData[ch][i])
                    sumSquares += s * s
                }
            }
            totalSamples += Int(toRead) * channelCount
        }
        guard totalSamples > 0 else { return nil }
        let rms = sqrt(sumSquares / Double(totalSamples))
        guard rms > 1e-10 else { return nil }
        let gainDB = -23.0 - 20.0 * log10(rms)  // how many dB to shift to reach -23 dBFS RMS
        return Float(pow(10.0, gainDB / 20.0))
    }

    private func crossfadeTo(url: URL, duration: TimeInterval, targetVolume: Float = 1.0) {
        guard let current = player else { startPlayback(url: url); return }
        do {
            let next = try makePlayer(url: url, volume: 0)
            altPlayer = next
            next.play()
            let startVolume = current.volume
            let steps = max(1, Int(duration * 30))
            let stepDuration = duration / Double(steps)
            let curve = crossfadeCurve   // capture at start of fade
            var i = 0
            Timer.scheduledTimer(withTimeInterval: stepDuration, repeats: true) { timer in
                i += 1
                let progress = min(1.0, Double(i) / Double(steps))
                let (fadeOut, fadeIn): (Double, Double)
                switch curve {
                case .linear:
                    fadeOut = 1.0 - progress
                    fadeIn  = progress
                case .equalPower:
                    fadeOut = cos(progress * .pi / 2)
                    fadeIn  = sin(progress * .pi / 2)
                }
                current.volume = startVolume * Float(fadeOut)
                next.volume    = targetVolume * Float(fadeIn)
                if i >= steps {
                    timer.invalidate()
                    current.stop()
                    self.player = next
                    self.beginScopedAccess(for: url)
                    self.altPlayer = nil
                    self.isPlaying = true
                    self.startTimeUpdates()
                    // Log the incoming track as started
                    if let idx = self.currentIndex, case .track(let trk) = self.items[idx] {
                        self.appendLog(trackTitle: trk.title, event: .started)
                    }
                }
            }
        } catch {
            // Fallback to normal start
            startPlayback(url: url)
        }
    }

    private func fade(_ p: AVAudioPlayer, to target: Float, duration: TimeInterval = 0.5, completion: (() -> Void)? = nil) {
        let steps = max(1, Int(duration * 30))
        let stepDuration = duration / Double(steps)
        let start = p.volume
        let delta = target - start
        var i = 0
        Timer.scheduledTimer(withTimeInterval: stepDuration, repeats: true) { timer in
            i += 1
            let t = min(1.0, Double(i)/Double(steps))
            p.volume = start + Float(t) * delta
            if i >= steps {
                timer.invalidate()
                completion?()
            }
        }
    }

    private func fade(to target: Float, duration: TimeInterval = 0.5, completion: (() -> Void)? = nil) {
        guard let p = player else { completion?(); return }
        fade(p, to: target, duration: duration, completion: completion)
    }

    // MARK: - Bed player

    func startBed(for pause: PauseItem) {
        guard let url = pause.bedURL else { return }
        stopBed(fadeDuration: 0.2)
        bedScopedURL?.stopAccessingSecurityScopedResource()
        if url.startAccessingSecurityScopedResource() { bedScopedURL = url }
        guard let p = try? AVAudioPlayer(contentsOf: url) else {
            bedScopedURL?.stopAccessingSecurityScopedResource(); bedScopedURL = nil; return
        }
        p.numberOfLoops = -1
        p.volume = 0
        p.prepareToPlay()
        p.play()
        bedPlayer = p
        bedIsPlaying = true
        // Normalise: bring bed to -23 dBFS, then scale by the bed-volume preference.
        currentBedNormGain = pause.bedNormalizeGain.map { min(1.0, $0) } ?? 1.0
        currentBedTargetVolume = min(1.0, currentBedNormGain * defaultBedVolume)
        fade(p, to: currentBedTargetVolume, duration: 1.5)
    }

    func stopBed(fadeDuration: TimeInterval = 1.5) {
        guard let b = bedPlayer else { return }
        bedPlayer = nil
        bedIsPlaying = false
        fade(b, to: 0, duration: fadeDuration) {
            b.stop()
            self.bedScopedURL?.stopAccessingSecurityScopedResource()
            self.bedScopedURL = nil
        }
    }

    func toggleBed() {
        guard let b = bedPlayer else { return }
        if b.isPlaying {
            bedIsPlaying = false
            fade(b, to: 0, duration: 2.0) { b.pause() }
        } else {
            b.volume = 0
            b.play()
            bedIsPlaying = true
            fade(b, to: currentBedTargetVolume, duration: 2.0)
        }
    }

    private func applyBedVolumeChange() {
        // Recalculate the target using the stored norm gain and new defaultBedVolume.
        currentBedTargetVolume = min(1.0, currentBedNormGain * defaultBedVolume)
        // Only update the live player if the bed is audible right now.
        guard let b = bedPlayer, bedIsPlaying else { return }
        fade(b, to: currentBedTargetVolume, duration: 0.3)
    }

    func assignBed(url: URL, to index: Int) {
        guard items.indices.contains(index), case .pause(var p) = items[index] else { return }
        p.bedBookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        p.bedURL = url
        p.bedNormalizeGain = nil   // reset so the new file gets scanned
        items[index] = .pause(p)
        savePlaylist()
        scanBed(pauseID: p.id)
    }

    func removeBed(at index: Int) {
        guard items.indices.contains(index), case .pause(var p) = items[index] else { return }
        p.bedBookmark = nil
        p.bedURL = nil
        items[index] = .pause(p)
        savePlaylist()
        if currentIndex == index { stopBed() }
    }

    private func startTimeUpdates() {
        stopTimeUpdates()
        timeLink = DisplayLinkBox { [weak self] in
            guard let self, let p = self.player else { return }
            self.currentTime = p.currentTime
            self.duration = p.duration

            // Meter levels
            p.updateMeters()
            let chCount = p.numberOfChannels
            if self.meterLevels.count != chCount {
                self.meterLevels = [Float](repeating: 0, count: chCount)
                self.meterPeaks = [Float](repeating: 0, count: chCount)
                self.peakHoldCounters = [Int](repeating: 0, count: chCount)
            }
            for ch in 0..<chCount {
                let lvl = Self.dbToNorm(p.averagePower(forChannel: ch))
                if lvl >= self.meterPeaks[ch] {
                    self.meterPeaks[ch] = lvl
                    self.peakHoldCounters[ch] = 45
                } else if self.peakHoldCounters[ch] > 0 {
                    self.peakHoldCounters[ch] -= 1
                } else {
                    self.meterPeaks[ch] = max(0, self.meterPeaks[ch] - 0.018)
                }
                self.meterLevels[ch] = lvl
            }

            // Effective end and trim start offset
            if let idx = self.currentIndex, case .track(let t) = self.items[idx] {
                self.currentTrimStart = t.trimStart
                self.effectiveEnd = t.trimEnd ?? self.duration
            } else {
                self.currentTrimStart = 0
                self.effectiveEnd = self.duration
            }
            let remaining = max(0, self.effectiveEnd - self.currentTime)
            self.isNearingEnd = remaining > 0 && remaining <= self.nearingEndThreshold

            // Early-out: trim end reached
            if let idx = self.currentIndex, case .track(let t) = self.items[idx], let trimEnd = t.trimEnd {
                if self.currentTime >= trimEnd && !self.isCrossfading {
                    self.next()
                    return
                }
            }

            if !self.isCrossfading, let idx = self.currentIndex {
                let nextIdx = idx + 1
                if remaining <= 0.05 { return } // let delegate handle natural end
                if case .track(let current) = self.items[idx], current.crossfadeEnabled,
                   self.items.indices.contains(nextIdx), case .track(let incoming) = self.items[nextIdx] {
                    if remaining <= current.crossfadeDuration {
                        self.isCrossfading = true
                        self.markCurrentAsPlayed()
                        self.currentIndex = nextIdx
                        self.crossfadeTo(url: incoming.url, duration: max(0.1, current.crossfadeDuration), targetVolume: self.normVolume(for: incoming))
                        DispatchQueue.main.asyncAfter(deadline: .now() + current.crossfadeDuration + 0.1) {
                            self.isCrossfading = false
                        }
                    }
                }
            }
        }
    }
    private func stopTimeUpdates(resetDisplay: Bool = false) {
        timeLink?.invalidate()
        timeLink = nil
        if resetDisplay {
            currentTime = 0
            duration = 0
            effectiveEnd = 0
            currentTrimStart = 0
        }
        isNearingEnd = false
        meterLevels = [0, 0]
        meterPeaks = [0, 0]
        peakHoldCounters = [0, 0]
    }

    func loadPersistedPlaylist() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        do {
            let decoded = try JSONDecoder().decode([PersistedItem].self, from: data)
            var rebuilt: [PlaylistItem] = []
            var anyStale = false
            for item in decoded {
                switch item {
                case .pause(let bundle):
                    var p = PauseItem()
                    if let bm = bundle.bedBookmark {
                        var stale = false
                        if let url = try? URL(resolvingBookmarkData: bm, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                            p.bedBookmark = stale ? nil : bm
                            p.bedURL = url
                        }
                    }
                    if p.bedURL == nil, let path = bundle.bedPath {
                        let url = URL(fileURLWithPath: path)
                        if FileManager.default.fileExists(atPath: path) {
                            p.bedURL = url
                            p.bedBookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                        }
                    }
                    p.bedNormalizeGain = bundle.bedNormalizeGain
                    rebuilt.append(.pause(p))
                case .track(let bundle):
                    let resolved = Track.from(bookmarkData: bundle.bookmark)
                    let baseTrack: Track?
                    let isStaleBookmark: Bool
                    if let (t, stale) = resolved {
                        baseTrack = t
                        isStaleBookmark = stale
                    } else if let path = bundle.filePath {
                        baseTrack = Track(url: URL(fileURLWithPath: path))
                        isStaleBookmark = false
                    } else {
                        baseTrack = nil
                        isStaleBookmark = false
                    }
                    if var t = baseTrack {
                        t.cachedBookmark = bundle.bookmark
                        t.crossfadeEnabled = bundle.crossfadeEnabled
                        t.crossfadeDuration = bundle.crossfadeDuration
                        // Use defaults if flags are absent in older persisted data (default true)
                        t.usesDefaultCrossfadeEnabled = bundle.usesDefaultCrossfadeEnabled
                        t.usesDefaultCrossfadeDuration = bundle.usesDefaultCrossfadeDuration
                        t.tagColor = bundle.tagColor
                        t.durationSeconds = bundle.durationSeconds ?? t.durationSeconds
                        t.trimStart = bundle.trimStart
                        t.trimEnd = bundle.trimEnd
                        t.normalizeGain = bundle.normalizeGain
                        let accessing = t.url.startAccessingSecurityScopedResource()
                        t.isMissing = !FileManager.default.fileExists(atPath: t.url.path)
                        if accessing { t.url.stopAccessingSecurityScopedResource() }
                        if !t.isMissing && t.durationSeconds == nil {
                            let asset = AVURLAsset(url: t.url)
                            let seconds = CMTimeGetSeconds(asset.duration)
                            if seconds.isFinite && seconds > 0 { t.durationSeconds = seconds }
                        }
                        rebuilt.append(.track(t))
                        if isStaleBookmark { anyStale = true }
                    }
                }
            }
            items = rebuilt
            let hasMissing = rebuilt.contains { if case .track(let t) = $0 { return t.isMissing } else { return false } }
            // Only save when every decoded item loaded successfully (nothing dropped, no missing files).
            // This migrates old playlists to include filePath while SMB is mounted.
            // If rebuilt.count < decoded.count some bookmarks failed with no path fallback —
            // don't save or we'll overwrite the saved data with a truncated/empty playlist.
            if !hasMissing && rebuilt.count == decoded.count { savePlaylist() }
            let unscanned = rebuilt.compactMap { item -> UUID? in
                if case .track(let t) = item, t.normalizeGain == nil, !t.isMissing { return t.id }
                return nil
            }
            if !unscanned.isEmpty { scanTracks(unscanned) }
            let unscannedBeds = rebuilt.compactMap { item -> UUID? in
                if case .pause(let p) = item, p.bedURL != nil, p.bedNormalizeGain == nil { return p.id }
                return nil
            }
            unscannedBeds.forEach { scanBed(pauseID: $0) }
        } catch { print("Failed to load playlist: \(error)") }
    }
    
    func loadDefaults() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(DefaultsBundle.self, from: data) {
            defaultCrossfadeEnabled  = decoded.crossfadeEnabled
            defaultCrossfadeDuration = decoded.crossfadeDuration
            nearingEndThreshold      = decoded.nearingEndThreshold
            crossfadeCurve           = decoded.crossfadeCurve
        }
        let saved = UserDefaults.standard.float(forKey: "defaultBedVolume")
        defaultBedVolume = saved > 0 ? saved : 0.4
    }

    func saveDefaults() {
        let bundle = DefaultsBundle(
            crossfadeEnabled:    defaultCrossfadeEnabled,
            crossfadeDuration:   defaultCrossfadeDuration,
            nearingEndThreshold: nearingEndThreshold,
            crossfadeCurve:      crossfadeCurve
        )
        if let data = try? JSONEncoder().encode(bundle) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        UserDefaults.standard.set(defaultBedVolume, forKey: "defaultBedVolume")
    }

    func savePlaylist() {
        let persisted: [PersistedItem] = items.compactMap { item in
            switch item {
            case .pause(let p): return .pause(PausePersisted(bedBookmark: p.bedBookmark, bedPath: p.bedURL?.path, bedNormalizeGain: p.bedNormalizeGain))
            case .track(let t):
                if let bm = t.makeBookmark() ?? t.cachedBookmark {
                    return .track(BookmarkWithSettings(
                        bookmark: bm,
                        filePath: t.url.path,
                        crossfadeEnabled: t.crossfadeEnabled,
                        crossfadeDuration: t.crossfadeDuration,
                        usesDefaultCrossfadeEnabled: t.usesDefaultCrossfadeEnabled,
                        usesDefaultCrossfadeDuration: t.usesDefaultCrossfadeDuration,
                        tagColor: t.tagColor,
                        durationSeconds: t.durationSeconds,
                        trimStart: t.trimStart,
                        trimEnd: t.trimEnd,
                        normalizeGain: t.normalizeGain
                    ))
                } else { return nil }
            }
        }
        do {
            let data = try JSONEncoder().encode(persisted)
            UserDefaults.standard.set(data, forKey: storageKey)
        } catch { print("Failed to save playlist: \(error)") }
    }

    // MARK: - Panel functions (called from menu bar or toolbar)

    /// All audio formats AVAudioPlayer supports on macOS 13+.
    /// Built-in UTType constants cover MP3/WAV/AIFF/M4A; the rest are resolved by extension.
    static var audioContentTypes: [UTType] {
        [.mp3, .wav, .aiff, .mpeg4Audio] +
        ["flac", "aac", "caf", "mp4"].compactMap { UTType(filenameExtension: $0) }
    }

    func openTrackPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.audioContentTypes
        guard panel.runModal() == .OK else { return }
        addFiles(urls: panel.urls)
        savePlaylist()
    }

    func openImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["json"]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        do {
            try importPlaylistData(data)
            currentPlaylistName = url.deletingPathExtension().lastPathComponent
        } catch { /* ignore */ }
    }

    func openExportPanel() {
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["json"]
        panel.nameFieldStringValue = (currentPlaylistName ?? "playlist") + ".json"
        if let dir = lastExportDirectory { panel.directoryURL = dir }
        guard panel.runModal() == .OK, let url = panel.url,
              let data = exportPlaylistData() else { return }
        do {
            let dir = url.deletingLastPathComponent()
            let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).json")
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: tmp, to: url)
            lastExportDirectory = dir
            currentPlaylistName = url.deletingPathExtension().lastPathComponent
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func clearPlaylist() {
        stopPlayback()
        stopBed()
        items.removeAll()
        currentIndex = nil
        currentPlaylistName = nil
        savePlaylist()
    }

    // MARK: - File-based import/export
    func exportPlaylistData() -> Data? {
        let persisted: [PersistedItem] = items.compactMap { item in
            switch item {
            case .pause(let p): return .pause(PausePersisted(bedBookmark: p.bedBookmark, bedPath: p.bedURL?.path, bedNormalizeGain: p.bedNormalizeGain))
            case .track(let t):
                if let bm = t.makeBookmark() ?? t.cachedBookmark {
                    return .track(BookmarkWithSettings(
                        bookmark: bm,
                        filePath: t.url.path,
                        crossfadeEnabled: t.crossfadeEnabled,
                        crossfadeDuration: t.crossfadeDuration,
                        usesDefaultCrossfadeEnabled: t.usesDefaultCrossfadeEnabled,
                        usesDefaultCrossfadeDuration: t.usesDefaultCrossfadeDuration,
                        tagColor: t.tagColor,
                        durationSeconds: t.durationSeconds,
                        trimStart: t.trimStart,
                        trimEnd: t.trimEnd,
                        normalizeGain: t.normalizeGain
                    ))
                } else { return nil }
            }
        }
        return try? JSONEncoder().encode(persisted)
    }

    func importPlaylistData(_ data: Data) throws {
        let decoded = try JSONDecoder().decode([PersistedItem].self, from: data)
        var rebuilt: [PlaylistItem] = []
        for item in decoded {
            switch item {
            case .pause(let bundle):
                var p = PauseItem()
                if let bm = bundle.bedBookmark {
                    var stale = false
                    if let url = try? URL(resolvingBookmarkData: bm, options: [.withSecurityScope, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale) {
                        p.bedBookmark = stale ? nil : bm
                        p.bedURL = url
                    }
                }
                if p.bedURL == nil, let path = bundle.bedPath {
                    let url = URL(fileURLWithPath: path)
                    if FileManager.default.fileExists(atPath: path) {
                        p.bedURL = url
                        p.bedBookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
                    }
                }
                p.bedNormalizeGain = bundle.bedNormalizeGain
                rebuilt.append(.pause(p))
            case .track(let bundle):
                let resolved = Track.from(bookmarkData: bundle.bookmark)
                let baseTrack: Track?
                if let (t, _) = resolved {
                    baseTrack = t
                } else if let path = bundle.filePath {
                    baseTrack = Track(url: URL(fileURLWithPath: path))
                } else {
                    baseTrack = nil
                }
                if var t = baseTrack {
                    t.cachedBookmark = bundle.bookmark
                    t.crossfadeEnabled = bundle.crossfadeEnabled
                    t.crossfadeDuration = bundle.crossfadeDuration
                    t.usesDefaultCrossfadeEnabled = bundle.usesDefaultCrossfadeEnabled
                    t.usesDefaultCrossfadeDuration = bundle.usesDefaultCrossfadeDuration
                    t.tagColor = bundle.tagColor
                    t.durationSeconds = bundle.durationSeconds
                    t.trimStart = bundle.trimStart
                    t.trimEnd = bundle.trimEnd
                    t.normalizeGain = bundle.normalizeGain
                    t.isMissing = !FileManager.default.fileExists(atPath: t.url.path)
                    rebuilt.append(.track(t))
                }
            }
        }
        self.items = rebuilt
        savePlaylist()
        let unscannedBeds = rebuilt.compactMap { item -> UUID? in
            if case .pause(let p) = item, p.bedURL != nil, p.bedNormalizeGain == nil { return p.id }
            return nil
        }
        unscannedBeds.forEach { scanBed(pauseID: $0) }
    }

    struct BookmarkWithSettings: Codable {
        let bookmark: Data
        let filePath: String?
        let crossfadeEnabled: Bool
        let crossfadeDuration: TimeInterval
        let usesDefaultCrossfadeEnabled: Bool
        let usesDefaultCrossfadeDuration: Bool
        let tagColor: RGBAColor?
        let durationSeconds: TimeInterval?
        let trimStart: TimeInterval
        let trimEnd: TimeInterval?
        let normalizeGain: Float?

        init(bookmark: Data, filePath: String? = nil, crossfadeEnabled: Bool, crossfadeDuration: TimeInterval, usesDefaultCrossfadeEnabled: Bool, usesDefaultCrossfadeDuration: Bool, tagColor: RGBAColor?, durationSeconds: TimeInterval?, trimStart: TimeInterval = 0, trimEnd: TimeInterval? = nil, normalizeGain: Float? = nil) {
            self.bookmark = bookmark
            self.filePath = filePath
            self.crossfadeEnabled = crossfadeEnabled
            self.crossfadeDuration = crossfadeDuration
            self.usesDefaultCrossfadeEnabled = usesDefaultCrossfadeEnabled
            self.usesDefaultCrossfadeDuration = usesDefaultCrossfadeDuration
            self.tagColor = tagColor
            self.durationSeconds = durationSeconds
            self.trimStart = trimStart
            self.trimEnd = trimEnd
            self.normalizeGain = normalizeGain
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            bookmark = try c.decode(Data.self, forKey: .bookmark)
            filePath = try c.decodeIfPresent(String.self, forKey: .filePath)
            crossfadeEnabled = try c.decode(Bool.self, forKey: .crossfadeEnabled)
            crossfadeDuration = try c.decode(TimeInterval.self, forKey: .crossfadeDuration)
            usesDefaultCrossfadeEnabled = try c.decode(Bool.self, forKey: .usesDefaultCrossfadeEnabled)
            usesDefaultCrossfadeDuration = try c.decode(Bool.self, forKey: .usesDefaultCrossfadeDuration)
            tagColor = try c.decodeIfPresent(RGBAColor.self, forKey: .tagColor)
            durationSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .durationSeconds)
            trimStart = (try? c.decode(TimeInterval.self, forKey: .trimStart)) ?? 0
            trimEnd = try? c.decode(TimeInterval.self, forKey: .trimEnd)
            normalizeGain = try? c.decode(Float.self, forKey: .normalizeGain)
        }
    }
    
    struct DefaultsBundle: Codable {
        let crossfadeEnabled: Bool
        let crossfadeDuration: TimeInterval
        let nearingEndThreshold: TimeInterval
        let crossfadeCurve: CrossfadeCurve

        init(crossfadeEnabled: Bool, crossfadeDuration: TimeInterval,
             nearingEndThreshold: TimeInterval, crossfadeCurve: CrossfadeCurve) {
            self.crossfadeEnabled = crossfadeEnabled
            self.crossfadeDuration = crossfadeDuration
            self.nearingEndThreshold = nearingEndThreshold
            self.crossfadeCurve = crossfadeCurve
        }

        // Backward-compatible decoder: new fields default gracefully when absent
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            crossfadeEnabled   = try  c.decode(Bool.self,         forKey: .crossfadeEnabled)
            crossfadeDuration  = try  c.decode(TimeInterval.self, forKey: .crossfadeDuration)
            nearingEndThreshold = (try? c.decode(TimeInterval.self,  forKey: .nearingEndThreshold)) ?? 30
            crossfadeCurve      = (try? c.decode(CrossfadeCurve.self, forKey: .crossfadeCurve))     ?? .linear
        }
    }

    struct PausePersisted: Codable {
        var bedBookmark: Data?
        var bedPath: String?
        var bedNormalizeGain: Float?   // optional → backward-compatible with old saves
    }

    enum PersistedItem: Codable {
        case track(BookmarkWithSettings)
        case pause(PausePersisted)

        enum CodingKeys: String, CodingKey { case type, data }
        enum Kind: String, Codable { case track, pause }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let t = try c.decode(Kind.self, forKey: .type)
            switch t {
            case .pause:
                // backward compat: old saves have no .data for pause
                let bundle = (try? c.decode(PausePersisted.self, forKey: .data)) ?? PausePersisted()
                self = .pause(bundle)
            case .track: self = .track(try c.decode(BookmarkWithSettings.self, forKey: .data))
            }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .pause(let bundle):
                try c.encode(Kind.pause, forKey: .type)
                try? c.encode(bundle, forKey: .data)
            case .track(let bundle):
                try c.encode(Kind.track, forKey: .type)
                try c.encode(bundle, forKey: .data)
            }
        }
    }
}

extension PlayoutViewModel: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        // The crossfade timer owns the transition — the outgoing player will reach its
        // natural end during the overlap.  Ignore the delegate so we don't double-advance.
        guard !isCrossfading else { return }
        // Also ignore callbacks from the incoming (alt) player while it hasn't been
        // promoted to self.player yet.
        guard player === self.player else { return }

        if let idx = currentIndex, case .track(let t) = items[idx] {
            appendLog(trackTitle: t.title, event: .finished)
        }
        markCurrentAsPlayed()
        isPlaying = false
        stopTimeUpdates()
        // Advance unless next is a pause
        if let idx = currentIndex {
            let nextIdx = idx + 1
            if items.indices.contains(nextIdx) {
                currentIndex = nextIdx
                if case .pause(let p) = items[nextIdx] {
                    stopPlayback(keepIndex: true)
                    startBed(for: p)
                    pauseEnteredAt = Date()
                } else {
                    play()
                }
            } else {
                stopPlayback()
            }
        }
    }
}

// MARK: - Views

struct ContentView: View {
    @StateObject private var vm = PlayoutViewModel()
    @State private var draggingItemID: UUID? = nil

    @State private var showingCrossfadeEditor = false
    @State private var editingCrossfadeIndex: Int? = nil
    @State private var pendingCrossfadeDuration: Double = 1.0

    @State private var showingTrimEditor = false
    @State private var editingTrimIndex: Int? = nil
    @State private var pendingTrimStart: Double = 0
    @State private var pendingTrimEnd: Double = 0
    @State private var trimEditorDuration: Double = 60
    @State private var trimEditorURL: URL? = nil
    @State private var trimEditorTitle: String = ""

    @State private var dropTargetIndex: Int? = nil
    @State private var isFinderDropTargeted = false
    @State private var flashBright = false
    @State private var currentDate = Date()
    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private struct PlaylistRow: View {
        let index: Int
        let trackNumber: Int?
        let item: PlaylistItem
        let isCurrent: Bool
        let isPlayed: Bool
        let onPlay: () -> Void
        let onInsertPauseBefore: () -> Void
        let onInsertPauseAfter: () -> Void
        let onToggleCrossfade: () -> Void
        let onEditCrossfade: () -> Void
        let onEditTrim: () -> Void
        let onRemove: () -> Void
        let onRemovePause: () -> Void
        let onSetColor: (RGBAColor?) -> Void
        let bedName: String?
        let onAssignBed: () -> Void
        let onRemoveBed: () -> Void
        let isPlaylistPlaying: Bool

        var body: some View {
            if item.isPause {
                pauseRow
            } else if case .track(let t) = item {
                trackRow(t)
            }
        }

        @ViewBuilder
        private func trackRow(_ t: Track) -> some View {
            let isTrimmed = t.trimStart > 0 || t.trimEnd != nil
            let displayDuration = t.effectiveDuration ?? t.durationSeconds
            HStack(spacing: 10) {
                // Track index
                Text(trackNumber.map { "\($0)" } ?? "")
                    .font(.system(size: 14).monospacedDigit())
                    .foregroundStyle(Color.primary.opacity(0.55))
                    .frame(width: 26, alignment: .trailing)
                // Status icon (fixed width to keep title aligned)
                ZStack {
                    if isCurrent {
                        Image(systemName: "speaker.wave.2.fill").foregroundStyle(.red)
                    } else if isPlayed {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    }
                }
                .frame(width: 16)
                // Title
                if t.isMissing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .help("File not found — track will fail to play")
                }
                Text(t.title)
                    .font(.system(size: 15))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(t.tagColor.map { Color($0) } ?? Color.primary)
                Spacer()
                // Duration with optional trim indicator
                if let d = displayDuration {
                    HStack(spacing: 3) {
                        if isTrimmed { Image(systemName: "scissors").font(.caption2) }
                        Text(timeStringStatic(d))
                            .font(.system(size: 14).monospacedDigit())
                            .frame(minWidth: 50, alignment: .trailing)
                    }
                    .foregroundStyle(isTrimmed ? Color.orange : Color.primary.opacity(0.55))
                }
                // CF badge
                if t.crossfadeEnabled {
                    Text("CF")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.25)))
                        .foregroundStyle(.tint)
                        .help("Fades out into the next track (\(String(format: "%.1f", t.crossfadeDuration))s)")
                }
                // Normalization badge
                if let gain = t.normalizeGain {
                    let gainDB = 20.0 * log10(Double(gain))
                    let label = gainDB >= 0 ? String(format: "+%.1f", gainDB) : String(format: "%.1f", gainDB)
                    Text(label)
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(gain < 1.0 ? 0.22 : 0.14)))
                        .foregroundStyle(Color.green)
                        .help("Normalization: \(label) dB applied to reach −23 dBFS")
                }
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            .padding(.vertical, 7)
            .opacity(isPlayed && !isCurrent ? 0.4 : 1.0)
            .background(isCurrent ? Color.red.opacity(0.22) : (index % 2 == 0 ? Color.primary.opacity(0.07) : Color.clear))
            .overlay(alignment: .leading) {
                if isCurrent {
                    Rectangle().fill(Color.red).frame(width: 4)
                } else if let rgba = t.tagColor {
                    Rectangle().fill(Color(rgba)).frame(width: 3)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onPlay() }
            .contextMenu {
                Button("Play", action: onPlay)
                Divider()
                Button("Insert Pause Before", action: onInsertPauseBefore)
                Button("Insert Pause After", action: onInsertPauseAfter)
                Button(t.crossfadeEnabled ? "Disable Fade-out to Next" : "Fade Out into Next Track", action: onToggleCrossfade)
                Button("Set Fade-out Duration…", action: onEditCrossfade)
                Button("Set Trim Points…", action: onEditTrim)
                    .disabled(isPlaylistPlaying)
                Menu("Tag Color") {
                    Button("Red") { onSetColor(RGBAColor(Color.red)) }
                    Button("Orange") { onSetColor(RGBAColor(Color.orange)) }
                    Button("Yellow") { onSetColor(RGBAColor(Color.yellow)) }
                    Button("Green") { onSetColor(RGBAColor(Color.green)) }
                    Button("Blue") { onSetColor(RGBAColor(Color.blue)) }
                    Button("Purple") { onSetColor(RGBAColor(Color.purple)) }
                    Divider()
                    Button("Clear") { onSetColor(nil) }
                }
                Button(role: .destructive, action: onRemove) { Label("Remove", systemImage: "trash") }
            }
        }

        @ViewBuilder
        private var pauseRow: some View {
            HStack(spacing: 10) {
                Text("").frame(width: 26)
                Color.clear.frame(width: 16)
                Text("Pause")
                    .font(.system(size: 15).italic())
                    .foregroundStyle(.red)
                if let name = bedName {
                    Text("·")
                        .font(.system(size: 15).italic())
                        .foregroundStyle(.red.opacity(0.65))
                    Text(name)
                        .font(.system(size: 15).italic())
                        .foregroundStyle(.red.opacity(0.85))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 4)
            }
            .padding(.vertical, 7)
            .background(isCurrent ? Color.red.opacity(0.22) : (index % 2 == 0 ? Color.primary.opacity(0.07) : Color.clear))
            .overlay(alignment: .leading) {
                if isCurrent { Rectangle().fill(Color.red).frame(width: 4) }
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { onPlay() }
            .contextMenu {
                Button("Jump to Pause", action: onPlay)
                Divider()
                Button("Insert Pause Before", action: onInsertPauseBefore)
                Button("Insert Pause After", action: onInsertPauseAfter)
                if bedName != nil {
                    Button("Remove Bed", action: onRemoveBed)
                } else {
                    Button("Assign Bed…", action: onAssignBed)
                }
                Button(role: .destructive, action: onRemovePause) { Label("Remove Pause", systemImage: "trash") }
            }
        }

        private var isCrossfadeEnabled: Bool {
            if case .track(let t) = item { return t.crossfadeEnabled }
            return false
        }

        private func timeStringStatic(_ t: TimeInterval) -> String {
            let total = Int(t)
            let s = total % 60
            let m = (total / 60) % 60
            let h = total / 3600
            if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
            return String(format: "%d:%02d", m, s)
        }
    }

    private func handleDrop(providers: [NSItemProvider], to index: Int) -> Bool {
        // Finder file drop takes priority over internal UUID reorder
        if providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) {
            return handleFinderDrop(providers: providers, at: index)
        }
        // Internal reorder — provider carries a UUID string
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.text.identifier, options: nil) { (data, error) in
            guard error == nil else { return }
            if let d = data as? Data, let idStr = String(data: d, encoding: .utf8), let uuid = UUID(uuidString: idStr) {
                DispatchQueue.main.async { moveItem(with: uuid, to: index) }
            } else if let s = data as? NSString, let uuid = UUID(uuidString: String(s)) {
                DispatchQueue.main.async { moveItem(with: uuid, to: index) }
            }
        }
        return true
    }

    /// Load file URLs from Finder-drop providers (preserving provider order), then insert at index.
    @discardableResult
    private func handleFinderDrop(providers: [NSItemProvider], at index: Int) -> Bool {
        let fileProviders = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        guard !fileProviders.isEmpty else { return false }
        var urlsBySlot = [Int: URL]()
        let group = DispatchGroup()
        for (slot, provider) in fileProviders.enumerated() {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { (data, _) in
                defer { group.leave() }
                var url: URL?
                if let d = data as? Data { url = URL(dataRepresentation: d, relativeTo: nil) }
                else if let u = data as? URL { url = u }
                if let u = url { urlsBySlot[slot] = u }
            }
        }
        group.notify(queue: .main) {
            let urls = urlsBySlot.sorted { $0.key < $1.key }.map(\.value)
            vm.insertFiles(urls: urls, at: index)
        }
        return true
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if vm.playlistAtBottom {
                    controls
                    Divider()
                    playlistView
                } else {
                    playlistView
                    Divider()
                    controls
                }
            }
            .navigationTitle(vm.currentPlaylistName.map { "Segue — \($0)" } ?? "Segue")
            .focusedSceneObject(vm)
            .toolbar {
                // Add audio — primary / most-used action
                ToolbarItem(placement: .primaryAction) { importButton }

                // File I/O: import & export playlist as a pair
                ToolbarItem(placement: .automatic) {
                    ControlGroup {
                        importPlaylistButton
                        exportPlaylistButton
                    }
                }

                // Session lifecycle: reset & clear as a pair
                ToolbarItem(placement: .automatic) {
                    ControlGroup {
                        resetSessionButton
                        clearPlaylistButton
                    }
                }

                // Settings — least-touched, sits at the quiet end
                ToolbarItem(placement: .automatic) { settingsButton }
            }
            .onAppear {
                vm.loadDefaults()
            }
            .sheet(isPresented: $showingCrossfadeEditor) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Fade-out Duration")
                        .font(.headline)
                    HStack {
                        Slider(value: $pendingCrossfadeDuration, in: 0...10, step: 0.1)
                        Text(String(format: "%.1fs", pendingCrossfadeDuration))
                            .frame(width: 60, alignment: .trailing)
                    }
                    HStack {
                        Spacer()
                        Button("Cancel") { showingCrossfadeEditor = false }
                        Button("Save") {
                            if let i = editingCrossfadeIndex, vm.items.indices.contains(i), case .track(var t) = vm.items[i] {
                                t.crossfadeDuration = pendingCrossfadeDuration
                                t.usesDefaultCrossfadeDuration = false
                                vm.items[i] = .track(t)
                                vm.savePlaylist()
                            }
                            showingCrossfadeEditor = false
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding()
                .frame(minWidth: 320)
            }
            .sheet(isPresented: $showingTrimEditor) {
                TrimEditorView(
                    trackTitle: trimEditorTitle,
                    trackURL: trimEditorURL,
                    trimStart: $pendingTrimStart,
                    trimEnd: $pendingTrimEnd,
                    duration: trimEditorDuration,
                    onSave: {
                        if let i = editingTrimIndex,
                           vm.items.indices.contains(i),
                           case .track(var t) = vm.items[i] {
                            t.trimStart = pendingTrimStart
                            t.trimEnd = pendingTrimEnd < trimEditorDuration ? pendingTrimEnd : nil
                            vm.items[i] = .track(t)
                            vm.savePlaylist()
                        }
                        showingTrimEditor = false
                    },
                    onCancel: { showingTrimEditor = false }
                )
            }
            .sheet(isPresented: $vm.showingSettings) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Playback Defaults").font(.title2).bold()

                    // ── Crossfade ─────────────────────────────────────────
                    Toggle("Fade out into next track by default", isOn: $vm.defaultCrossfadeEnabled)
                    HStack {
                        Text("Default fade-out duration")
                        Slider(value: $vm.defaultCrossfadeDuration, in: 0...10, step: 0.1)
                        Text(String(format: "%.1fs", vm.defaultCrossfadeDuration)).frame(width: 60, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                    HStack {
                        Text("Crossfade curve")
                        Spacer()
                        Picker("", selection: $vm.crossfadeCurve) {
                            ForEach(CrossfadeCurve.allCases, id: \.self) { curve in
                                Text(curve.displayName).tag(curve)
                            }
                        }
                        .pickerStyle(.segmented)
                        .fixedSize()
                    }

                    Divider()

                    // ── Beds ──────────────────────────────────────────────
                    HStack {
                        Text("Bed volume")
                        Slider(value: $vm.defaultBedVolume, in: 0...1, step: 0.05)
                        Text(String(format: "%.0f%%", vm.defaultBedVolume * 100)).frame(width: 60, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)

                    Divider()

                    // ── Cue warning ───────────────────────────────────────
                    HStack {
                        Text("Nearing-end warning")
                        Slider(value: $vm.nearingEndThreshold, in: 5...120, step: 5)
                        Text("\(Int(vm.nearingEndThreshold))s").frame(width: 48, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                    Text("Flash the red cue warning this many seconds before the track ends.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    HStack {
                        Spacer()
                        Button("Close") {
                            vm.saveDefaults()
                            // Apply updated defaults to any tracks that are still following defaults
                            for i in vm.items.indices {
                                if case .track(var t) = vm.items[i] {
                                    if t.usesDefaultCrossfadeEnabled  { t.crossfadeEnabled  = vm.defaultCrossfadeEnabled }
                                    if t.usesDefaultCrossfadeDuration { t.crossfadeDuration = vm.defaultCrossfadeDuration }
                                    vm.items[i] = .track(t)
                                }
                            }
                            vm.savePlaylist()
                            vm.showingSettings = false
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding()
                .frame(minWidth: 400)
            }
            .sheet(isPresented: $vm.showingKeyboardShortcuts) {
                keyboardShortcutsSheet
            }
            .sheet(isPresented: $vm.showingPlayLog) {
                playLogSheet
            }
        }
    }

    private var remainingPlaylistDuration: TimeInterval {
        if let idx = vm.currentIndex {
            // Active track: use effectiveEnd (respects trimEnd) with stored-duration fallback.
            // effectiveEnd is briefly 0 while the new player loads after a jump.
            let liveRemaining = vm.effectiveEnd > 0 ? max(0, vm.effectiveEnd - vm.currentTime) : 0
            let storedDuration: TimeInterval = {
                if case .track(let t) = vm.items[idx] { return t.effectiveDuration ?? t.durationSeconds ?? 0 }
                return 0
            }()
            let trackRemaining = liveRemaining > 0 ? liveRemaining : storedDuration
            var total: TimeInterval = trackRemaining
            for i in (idx + 1)..<vm.items.count {
                if case .track(let t) = vm.items[i], let d = t.effectiveDuration ?? t.durationSeconds { total += d }
            }
            return total
        } else {
            // Stopped: find the furthest track that has been played, sum everything after it.
            // If nothing has been played yet this gives the full playlist duration.
            var lastPlayedIdx = -1
            for i in 0..<vm.items.count {
                if case .track(let t) = vm.items[i], vm.playedTrackIDs.contains(t.id) { lastPlayedIdx = i }
            }
            var total: TimeInterval = 0
            for i in (lastPlayedIdx + 1)..<vm.items.count {
                if case .track(let t) = vm.items[i], let d = t.effectiveDuration ?? t.durationSeconds { total += d }
            }
            return total
        }
    }

    @ViewBuilder
    private func playlistRowView(index: Int, item: PlaylistItem, trackNum: Int?) -> some View {
        let isTarget = dropTargetIndex == index
        PlaylistRow(
            index: index,
            trackNumber: trackNum,
            item: item,
            isCurrent: vm.currentIndex == index,
            isPlayed: { if case .track(let t) = item { return vm.playedTrackIDs.contains(t.id) }; return false }(),
            onPlay: { vm.play(at: index) },
            onInsertPauseBefore: { vm.addPause(at: index) },
            onInsertPauseAfter: { vm.addPause(at: index + 1) },
            onToggleCrossfade: {
                if case .track(var t) = vm.items[index] {
                    t.crossfadeEnabled.toggle()
                    t.usesDefaultCrossfadeEnabled = false
                    vm.items[index] = .track(t)
                    vm.savePlaylist()
                }
            },
            onEditCrossfade: {
                if case .track(let t) = vm.items[index] {
                    editingCrossfadeIndex = index
                    pendingCrossfadeDuration = t.crossfadeDuration
                    showingCrossfadeEditor = true
                }
            },
            onEditTrim: {
                if case .track(let t) = vm.items[index] {
                    editingTrimIndex = index
                    pendingTrimStart = t.trimStart
                    let dur = t.durationSeconds ?? 60
                    trimEditorDuration = dur
                    pendingTrimEnd = t.trimEnd ?? dur
                    trimEditorURL = t.url
                    trimEditorTitle = t.title
                    showingTrimEditor = true
                }
            },
            onRemove: { vm.remove(atOffsets: IndexSet([index])) },
            onRemovePause: { vm.remove(atOffsets: IndexSet([index])) },
            onSetColor: { newColor in
                if case .track(var t) = vm.items[index] {
                    t.tagColor = newColor
                    vm.items[index] = .track(t)
                    vm.savePlaylist()
                }
            },
            bedName: { if case .pause(let p) = item { return p.bedFilename } else { return nil } }(),
            onAssignBed: { openBedPicker(for: index) },
            onRemoveBed: { vm.removeBed(at: index) },
            isPlaylistPlaying: vm.isPlaying
        )
        .onDrag { NSItemProvider(object: item.id.uuidString as NSString) }
        .onDrop(of: [UTType.text, UTType.fileURL],
                isTargeted: Binding(
                    get: { self.dropTargetIndex == index },
                    set: { v in self.dropTargetIndex = v ? index : (self.dropTargetIndex == index ? nil : self.dropTargetIndex) }
                )) { self.handleDrop(providers: $0, to: index) }
        .overlay(alignment: .top) {
            if isTarget {
                Rectangle().fill(Color.accentColor).frame(height: 2)
                    .shadow(color: Color.accentColor.opacity(0.6), radius: 4, y: 0)
            }
        }
        .background(isTarget ? Color.accentColor.opacity(0.08) : Color.clear)
    }

    private var playlistView: some View {
        let trackNums: [Int?] = {
            var count = 0
            return vm.items.map { item in
                if case .track = item { count += 1; return count }
                return nil
            }
        }()
        return VStack(spacing: 0) {
        ScrollViewReader { proxy in
        List {
            ForEach(Array(vm.items.enumerated()), id: \.offset) { index, item in
                playlistRowView(index: index, item: item, trackNum: trackNums[index])
            }
            .onMove { from, to in vm.move(from: from, to: to) }
            .onDelete { offsets in vm.remove(atOffsets: offsets) }
        }
        .listStyle(.inset)
        // Catch Finder drops onto empty space between rows (append to end)
        .onDrop(of: [UTType.fileURL], isTargeted: $isFinderDropTargeted) { providers in
            handleFinderDrop(providers: providers, at: vm.items.count)
        }
        .overlay {
            if vm.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "plus.circle.dashed")
                        .font(.system(size: 40))
                        .foregroundStyle(isFinderDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                    Text("Drop audio files here")
                        .font(.body)
                        .foregroundStyle(isFinderDropTargeted ? Color.accentColor : Color.secondary.opacity(0.4))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
                .allowsHitTesting(false)
            }
        }
        .onAppear {
            if let idx = vm.currentIndex {
                proxy.scrollTo(idx, anchor: .center)
            }
        }
        .onChange(of: vm.currentIndex) { idx in
            guard let idx else { return }
            withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo(idx, anchor: .center) }
        }
        .onChange(of: dropTargetIndex) { idx in
            guard let idx = idx, !vm.items.isEmpty else { return }
            if idx <= 1 {
                withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(0, anchor: .top) }
            } else if idx >= vm.items.count - 2 {
                withAnimation(.easeInOut(duration: 0.15)) { proxy.scrollTo(vm.items.count - 1, anchor: .bottom) }
            }
        }
        } // ScrollViewReader
        if !vm.items.isEmpty {
            HStack {
                Image(systemName: "clock")
                    .font(.body)
                Text("Total remaining")
                    .foregroundStyle(.secondary)
                Text(timeString(remainingPlaylistDuration))
                    .fontWeight(.semibold)
                    .monospacedDigit()
                Spacer()
                let trackCount = vm.items.filter { if case .track = $0 { return true }; return false }.count
                Text("\(trackCount) track\(trackCount == 1 ? "" : "s")")
                    .foregroundStyle(.secondary)
            }
            .font(.body)
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.1))
        }
        }
        .overlay(Rectangle().stroke(Color(NSColor.separatorColor), lineWidth: 1))
    }

    private var controls: some View {
        VStack(spacing: 0) {
            // Clock bar — two styled cards
            HStack(spacing: 0) {
                Spacer()
                HStack(spacing: 16) {
                    // Clock card
                    VStack(spacing: 3) {
                        Text("CLOCK")
                            .font(.system(size: 12, weight: .heavy))
                            .kerning(2)
                            .foregroundStyle(.secondary)
                        Text(currentDate, format: .dateTime.hour().minute().second())
                            .font(.system(size: 30, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.07)))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12), lineWidth: 1))

                    if remainingPlaylistDuration > 0 {
                        let endDate = Date().addingTimeInterval(remainingPlaylistDuration)
                        // Show Ends card — accent-tinted to signal it's a target
                        VStack(spacing: 3) {
                            Text("SHOW ENDS")
                                .font(.system(size: 12, weight: .heavy))
                                .kerning(2)
                                .foregroundStyle(Color.accentColor.opacity(0.8))
                            Text(endDate, format: .dateTime.hour().minute().second())
                                .font(.system(size: 30, weight: .bold, design: .monospaced))
                                .foregroundStyle(Color.accentColor)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.accentColor.opacity(0.08)))
                        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.accentColor.opacity(0.25), lineWidth: 1))
                    }
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 12)

            Divider().opacity(0.7)

            // Progress bar + time display
            VStack(spacing: 4) {
                ProgressSlider(
                    value: Binding(get: { vm.effectiveEnd > 0 ? vm.currentTime : 0 }, set: { _ in }),
                    range: 0...(vm.effectiveEnd > 0 ? vm.effectiveEnd : 1),
                    onSeek: { vm.seek(to: $0) }
                )
                HStack {
                    Text(timeString(vm.currentTime))
                        .monospacedDigit()
                    Spacer()
                    let remaining = max(0, vm.effectiveEnd - vm.currentTime)
                    Text("-" + timeString(remaining))
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background {
                            if flashBright {
                                RoundedRectangle(cornerRadius: 4).fill(Color.red.opacity(0.5))
                            }
                        }
                        .animation(flashBright
                            ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                            : .easeOut(duration: 0.3),
                                   value: flashBright)
                }
                .font(.body)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider().opacity(0.7)

            // ON AIR / NEXT panels
            HStack(spacing: 12) {
                // ON AIR
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(vm.isPlaying ? "ON AIR" : "CUE", systemImage: vm.isPlaying ? "dot.radiowaves.left.and.right" : "pause.circle")
                            .font(.title3.bold())
                            .foregroundStyle(vm.isPlaying ? .red : .secondary)
                        if let idx = vm.currentIndex, vm.items.indices.contains(idx) {
                            Text(vm.items[idx].displayName)
                                .font(.system(size: 28, weight: .bold))
                                .lineLimit(3)
                                .foregroundStyle(vm.isNearingEnd ? Color.white : Color.primary)
                            if case .pause(let p) = vm.items[idx], let bedName = p.bedFilename {
                                HStack(spacing: 8) {
                                    Text(bedName)
                                        .font(.system(size: 20, weight: .regular).italic())
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                        .foregroundStyle(.secondary)
                                    Button {
                                        vm.toggleBed()
                                    } label: {
                                        Image(systemName: vm.bedIsPlaying ? "pause.fill" : "play.fill")
                                            .font(.system(size: 14))
                                    }
                                    .buttonStyle(.bordered)
                                    .help("Pause/resume bed (B)")
                                    .keyboardShortcut("b", modifiers: [])
                                }
                            }
                            if let entered = vm.pauseEnteredAt {
                                Text("In break · " + timeString(currentDate.timeIntervalSince(entered)))
                                    .font(.system(size: 28, weight: .semibold).monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("—")
                                .font(.system(size: 28, weight: .bold))
                                .foregroundStyle(.tertiary)
                        }
                        if vm.effectiveEnd > 0 {
                            let elapsed = max(0, vm.currentTime - vm.currentTrimStart)
                            let total = vm.effectiveEnd - vm.currentTrimStart
                            Text("\(timeString(elapsed)) / \(timeString(total))")
                                .font(.system(size: 28, weight: .semibold).monospacedDigit())
                                .foregroundStyle(vm.isNearingEnd ? Color.white.opacity(0.75) : Color.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)

                    VUMeterView(levels: vm.meterLevels, peaks: vm.meterPeaks)
                        .frame(width: 34)
                        .padding(.top, 2)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(flashBright ? Color.red : (vm.isPlaying ? Color.red.opacity(0.13) : Color.secondary.opacity(0.13)))
                        .id(vm.currentIndex)
                        .animation(flashBright
                            ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                            : .easeOut(duration: 0.3),
                                   value: flashBright)
                )
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(vm.isPlaying ? Color.red.opacity(0.5) : Color.secondary.opacity(0.35), lineWidth: 1))

                // NEXT
                VStack(alignment: .leading, spacing: 8) {
                    Label("NEXT", systemImage: "forward.fill")
                        .font(.title3.bold())
                        .foregroundStyle(.secondary)
                    if let idx = vm.currentIndex, vm.items.indices.contains(idx + 1) {
                        let nextItem = vm.items[idx + 1]
                        Text(nextItem.displayName)
                            .font(.system(size: 28, weight: .bold))
                            .lineLimit(3)
                            .foregroundStyle(nextItem.isPause ? .orange : .primary)
                        if case .track(let t) = nextItem,
                           let dur = t.effectiveDuration ?? t.durationSeconds {
                            Text(timeString(dur))
                                .font(.system(size: 20, weight: .semibold).monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text("End of playlist")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.13)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.35), lineWidth: 1))
            }
            .frame(minHeight: 120, maxHeight: 180)
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider().opacity(0.7)

            // Transport controls — three zones so Play sits dead-centre
            HStack(spacing: 0) {
                // Left zone
                HStack(spacing: 20) {
                    Button { vm.previousManual() } label: { Image(systemName: "backward.end.fill").font(.title3) }
                        .disabled(vm.items.isEmpty)
                        .help("Previous track")
                        .keyboardShortcut(.leftArrow, modifiers: [.command])
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 24)

                // Centre: Play / Pause
                Button { vm.togglePlayPause() } label: {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.items.isEmpty)
                .keyboardShortcut(.space, modifiers: [])

                // Right zone
                HStack(spacing: 20) {
                    Button { vm.nextManual() } label: { Image(systemName: "forward.end.fill").font(.title3) }
                        .disabled(vm.items.isEmpty)
                        .help("Next track")
                        .keyboardShortcut(.rightArrow, modifiers: [.command])
                    Button { vm.fadeOut() } label: { Label("Fade Out", systemImage: "stop.fill").font(.title3) }
                        .disabled(!vm.isPlaying)
                        .help("Fade out and stop (3 seconds)")
                        .keyboardShortcut(".", modifiers: [.command])
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 24)
            }
            // Hidden buttons preserve keyboard shortcuts without cluttering the UI
            .background(Group {
                Button("") { vm.seekBackward() }.keyboardShortcut(.leftArrow, modifiers: []).disabled(!vm.isPlaying)
                Button("") { vm.seekForward() }.keyboardShortcut(.rightArrow, modifiers: []).disabled(!vm.isPlaying)
                Button("") { vm.seekToNearEnd() }.keyboardShortcut("e", modifiers: [.command]).disabled(!vm.isPlaying)
                Button("") { vm.showingKeyboardShortcuts = true }.keyboardShortcut("?", modifiers: [])
            }.frame(width: 0, height: 0).opacity(0).accessibilityHidden(true))
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .background(Color.primary.opacity(0.02))
        .onReceive(clockTimer) { date in currentDate = date }
        .onChange(of: vm.isNearingEnd) { nearing in
            flashBright = nearing
        }
    }

    private var importButton: some View {
        Button { vm.openTrackPicker() } label: {
            Label("Add Audio", systemImage: "plus")
        }
        .keyboardShortcut(.init("o"), modifiers: [.command])
        .help("Import MP3 or WAV files")
    }
    
    private var settingsButton: some View {
        Button {
            vm.showingSettings = true
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
        .help("Playback defaults")
    }
    
    private var importPlaylistButton: some View {
        Button { vm.openImportPanel() } label: {
            Label("Import", systemImage: "square.and.arrow.down")
        }
        .help("Import playlist from JSON file")
        .keyboardShortcut(.init("l"), modifiers: [.command])
    }

    private var exportPlaylistButton: some View {
        Button { vm.openExportPanel() } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .help("Export playlist to JSON file")
        .keyboardShortcut(.init("s"), modifiers: [.command])
    }

    private var resetSessionButton: some View {
        Button {
            vm.resetSession()
        } label: {
            Label("Reset Session", systemImage: "arrow.counterclockwise")
        }
        .help("Stop playback and clear played markers — keeps all tracks")
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .disabled(vm.items.isEmpty)
    }

    private var clearPlaylistButton: some View {
        Button(role: .destructive) {
            vm.showingClearConfirm = true
        } label: {
            Label("Clear Playlist", systemImage: "trash")
        }
        .help("Clear all tracks from playlist")
        .disabled(vm.items.isEmpty)
        .confirmationDialog("Clear playlist?", isPresented: $vm.showingClearConfirm) {
            Button("Clear", role: .destructive) { vm.clearPlaylist() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all tracks and pauses.")
        }
    }

    private var helpButton: some View {
        Button {
            vm.showingKeyboardShortcuts = true
        } label: {
            Label("Keyboard Shortcuts", systemImage: "questionmark.circle")
        }
        .help("Show keyboard shortcuts")
        .keyboardShortcut("?", modifiers: [])
    }

    private var keyboardShortcutsSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Keyboard Shortcuts")
                .font(.title2)
                .bold()

            VStack(alignment: .leading, spacing: 12) {
                Group {
                    Text("Playback").font(.headline)
                    ShortcutRow(key: "Space", description: "Play / Pause")
                    ShortcutRow(key: "⌘ + ←", description: "Previous track")
                    ShortcutRow(key: "⌘ + →", description: "Next track")
                    ShortcutRow(key: "←", description: "Seek back 5 seconds")
                    ShortcutRow(key: "→", description: "Seek forward 5 seconds")
                    ShortcutRow(key: "⌘ + .", description: "Fade out and stop")
                    ShortcutRow(key: "B", description: "Pause / resume bed")
                }

                Divider().padding(.vertical, 4)

                Group {
                    Text("Playlist").font(.headline)
                    ShortcutRow(key: "⌘ + O", description: "Add audio files")
                    ShortcutRow(key: "⌘ + L", description: "Import playlist")
                    ShortcutRow(key: "⌘ + S", description: "Export playlist")
                    ShortcutRow(key: "⇧ + ⌘ + R", description: "Reset session (keep tracks, clear played)")
                }

                Divider().padding(.vertical, 4)

                Group {
                    Text("Track Actions").font(.headline)
                    ShortcutRow(key: "Double-click", description: "Play track")
                    ShortcutRow(key: "Right-click", description: "Show context menu")
                }

                Divider().padding(.vertical, 4)

                Group {
                    Text("Other").font(.headline)
                    ShortcutRow(key: "?", description: "Show keyboard shortcuts")
                }
            }

            Spacer()

            HStack {
                Spacer()
                Button("Close") {
                    vm.showingKeyboardShortcuts = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 400, minHeight: 500)
    }

    // MARK: - Play Log sheet

    private var playLogSheet: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                Text("Play Log").font(.title2).bold()
                Spacer()
                Button("Export CSV…") { exportPlayLogCSV() }
                    .disabled(vm.playLog.isEmpty)
                Button("Clear") { vm.playLog.removeAll() }
                    .disabled(vm.playLog.isEmpty)
            }
            .padding()

            Divider()

            if vm.playLog.isEmpty {
                VStack {
                    Spacer()
                    Text("No events recorded yet")
                        .foregroundStyle(.tertiary)
                        .font(.title3)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
            } else {
                List(vm.playLog.reversed()) { entry in
                    HStack(spacing: 12) {
                        Image(systemName: entry.event.icon)
                            .foregroundStyle(entry.event.color)
                            .frame(width: 20)
                        Text(entry.trackTitle)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer()
                        Text(entry.event.displayName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 70, alignment: .trailing)
                        Text(entry.timestamp, style: .time)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 72, alignment: .trailing)
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.inset)
            }

            Divider()
            HStack {
                Text(vm.playLog.isEmpty ? "" : "\(vm.playLog.count) event\(vm.playLog.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Close") { vm.showingPlayLog = false }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(minWidth: 520, minHeight: 380)
    }

    private func exportPlayLogCSV() {
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["csv"]
        let nameFmt = DateFormatter()
        nameFmt.dateFormat = "yyyy-MM-dd"
        panel.nameFieldStringValue = "play-log-\(nameFmt.string(from: Date())).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var lines = ["Timestamp,Track,Event"]
        let tsFmt = DateFormatter()
        tsFmt.dateFormat = "yyyy-MM-dd HH:mm:ss"
        for entry in vm.playLog {
            let time  = tsFmt.string(from: entry.timestamp)
            let title = entry.trackTitle
                .replacingOccurrences(of: "\"", with: "\"\"")
            lines.append("\(time),\"\(title)\",\(entry.event.rawValue)")
        }
        let csv = lines.joined(separator: "\n")
        try? csv.write(to: url, atomically: true, encoding: .utf8)
    }


    private struct ShortcutRow: View {
        let key: String
        let description: String

        var body: some View {
            HStack {
                Text(key)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)
                Text(description)
                Spacer()
            }
        }
    }

    private func timeString(_ t: TimeInterval) -> String {
        let total = Int(t)
        let s = total % 60
        let m = (total / 60) % 60
        let h = total / 3600
        if h > 0 { return String(format: "%d:%02d:%02d", h, m, s) }
        return String(format: "%d:%02d", m, s)
    }
    
    private func moveItem(with id: UUID, to targetIndex: Int) {
        guard let fromIndex = vm.items.firstIndex(where: { $0.id == id }) else { return }
        if fromIndex == targetIndex { return }
        let currentID = vm.currentIndex.flatMap { vm.items.indices.contains($0) ? vm.items[$0].id : nil }
        let item = vm.items.remove(at: fromIndex)
        let safeTarget = max(0, min(targetIndex, vm.items.count))
        vm.items.insert(item, at: safeTarget)
        if let id = currentID {
            vm.currentIndex = vm.items.firstIndex(where: { $0.id == id })
        }
        vm.savePlaylist()
    }

    private func openBedPicker(for index: Int) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = PlayoutViewModel.audioContentTypes
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vm.assignBed(url: url, to: index)
    }

}

// MARK: - Trim Editor

/// Manages the preview AVAudioPlayer for the trim editor so timer callbacks
/// can safely mutate @Published state without value-type struct capture problems.
private final class TrimPreviewState: ObservableObject {
    enum Mode { case inPoint, outPoint }

    @Published var isPlaying: Bool = false
    @Published var currentTime: TimeInterval = 0
    @Published var mode: Mode? = nil

    private var player: AVAudioPlayer?
    private var scopedURL: URL?
    private var timer: Timer?

    /// Start playback from `start`. Plays until the track ends or `stop()` is called.
    func preview(url: URL, from start: TimeInterval, mode: Mode) {
        stop()           // clears mode — set it afterwards
        self.mode = mode
        let accessing = url.startAccessingSecurityScopedResource()
        if accessing { scopedURL = url }
        guard let p = try? AVAudioPlayer(contentsOf: url) else {
            if accessing { url.stopAccessingSecurityScopedResource(); scopedURL = nil }
            return
        }
        p.prepareToPlay()
        p.currentTime = start
        p.volume = 1.0
        p.play()
        player      = p
        currentTime = start
        isPlaying   = true

        timer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] t in
            guard let self, let p = self.player else { t.invalidate(); return }
            self.currentTime = p.currentTime
            if !p.isPlaying { self.stop() }
        }
    }

    func stop() {
        timer?.invalidate(); timer = nil
        player?.stop();      player = nil
        scopedURL?.stopAccessingSecurityScopedResource(); scopedURL = nil
        isPlaying = false
        mode = nil
    }

    deinit { stop() }
}

private struct TrimEditorView: View {
    let trackTitle: String
    let trackURL: URL?
    @Binding var trimStart: Double
    @Binding var trimEnd: Double
    let duration: Double
    let onSave: () -> Void
    let onCancel: () -> Void

    @StateObject private var preview = TrimPreviewState()

    private let previewWindow: TimeInterval = 10

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {

            // ── Header ────────────────────────────────────────────────
            VStack(alignment: .leading, spacing: 3) {
                Text("Trim Track").font(.title3).bold()
                Text(trackTitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Divider()

            // ── In point slider ───────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("In point").fontWeight(.medium)
                    Text("— skip this much from the start")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(fmtTime(trimStart))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $trimStart,
                       in: 0...max(duration - 1, 1),
                       step: 0.5)
                .onChange(of: trimStart) { v in
                    if trimEnd <= v { trimEnd = min(v + 1, duration) }
                    preview.stop()
                }
            }

            // ── Out point slider ──────────────────────────────────────
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Out point").fontWeight(.medium)
                    Text("— stop early here")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(fmtTime(trimEnd))
                        .monospacedDigit().foregroundStyle(.secondary)
                }
                Slider(value: $trimEnd,
                       in: max(trimStart + 1, 1)...max(duration, trimStart + 2),
                       step: 0.5)
                .onChange(of: trimEnd) { _ in preview.stop() }
            }

            Text("Effective duration: \(fmtTime(max(0, trimEnd - trimStart)))")
                .font(.callout).foregroundStyle(.secondary)

            Divider()

            // ── Visual timeline + preview ─────────────────────────────
            VStack(alignment: .leading, spacing: 10) {
                Text("Preview").font(.subheadline).fontWeight(.medium)

                TrimTimelineView(
                    duration: duration,
                    trimStart: trimStart,
                    trimEnd: trimEnd,
                    previewTime: preview.isPlaying ? preview.currentTime : nil
                )
                .frame(height: 40)

                HStack(spacing: 10) {
                    // Preview In
                    Button {
                        guard let url = trackURL else { return }
                        preview.preview(url: url, from: trimStart, mode: .inPoint)
                    } label: {
                        Label("In point", systemImage: "arrow.right.to.line.compact")
                    }
                    .disabled(trackURL == nil || preview.isPlaying)
                    .help("Play from the in point — press Stop or Set Point when done")

                    // Preview Out
                    Button {
                        guard let url = trackURL else { return }
                        preview.preview(url: url,
                                        from: max(trimStart, trimEnd - previewWindow),
                                        mode: .outPoint)
                    } label: {
                        Label("Out point", systemImage: "arrow.left.to.line.compact")
                    }
                    .disabled(trackURL == nil || preview.isPlaying)
                    .help("Play from \(Int(previewWindow))s before the out point — press Set Point at the right moment")

                    // While playing: Stop + Set Here
                    if preview.isPlaying {
                        Button { preview.stop() } label: {
                            Image(systemName: "stop.fill")
                        }
                        .foregroundStyle(.red)
                        .help("Stop preview")

                        Button("Set Point") {
                            let t = preview.currentTime
                            switch preview.mode {
                            case .inPoint:
                                trimStart = t
                                if trimEnd <= trimStart { trimEnd = min(trimStart + 1, duration) }
                            case .outPoint:
                                trimEnd = t
                                if trimEnd <= trimStart { trimEnd = trimStart + 1 }
                            case nil: break
                            }
                            preview.stop()
                        }
                        .foregroundStyle(.yellow)
                        .help("Snap the trim point to the current playback position")
                    }

                    Spacer()

                    if preview.isPlaying {
                        Text(fmtTime(preview.currentTime))
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
            }

            Divider()

            // ── Action row ────────────────────────────────────────────
            HStack {
                Button("Clear Trim") {
                    trimStart = 0
                    trimEnd   = duration
                    preview.stop()
                }
                Spacer()
                Button("Cancel") { preview.stop(); onCancel() }
                Button("Save")   { preview.stop(); onSave()   }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 460)
        .onDisappear { preview.stop() }
    }

    private func fmtTime(_ t: TimeInterval) -> String {
        let n = Int(max(0, t))
        let h = n / 3600; let m = (n / 60) % 60; let s = n % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s)
                     : String(format: "%d:%02d", m, s)
    }
}

/// A horizontal bar showing the full track duration with the active trim region
/// highlighted and an optional playhead.
private struct TrimTimelineView: View {
    let duration: Double
    let trimStart: Double
    let trimEnd: Double
    let previewTime: TimeInterval?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let sx = CGFloat(trimStart / max(duration, 1)) * w
            let ex = CGFloat(trimEnd   / max(duration, 1)) * w

            ZStack(alignment: .leading) {
                // Full track background
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color.primary.opacity(0.09))

                // Kept region
                Rectangle()
                    .fill(Color.accentColor.opacity(0.28))
                    .frame(width: max(0, ex - sx))
                    .offset(x: sx)

                // In-point marker
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
                    .offset(x: sx)

                // Out-point marker
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(width: 2)
                    .offset(x: max(sx, ex - 2))

                // Playhead
                if let t = previewTime {
                    let px = CGFloat(t / max(duration, 1)) * w
                    Rectangle()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 2)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                        .offset(x: max(0, min(px - 1, w - 2)))
                }

                // Trim time labels
                HStack(spacing: 0) {
                    Spacer().frame(width: max(4, sx))
                    Text(mmss(trimStart))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                    Spacer()
                    Text(mmss(trimEnd))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.accentColor)
                    Spacer().frame(width: max(4, w - ex))
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5)
                         .stroke(Color.primary.opacity(0.12), lineWidth: 1))
        }
    }

    private func mmss(_ t: TimeInterval) -> String {
        let n = Int(max(0, t))
        return String(format: "%d:%02d", (n / 60) % 60, n % 60)
    }
}

// MARK: - Progress Slider (custom, avoids NSSlider ghost artifact)

struct ProgressSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onSeek: (Double) -> Void = { _ in }

    @State private var isDragging = false
    @State private var dragValue: Double = 0

    var body: some View {
        GeometryReader { geo in
            let span = max(range.upperBound - range.lowerBound, 0.0001)
            let displayed = isDragging ? dragValue : value
            let frac = max(0, min(1, (displayed - range.lowerBound) / span))
            let trackHeight: CGFloat = 4
            let thumbSize: CGFloat = 14
            let usable = max(geo.size.width - thumbSize, 0)
            let thumbX = usable * CGFloat(frac)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.primary.opacity(0.15))
                    .frame(height: trackHeight)
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: thumbX + thumbSize / 2, height: trackHeight)
                Circle()
                    .fill(Color.white)
                    .overlay(Circle().stroke(Color.black.opacity(0.25), lineWidth: 0.5))
                    .frame(width: thumbSize, height: thumbSize)
                    .offset(x: thumbX)
                    .shadow(color: .black.opacity(0.2), radius: 1, y: 0.5)
            }
            .frame(height: thumbSize)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        let f = max(0, min(1, (g.location.x - thumbSize / 2) / max(usable, 1)))
                        let v = range.lowerBound + Double(f) * span
                        if !isDragging { isDragging = true }
                        dragValue = v
                        onSeek(v)
                    }
                    .onEnded { _ in
                        isDragging = false
                    }
            )
        }
        .frame(height: 14)
    }
}

// MARK: - VU Meter

struct VUMeterView: View {
    let levels: [Float]
    let peaks: [Float]

    private let channelLabels = ["L", "R"]

    var body: some View {
        VStack(spacing: 3) {
            HStack(alignment: .bottom, spacing: 4) {
                ForEach(0..<max(levels.count, 1), id: \.self) { ch in
                    let level = ch < levels.count ? CGFloat(levels[ch]) : 0
                    let peak  = ch < peaks.count  ? CGFloat(peaks[ch])  : 0
                    MeterBarView(level: level, peak: peak)
                }
            }
            HStack(spacing: 4) {
                ForEach(0..<max(levels.count, 1), id: \.self) { ch in
                    Text(ch < channelLabels.count ? channelLabels[ch] : "\(ch+1)")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 10)
        }
    }
}

struct MeterBarView: View {
    let level: CGFloat
    let peak: CGFloat

    var body: some View {
        GeometryReader { geo in
            let h = geo.size.height
            ZStack {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.primary.opacity(0.06))

                // Level fill — VStack+Spacer keeps bar pinned to bottom
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    Rectangle()
                        .fill(meterGradient)
                        .frame(height: h * max(0, min(1, level)))
                }

                // Peak hold line
                if peak > 0.01 {
                    VStack(spacing: 0) {
                        Spacer(minLength: 0)
                            .frame(height: max(0, h * (1 - peak)))
                        Rectangle()
                            .fill(peakColor(peak))
                            .frame(height: 2)
                        Spacer(minLength: 0)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 2))
        }
    }

    private var meterGradient: LinearGradient {
        LinearGradient(
            stops: [
                .init(color: Color(red: 0.1, green: 0.85, blue: 0.1), location: 0),
                .init(color: Color(red: 0.1, green: 0.85, blue: 0.1), location: 0.65),
                .init(color: .yellow,  location: 0.78),
                .init(color: .orange,  location: 0.88),
                .init(color: .red,     location: 1.0),
            ],
            startPoint: .bottom,
            endPoint: .top
        )
    }

    private func peakColor(_ p: CGFloat) -> Color {
        if p > 0.88 { return .red }
        if p > 0.7  { return .yellow }
        return Color(red: 0.1, green: 0.85, blue: 0.1)
    }
}

struct FilePickerBridge: View {
    let allowedExtensions: [String]
    let onPick: ([URL]) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        #if os(iOS)
        IOSPicker(allowedExtensions: allowedExtensions, onPick: { urls in onPick(urls); dismiss() })
        #elseif os(macOS)
        MacPicker(allowedExtensions: allowedExtensions, onPick: { urls in onPick(urls); dismiss() })
        #else
        Text("Unsupported platform")
        #endif
    }
}

struct FileImportBridge: View {
    let onComplete: (Data?) -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        #if os(iOS)
        IOSImport(onComplete: { data in onComplete(data); dismiss() })
        #elseif os(macOS)
        MacImport(onComplete: { data in onComplete(data); dismiss() })
        #else
        Text("Unsupported platform")
        #endif
    }
}

struct FileExportBridge: View {
    let dataProvider: () -> Data?
    var initialDirectory: URL? = nil
    var onDirectoryChosen: ((URL?) -> Void)? = nil
    let onComplete: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        #if os(iOS)
        IOSExport(dataProvider: dataProvider, onComplete: { onComplete(); dismiss() })
        #elseif os(macOS)
        MacExport(dataProvider: dataProvider, initialDirectory: initialDirectory, onDirectoryChosen: onDirectoryChosen, onComplete: { onComplete(); dismiss() })
        #else
        Text("Unsupported platform")
        #endif
    }
}

#if os(iOS)
import UniformTypeIdentifiers
import MobileCoreServices

struct IOSPicker: UIViewControllerRepresentable {
    let allowedExtensions: [String]
    let onPick: ([URL]) -> Void
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [.audio]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coord { Coord(onPick: onPick) }
    final class Coord: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onPick([]) }
    }
}

struct IOSImport: UIViewControllerRepresentable {
    let onComplete: (Data?) -> Void
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = [.json]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}
    func makeCoordinator() -> Coord { Coord(onComplete: onComplete) }
    final class Coord: NSObject, UIDocumentPickerDelegate {
        let onComplete: (Data?) -> Void
        init(onComplete: @escaping (Data?) -> Void) { self.onComplete = onComplete }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard let url = urls.first else { onComplete(nil); return }
            let data = try? Data(contentsOf: url)
            onComplete(data)
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onComplete(nil) }
    }
}

struct IOSExport: UIViewControllerRepresentable {
    let dataProvider: () -> Data?
    let onComplete: () -> Void
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let tempURL: URL
        if let data = dataProvider() {
            let dir = FileManager.default.temporaryDirectory
            tempURL = dir.appendingPathComponent("playlist.json")
            try? data.write(to: tempURL)
        } else {
            tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("empty.json")
            try? Data().write(to: tempURL)
        }
        let vc = UIActivityViewController(activityItems: [tempURL], applicationActivities: nil)
        vc.completionWithItemsHandler = { _, _, _, _ in onComplete() }
        return vc
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
#endif

#if os(macOS)
struct MacPicker: NSViewControllerRepresentable {
    let allowedExtensions: [String]
    let onPick: ([URL]) -> Void
    func makeNSViewController(context: Context) -> NSViewController {
        let vc = NSViewController()
        vc.view = NSView(frame: .zero)
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = true
            panel.allowedFileTypes = allowedExtensions
            if panel.runModal() == .OK {
                onPick(panel.urls)
            } else {
                onPick([])
            }
        }
        return vc
    }
    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {}
}

struct MacImport: NSViewControllerRepresentable {
    let onComplete: (Data?) -> Void
    func makeNSViewController(context: Context) -> NSViewController {
        let vc = NSViewController()
        vc.view = NSView(frame: .zero)
        DispatchQueue.main.async {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedFileTypes = ["json"]
            if panel.runModal() == .OK, let url = panel.url {
                let data = try? Data(contentsOf: url)
                onComplete(data)
            } else {
                onComplete(nil)
            }
        }
        return vc
    }
    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {}
}

struct MacExport: NSViewControllerRepresentable {
    let dataProvider: () -> Data?
    var initialDirectory: URL? = nil
    var onDirectoryChosen: ((URL?) -> Void)? = nil
    let onComplete: () -> Void
    func makeNSViewController(context: Context) -> NSViewController {
        let vc = NSViewController()
        vc.view = NSView(frame: .zero)
        DispatchQueue.main.async {
            let panel = NSSavePanel()
            panel.allowedFileTypes = ["json"]
            panel.nameFieldStringValue = "playlist.json"
            if let dir = initialDirectory {
                panel.directoryURL = dir
            }
            if panel.runModal() == .OK, let url = panel.url, let data = dataProvider() {
                do {
                    let dir = url.deletingLastPathComponent()
                    let tempURL = dir.appendingPathComponent(".tmp-\(UUID().uuidString).json")
                    try data.write(to: tempURL, options: .atomic)
                    if FileManager.default.fileExists(atPath: url.path) {
                        try FileManager.default.removeItem(at: url)
                    }
                    try FileManager.default.moveItem(at: tempURL, to: url)
                } catch {
                    // Present a simple alert to inform the user
                    let alert = NSAlert()
                    alert.messageText = "Export failed"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "OK")
                    alert.runModal()
                }
            }
            onComplete()
        }
        return vc
    }
    func updateNSViewController(_ nsViewController: NSViewController, context: Context) {}
}
#endif

#Preview {
    ContentView()
}
