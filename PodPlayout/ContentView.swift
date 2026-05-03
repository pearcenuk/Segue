//
//  ContentView.swift
//  PodPlayout
//
//  Created by Neil Pearce on 26/10/2025.
//

import SwiftUI
import AVFoundation
import Combine

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

// MARK: - Models

struct PauseItem: Identifiable, Equatable {
    let id = UUID()
    var bedBookmark: Data? = nil
    var bedURL: URL? = nil

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
    @Published var defaultBedVolume: Float = 0.4

    @Published var bedIsPlaying: Bool = false
    private var bedPlayer: AVAudioPlayer? = nil
    private var bedScopedURL: URL? = nil

    private var player: AVAudioPlayer?
    private var altPlayer: AVAudioPlayer?
    private var timeLink: CADisplayLinkLike?

    private var currentScopedURL: URL? = nil
    private var currentScopeActive: Bool = false

    private let storageKey = "playlist.bookmarks.v1"
    private let defaultsKey = "playlist.defaults.v1"

    // Load files (mp3, wav)
    func addFiles(urls: [URL]) {
        let supported: Set<String> = ["mp3", "wav"]
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
        items.append(contentsOf: newItems)
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
        items.remove(atOffsets: offsets)
        // Adjust current index if needed
        if let current = currentIndex {
            if items.indices.contains(current) == false { currentIndex = nil }
        }
        savePlaylist()
    }

    func move(from source: IndexSet, to destination: Int) {
        items.move(fromOffsets: source, toOffset: destination)
        // Keep currentIndex aligned to the same item if possible
        if let current = currentIndex, current < items.count {
            // No-op: SwiftUI move keeps order; currentIndex still points to same position
        }
        savePlaylist()
    }

    private func markCurrentAsPlayed() {
        if let idx = currentIndex, case .track(let t) = items[idx] {
            playedTrackIDs.insert(t.id)
        }
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
        fade(to: 0.0, duration: 0.2) {
            self.player?.stop()
            self.player = nil
            self.altPlayer?.stop()
            self.altPlayer = nil
            self.endScopedAccess()
            self.isPlaying = false
            if !keepIndex { self.currentIndex = nil }
            self.stopTimeUpdates()
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
        fade(to: 0.0, duration: duration) {
            self.player?.stop()
            self.player = nil
            self.altPlayer?.stop()
            self.altPlayer = nil
            self.endScopedAccess()
            self.isPlaying = false
            self.stopTimeUpdates()
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
            var i = 0
            Timer.scheduledTimer(withTimeInterval: stepDuration, repeats: true) { timer in
                i += 1
                let t = min(1.0, Double(i)/Double(steps))
                current.volume = startVolume * Float(1.0 - t)
                next.volume = targetVolume * Float(t)
                if i >= steps {
                    timer.invalidate()
                    current.stop()
                    self.player = next
                    self.beginScopedAccess(for: url)
                    self.altPlayer = nil
                    self.isPlaying = true
                    self.startTimeUpdates()
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
        fade(p, to: defaultBedVolume, duration: 1.5)
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
            fade(b, to: defaultBedVolume, duration: 2.0)
        }
    }

    func assignBed(url: URL, to index: Int) {
        guard items.indices.contains(index), case .pause(var p) = items[index] else { return }
        p.bedBookmark = try? url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        p.bedURL = url
        items[index] = .pause(p)
        savePlaylist()
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
            self.isNearingEnd = remaining > 0 && remaining <= 30

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
    private func stopTimeUpdates() {
        timeLink?.invalidate()
        timeLink = nil
        currentTime = 0
        duration = 0
        effectiveEnd = 0
        currentTrimStart = 0
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
        } catch { print("Failed to load playlist: \(error)") }
    }
    
    func loadDefaults() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(DefaultsBundle.self, from: data) {
            defaultCrossfadeEnabled = decoded.crossfadeEnabled
            defaultCrossfadeDuration = decoded.crossfadeDuration
        }
        let saved = UserDefaults.standard.float(forKey: "defaultBedVolume")
        defaultBedVolume = saved > 0 ? saved : 0.4
    }

    func saveDefaults() {
        let bundle = DefaultsBundle(crossfadeEnabled: defaultCrossfadeEnabled, crossfadeDuration: defaultCrossfadeDuration)
        if let data = try? JSONEncoder().encode(bundle) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        UserDefaults.standard.set(defaultBedVolume, forKey: "defaultBedVolume")
    }

    func savePlaylist() {
        let persisted: [PersistedItem] = items.compactMap { item in
            switch item {
            case .pause(let p): return .pause(PausePersisted(bedBookmark: p.bedBookmark, bedPath: p.bedURL?.path))
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

    // MARK: - File-based import/export
    func exportPlaylistData() -> Data? {
        let persisted: [PersistedItem] = items.compactMap { item in
            switch item {
            case .pause(let p): return .pause(PausePersisted(bedBookmark: p.bedBookmark, bedPath: p.bedURL?.path))
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
    }

    struct PausePersisted: Codable {
        var bedBookmark: Data?
        var bedPath: String?
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

    @State private var dropTargetIndex: Int? = nil
    
    @State private var showingSettings = false
    @State private var lastExportDirectory: URL? = nil
    @State private var flashBright = false
    @State private var showingKeyboardShortcuts = false
    @State private var currentDate = Date()
    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    @State private var showingClearConfirm = false

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
                    .font(.system(size: 13).monospacedDigit())
                    .foregroundStyle(.secondary)
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
                    .font(.body)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .foregroundStyle(t.tagColor.map { Color($0) } ?? Color.primary)
                Spacer()
                // Duration with optional trim indicator
                if let d = displayDuration {
                    HStack(spacing: 3) {
                        if isTrimmed { Image(systemName: "scissors").font(.caption2) }
                        Text(timeStringStatic(d))
                            .font(.callout.monospacedDigit())
                            .frame(minWidth: 50, alignment: .trailing)
                    }
                    .foregroundStyle(isTrimmed ? Color.orange : Color.secondary)
                }
                // CF badge
                if t.crossfadeEnabled {
                    Text("CF")
                        .font(.caption2.bold())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
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
                        .background(Capsule().fill(Color.green.opacity(gain < 1.0 ? 0.15 : 0.08)))
                        .foregroundStyle(Color.green.opacity(0.8))
                        .help("Normalization: \(label) dB applied to reach −23 dBFS")
                }
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
                    .padding(.leading, 4)
            }
            .padding(.vertical, 7)
            .opacity(isPlayed && !isCurrent ? 0.4 : 1.0)
            .background(isCurrent ? Color.red.opacity(0.08) : (index % 2 == 0 ? Color.primary.opacity(0.04) : Color.clear))
            .overlay(alignment: .leading) {
                if let rgba = t.tagColor {
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
                    .font(.body.italic())
                    .foregroundStyle(.red)
                if let name = bedName {
                    Text("·")
                        .font(.body.italic())
                        .foregroundStyle(.red.opacity(0.5))
                    Text(name)
                        .font(.body.italic())
                        .foregroundStyle(.red.opacity(0.7))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                Image(systemName: "line.3.horizontal")
                    .font(.caption)
                    .foregroundStyle(.quaternary)
                    .padding(.leading, 4)
            }
            .padding(.vertical, 7)
            .background(isCurrent ? Color.red.opacity(0.08) : (index % 2 == 0 ? Color.primary.opacity(0.04) : Color.clear))
            .contentShape(Rectangle())
            .contextMenu {
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

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                playlistView
                Divider()
                controls
            }
            .navigationTitle("Segue")
            .toolbar {
                // Primary: add audio files
                ToolbarItem(placement: .primaryAction) { importButton }

                // File I/O group: import / export playlist together
                ToolbarItem(placement: .automatic) {
                    ControlGroup {
                        importPlaylistButton
                        exportPlaylistButton
                    }
                }

                // Settings
                ToolbarItem(placement: .automatic) { settingsButton }

                // Session group: reset / clear — visually separated from the above
                ToolbarItem(placement: .automatic) {
                    ControlGroup {
                        resetSessionButton
                        clearPlaylistButton
                    }
                }
            }
            .onAppear {
                vm.loadPersistedPlaylist()
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
                trimEditorSheet
            }
            .sheet(isPresented: $showingSettings) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Playback Defaults").font(.title2).bold()
                    Toggle("Fade out into next track by default", isOn: $vm.defaultCrossfadeEnabled)
                    HStack {
                        Text("Default fade-out duration")
                        Slider(value: $vm.defaultCrossfadeDuration, in: 0...10, step: 0.1)
                        Text(String(format: "%.1fs", vm.defaultCrossfadeDuration)).frame(width: 60, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                    Divider()
                    HStack {
                        Text("Bed volume")
                        Slider(value: $vm.defaultBedVolume, in: 0...1, step: 0.05)
                        Text(String(format: "%.0f%%", vm.defaultBedVolume * 100)).frame(width: 60, alignment: .trailing)
                    }
                    .accessibilityElement(children: .combine)
                    HStack {
                        Spacer()
                        Button("Close") {
                            // Save new defaults
                            vm.saveDefaults()
                            // Apply updated defaults to any tracks that are still following defaults
                            for i in vm.items.indices {
                                if case .track(var t) = vm.items[i] {
                                    if t.usesDefaultCrossfadeEnabled {
                                        t.crossfadeEnabled = vm.defaultCrossfadeEnabled
                                    }
                                    if t.usesDefaultCrossfadeDuration {
                                        t.crossfadeDuration = vm.defaultCrossfadeDuration
                                    }
                                    vm.items[i] = .track(t)
                                }
                            }
                            vm.savePlaylist()
                            showingSettings = false
                        }
                        .keyboardShortcut(.defaultAction)
                    }
                }
                .padding()
                .frame(minWidth: 360)
            }
            .sheet(isPresented: $showingKeyboardShortcuts) {
                keyboardShortcutsSheet
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
                PlaylistRow(
                    index: index,
                    trackNumber: trackNums[index],
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
                            showingTrimEditor = true
                        }
                    },
                    onRemove: {
                        vm.items.remove(at: index)
                        vm.savePlaylist()
                    },
                    onRemovePause: {
                        vm.items.remove(at: index)
                        vm.savePlaylist()
                    },
                    onSetColor: { newColor in
                        if case .track(var t) = vm.items[index] {
                            t.tagColor = newColor
                            vm.items[index] = .track(t)
                            vm.savePlaylist()
                        }
                    },
                    bedName: { if case .pause(let p) = item { return p.bedFilename } else { return nil } }(),
                    onAssignBed: { openBedPicker(for: index) },
                    onRemoveBed: { vm.removeBed(at: index) }
                )
                .onDrag { NSItemProvider(object: item.id.uuidString as NSString) }
                .onDrop(
                    of: [UTType.text],
                    isTargeted: Binding(
                        get: { dropTargetIndex == index },
                        set: { isOver in
                            dropTargetIndex = isOver ? index : (dropTargetIndex == index ? nil : dropTargetIndex)
                        })
                ) { providers in
                    handleDrop(providers: providers, to: index)
                }
                .overlay(alignment: .top) {
                    if dropTargetIndex == index {
                        Rectangle()
                            .fill(Color.accentColor)
                            .frame(height: 2)
                            .shadow(color: Color.accentColor.opacity(0.6), radius: 4, y: 0)
                    }
                }
                .background(dropTargetIndex == index ? Color.accentColor.opacity(0.08) : Color.clear)
            }
            .onMove { from, to in vm.move(from: from, to: to) }
            .onDelete { offsets in vm.remove(atOffsets: offsets) }
        }
        .listStyle(.inset)
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
            .background(Color.secondary.opacity(0.06))
        }
        }
        .overlay(Rectangle().stroke(Color(NSColor.separatorColor), lineWidth: 1))
    }

    private var controls: some View {
        VStack(spacing: 0) {
            // Clock bar
            HStack(alignment: .bottom, spacing: 0) {
                Spacer()
                HStack(alignment: .bottom, spacing: 20) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("CLOCK")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Text(currentDate, format: .dateTime.hour().minute().second())
                            .font(.title3.weight(.semibold).monospacedDigit())
                    }
                    if remainingPlaylistDuration > 0 {
                        Divider().frame(height: 36)
                        let endDate = currentDate.addingTimeInterval(remainingPlaylistDuration)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("SHOW ENDS ~")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(endDate, format: .dateTime.hour().minute().second())
                                .font(.title3.weight(.semibold).monospacedDigit())
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal)
            .padding(.top, 8)
            .padding(.bottom, 6)

            Divider().opacity(0.4)

            // Progress bar + time display
            VStack(spacing: 4) {
                Slider(value: Binding(get: { vm.effectiveEnd > 0 ? vm.currentTime : 0 }, set: { vm.seek(to: $0) }), in: 0...(vm.effectiveEnd > 0 ? vm.effectiveEnd : 1))
                HStack {
                    Text(timeString(vm.currentTime))
                        .monospacedDigit()
                    Spacer()
                    let remaining = max(0, vm.effectiveEnd - vm.currentTime)
                    Text("-" + timeString(remaining))
                        .monospacedDigit()
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Color.red.opacity(flashBright ? 0.5 : 0)))
                }
                .font(.body)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider().opacity(0.4)

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
                                .foregroundStyle(flashBright ? Color.white : (vm.isNearingEnd ? Color.red : Color.primary))
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
                                .foregroundStyle(flashBright ? Color.white.opacity(0.75) : Color.secondary)
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
                        .fill(flashBright ? Color.red : (vm.isPlaying ? Color.red.opacity(0.08) : Color.secondary.opacity(0.08)))
                        .id(vm.currentIndex) // recreate on track change, killing any in-progress animation
                )
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(vm.isPlaying ? Color.red.opacity(0.4) : Color.secondary.opacity(0.2), lineWidth: 1))

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
                    } else {
                        Text("End of playlist")
                            .font(.system(size: 28, weight: .bold))
                            .foregroundStyle(.tertiary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.secondary.opacity(0.2), lineWidth: 1))
            }
            .frame(minHeight: 120)
            .padding(.horizontal)
            .padding(.top, 10)
            .padding(.bottom, 6)

            Divider().opacity(0.4)

            // Transport controls
            HStack(spacing: 0) {
                Spacer()
                HStack(spacing: 20) {
                    Button { vm.previous() } label: { Image(systemName: "backward.end.fill").font(.title3) }
                        .disabled(vm.items.isEmpty)
                        .help("Previous track")
                        .keyboardShortcut(.leftArrow, modifiers: [.command])
                    Button { vm.togglePlayPause() } label: {
                        Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill").font(.title2)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(vm.items.isEmpty)
                    .keyboardShortcut(.space, modifiers: [])
                    Button { vm.next() } label: { Image(systemName: "forward.end.fill").font(.title3) }
                        .disabled(vm.items.isEmpty)
                        .help("Next track")
                        .keyboardShortcut(.rightArrow, modifiers: [.command])
                    Button { vm.seekToNearEnd() } label: { Image(systemName: "10.arrow.trianglehead.counterclockwise").font(.title3) }
                        .disabled(!vm.isPlaying)
                        .help("Skip to 10 seconds from end")
                        .keyboardShortcut("e", modifiers: [.command])
                    Button { vm.fadeOut() } label: { Label("Fade Out", systemImage: "speaker.slash.fill").font(.title3) }
                        .disabled(!vm.isPlaying)
                        .help("Fade out and stop (3 seconds)")
                        .keyboardShortcut(".", modifiers: [.command])
                }
                // Hidden seek buttons preserve ← / → keyboard shortcuts without cluttering the toolbar
                Group {
                    Button("") { vm.seekBackward() }.keyboardShortcut(.leftArrow, modifiers: []).disabled(!vm.isPlaying)
                    Button("") { vm.seekForward() }.keyboardShortcut(.rightArrow, modifiers: []).disabled(!vm.isPlaying)
                }.frame(width: 0, height: 0).opacity(0).accessibilityHidden(true)
                Spacer()
            }
            .padding(.horizontal)
            .padding(.vertical, 10)
        }
        .background(Color.primary.opacity(0.02))
        .onReceive(clockTimer) { date in currentDate = date }
        .onChange(of: vm.isNearingEnd) { nearing in
            if nearing {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    flashBright = true
                }
            } else {
                flashBright = false
            }
        }
    }

    private var importButton: some View {
        Button { openTrackPicker() } label: {
            Label("Add Audio", systemImage: "plus")
        }
        .keyboardShortcut(.init("o"), modifiers: [.command])
        .help("Import MP3 or WAV files")
    }
    
    private var settingsButton: some View {
        Button {
            showingSettings = true
        } label: {
            Label("Settings", systemImage: "gearshape")
        }
        .help("Playback defaults")
    }
    
    private var importPlaylistButton: some View {
        Button { openImportPanel() } label: {
            Label("Import", systemImage: "square.and.arrow.down")
        }
        .help("Import playlist from JSON file")
        .keyboardShortcut(.init("l"), modifiers: [.command])
    }

    private var exportPlaylistButton: some View {
        Button { openExportPanel() } label: {
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
            showingClearConfirm = true
        } label: {
            Label("Clear Playlist", systemImage: "trash")
        }
        .help("Clear all tracks from playlist")
        .disabled(vm.items.isEmpty)
        .confirmationDialog("Clear playlist?", isPresented: $showingClearConfirm) {
            Button("Clear", role: .destructive) {
                vm.stopPlayback()
                vm.stopBed()
                vm.items.removeAll()
                vm.currentIndex = nil
                vm.savePlaylist()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will remove all tracks and pauses.")
        }
    }

    private var helpButton: some View {
        Button {
            showingKeyboardShortcuts = true
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
                    ShortcutRow(key: "⌘ + E", description: "Skip to 10s from end")
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
                    showingKeyboardShortcuts = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 400, minHeight: 500)
    }

    private var trimEditorSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Trim Track").font(.headline)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("In point (start offset)")
                    Spacer()
                    Text(timeString(pendingTrimStart))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $pendingTrimStart, in: 0...max(trimEditorDuration - 1, 1), step: 0.5)
                    .onChange(of: pendingTrimStart) { v in
                        if pendingTrimEnd <= v { pendingTrimEnd = min(v + 1, trimEditorDuration) }
                    }
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Out point (early end)")
                    Spacer()
                    Text(timeString(pendingTrimEnd))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $pendingTrimEnd, in: max(pendingTrimStart + 1, 1)...max(trimEditorDuration, pendingTrimStart + 2), step: 0.5)
            }

            let effective = pendingTrimEnd - pendingTrimStart
            Text("Effective duration: \(timeString(max(0, effective)))")
                .font(.callout)
                .foregroundStyle(.secondary)

            HStack {
                Button("Clear Trim") {
                    pendingTrimStart = 0
                    pendingTrimEnd = trimEditorDuration
                }
                Spacer()
                Button("Cancel") { showingTrimEditor = false }
                Button("Save") {
                    if let i = editingTrimIndex, vm.items.indices.contains(i), case .track(var t) = vm.items[i] {
                        t.trimStart = pendingTrimStart
                        t.trimEnd = pendingTrimEnd < trimEditorDuration ? pendingTrimEnd : nil
                        vm.items[i] = .track(t)
                        vm.savePlaylist()
                    }
                    showingTrimEditor = false
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(minWidth: 380)
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
        let item = vm.items.remove(at: fromIndex)
        let safeTarget = max(0, min(targetIndex, vm.items.count))
        vm.items.insert(item, at: safeTarget)
        vm.savePlaylist()
    }

    private func openTrackPicker() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowedFileTypes = ["mp3", "wav"]
        guard panel.runModal() == .OK else { return }
        vm.addFiles(urls: panel.urls)
        vm.savePlaylist()
    }

    private func openBedPicker(for index: Int) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["mp3", "wav", "aiff", "m4a"]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        vm.assignBed(url: url, to: index)
    }

    private func openImportPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedFileTypes = ["json"]
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url) else { return }
        try? vm.importPlaylistData(data)
    }

    private func openExportPanel() {
        let panel = NSSavePanel()
        panel.allowedFileTypes = ["json"]
        panel.nameFieldStringValue = "playlist.json"
        if let dir = lastExportDirectory { panel.directoryURL = dir }
        guard panel.runModal() == .OK, let url = panel.url,
              let data = vm.exportPlaylistData() else { return }
        do {
            let dir = url.deletingLastPathComponent()
            let tmp = dir.appendingPathComponent(".tmp-\(UUID().uuidString).json")
            try data.write(to: tmp, options: .atomic)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
            try FileManager.default.moveItem(at: tmp, to: url)
            lastExportDirectory = dir
        } catch {
            let alert = NSAlert()
            alert.messageText = "Export failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
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
