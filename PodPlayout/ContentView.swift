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

    var title: String {
        url.deletingPathExtension().lastPathComponent
    }
}

extension Track {
    static func from(bookmarkData: Data) -> (Track, Bool)? {
        var isStale = false
        do {
            let url = try URL(resolvingBookmarkData: bookmarkData, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &isStale)
            return (Track(url: url), isStale)
        } catch { return nil }
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
    @Published var autoAdvance: Bool = true

    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    
    @Published var defaultCrossfadeEnabled: Bool = false
    @Published var defaultCrossfadeDuration: TimeInterval = 1.0

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

    func play(at index: Int? = nil) {
        // If an index provided, set it
        if let idx = index { currentIndex = idx }
        guard let idx = currentIndex ?? items.indices.first else { return }
        currentIndex = idx

        let item = items[idx]
        switch item {
        case .pause:
            stopPlayback(keepIndex: true)
        case .track(let track):
            startPlayback(url: track.url)
        }
    }

    func togglePlayPause() {
        if isPlaying {
            pause()
        } else {
            // If we have a paused player, resume it instead of restarting
            if let p = player {
                p.play()
                isPlaying = true
                startTimeUpdates()
                fade(to: 1.0)
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
        guard let idx = currentIndex else {
            if !items.isEmpty {
                fade(to: 0.0, duration: 0.2) {
                    self.player?.stop()
                    self.player = nil
                    self.isPlaying = false
                    self.stopTimeUpdates()
                    self.currentIndex = 0
                    self.play()
                }
            }
            return
        }
        let nextIdx = idx + 1
        if items.indices.contains(nextIdx) {
            if case .track(let t) = items[nextIdx] {
                currentIndex = nextIdx
                if t.crossfadeEnabled {
                    crossfadeTo(url: t.url, duration: max(0.1, t.crossfadeDuration))
                } else {
                    play()
                }
            } else {
                currentIndex = nextIdx
                play()
            }
        } else {
            stopPlayback()
        }
    }

    func previous() {
        guard let idx = currentIndex else { return }
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
            player?.prepareToPlay()
            player?.volume = 0
            player?.play()
            isPlaying = true
            startTimeUpdates()
            fade(to: 1.0)
        } catch {
            print("Failed to play: \(error)")
            isPlaying = false
        }
    }

    private func makePlayer(url: URL, volume: Float) throws -> AVAudioPlayer {
        beginScopedAccess(for: url)
        let p = try AVAudioPlayer(contentsOf: url)
        p.delegate = self
        p.prepareToPlay()
        p.volume = volume
        return p
    }

    private func crossfadeTo(url: URL, duration: TimeInterval) {
        guard let current = player else { startPlayback(url: url); return }
        do {
            let next = try makePlayer(url: url, volume: 0)
            altPlayer = next
            next.play()
            // Ramp both players
            let steps = max(1, Int(duration * 30))
            let stepDuration = duration / Double(steps)
            var i = 0
            Timer.scheduledTimer(withTimeInterval: stepDuration, repeats: true) { timer in
                i += 1
                let t = min(1.0, Double(i)/Double(steps))
                current.volume = Float(1.0 - t)
                next.volume = Float(t)
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

    private func fade(to target: Float, duration: TimeInterval = 0.5, completion: (() -> Void)? = nil) {
        guard let p = player else { completion?(); return }
        let steps = 20
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

    private func startTimeUpdates() {
        stopTimeUpdates()
        timeLink = DisplayLinkBox { [weak self] in
            guard let self, let p = self.player else { return }
            self.currentTime = p.currentTime
            self.duration = p.duration

            if self.autoAdvance, let idx = self.currentIndex {
                let remaining = max(0, self.duration - self.currentTime)
                let nextIdx = idx + 1
                if remaining <= 0.05 { return } // let delegate handle end
                if self.items.indices.contains(nextIdx), case .track(let incoming) = self.items[nextIdx], incoming.crossfadeEnabled {
                    if remaining <= incoming.crossfadeDuration {
                        // Prevent re-trigger by disabling autoAdvance temporarily
                        self.autoAdvance = false
                        self.currentIndex = nextIdx
                        self.crossfadeTo(url: incoming.url, duration: max(0.1, incoming.crossfadeDuration))
                        // Re-enable autoAdvance after a short delay
                        DispatchQueue.main.asyncAfter(deadline: .now() + incoming.crossfadeDuration + 0.1) {
                            self.autoAdvance = true
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
    }

    func loadPersistedPlaylist() {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return }
        do {
            let decoded = try JSONDecoder().decode([PersistedItem].self, from: data)
            var rebuilt: [PlaylistItem] = []
            var anyStale = false
            for item in decoded {
                switch item {
                case .pause:
                    rebuilt.append(.pause(PauseItem()))
                case .track(let bundle):
                    if let result = Track.from(bookmarkData: bundle.bookmark) {
                        var (t, stale) = result
                        t.crossfadeEnabled = bundle.crossfadeEnabled
                        t.crossfadeDuration = bundle.crossfadeDuration
                        // Use defaults if flags are absent in older persisted data (default true)
                        t.usesDefaultCrossfadeEnabled = bundle.usesDefaultCrossfadeEnabled
                        t.usesDefaultCrossfadeDuration = bundle.usesDefaultCrossfadeDuration
                        t.tagColor = bundle.tagColor
                        t.durationSeconds = bundle.durationSeconds ?? t.durationSeconds
                        if t.durationSeconds == nil {
                            let asset = AVURLAsset(url: t.url)
                            let seconds = CMTimeGetSeconds(asset.duration)
                            if seconds.isFinite && seconds > 0 { t.durationSeconds = seconds }
                        }
                        rebuilt.append(.track(t))
                        if stale {
                            anyStale = true
                            // Regenerate bookmark by saving later
                        }
                    }
                }
            }
            items = rebuilt
            // If any bookmarks were stale, re-saving will refresh them
            if anyStale {
                savePlaylist()
            }
        } catch { print("Failed to load playlist: \(error)") }
    }
    
    func loadDefaults() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(DefaultsBundle.self, from: data) {
            defaultCrossfadeEnabled = decoded.crossfadeEnabled
            defaultCrossfadeDuration = decoded.crossfadeDuration
        }
    }
    
    func saveDefaults() {
        let bundle = DefaultsBundle(crossfadeEnabled: defaultCrossfadeEnabled, crossfadeDuration: defaultCrossfadeDuration)
        if let data = try? JSONEncoder().encode(bundle) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }

    func savePlaylist() {
        let persisted: [PersistedItem] = items.compactMap { item in
            switch item {
            case .pause: return .pause
            case .track(let t):
                if let bm = t.makeBookmark() {
                    return .track(BookmarkWithSettings(
                        bookmark: bm,
                        crossfadeEnabled: t.crossfadeEnabled,
                        crossfadeDuration: t.crossfadeDuration,
                        usesDefaultCrossfadeEnabled: t.usesDefaultCrossfadeEnabled,
                        usesDefaultCrossfadeDuration: t.usesDefaultCrossfadeDuration,
                        tagColor: t.tagColor,
                        durationSeconds: t.durationSeconds
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
            case .pause: return .pause
            case .track(let t):
                if let bm = t.makeBookmark() {
                    return .track(BookmarkWithSettings(
                        bookmark: bm,
                        crossfadeEnabled: t.crossfadeEnabled,
                        crossfadeDuration: t.crossfadeDuration,
                        usesDefaultCrossfadeEnabled: t.usesDefaultCrossfadeEnabled,
                        usesDefaultCrossfadeDuration: t.usesDefaultCrossfadeDuration,
                        tagColor: t.tagColor,
                        durationSeconds: t.durationSeconds
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
            case .pause:
                rebuilt.append(.pause(PauseItem()))
            case .track(let bundle):
                if let track = Track.from(bookmarkData: bundle.bookmark) {
                    var t = track.0
                    t.crossfadeEnabled = bundle.crossfadeEnabled
                    t.crossfadeDuration = bundle.crossfadeDuration
                    t.usesDefaultCrossfadeEnabled = bundle.usesDefaultCrossfadeEnabled
                    t.usesDefaultCrossfadeDuration = bundle.usesDefaultCrossfadeDuration
                    t.tagColor = bundle.tagColor
                    t.durationSeconds = bundle.durationSeconds
                    rebuilt.append(.track(t))
                }
            }
        }
        self.items = rebuilt
        savePlaylist()
    }

    struct BookmarkWithSettings: Codable {
        let bookmark: Data
        let crossfadeEnabled: Bool
        let crossfadeDuration: TimeInterval
        let usesDefaultCrossfadeEnabled: Bool
        let usesDefaultCrossfadeDuration: Bool
        let tagColor: RGBAColor?
        let durationSeconds: TimeInterval?
    }
    
    struct DefaultsBundle: Codable {
        let crossfadeEnabled: Bool
        let crossfadeDuration: TimeInterval
    }

    enum PersistedItem: Codable {
        case track(BookmarkWithSettings)
        case pause

        enum CodingKeys: String, CodingKey { case type, data }
        enum Kind: String, Codable { case track, pause }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            let t = try c.decode(Kind.self, forKey: .type)
            switch t {
            case .pause: self = .pause
            case .track: self = .track(try c.decode(BookmarkWithSettings.self, forKey: .data))
            }
        }
        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .pause:
                try c.encode(Kind.pause, forKey: .type)
            case .track(let bundle):
                try c.encode(Kind.track, forKey: .type)
                try c.encode(bundle, forKey: .data)
            }
        }
    }
}

extension PlayoutViewModel: AVAudioPlayerDelegate {
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
        stopTimeUpdates()
        guard autoAdvance else { return }
        // Advance unless next is a pause (we'll stop on pause when play() called)
        if let idx = currentIndex {
            let nextIdx = idx + 1
            if items.indices.contains(nextIdx) {
                currentIndex = nextIdx
                if case .pause = items[nextIdx] {
                    stopPlayback(keepIndex: true)
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
    @State private var showingPickerBridge = false
    @State private var draggingItemID: UUID? = nil

    @State private var showingCrossfadeEditor = false
    @State private var editingCrossfadeIndex: Int? = nil
    @State private var pendingCrossfadeDuration: Double = 1.0

    @State private var dropTargetIndex: Int? = nil
    
    @State private var showingSettings = false
    @State private var showingImport = false
    @State private var showingExport = false
    @State private var lastExportDirectory: URL? = nil
    @State private var isFlashingRemaining = false
    @State private var showingKeyboardShortcuts = false

    private struct PlaylistRow: View {
        let index: Int
        let item: PlaylistItem
        let isCurrent: Bool
        let onPlay: () -> Void
        let onInsertPauseBefore: () -> Void
        let onInsertPauseAfter: () -> Void
        let onToggleCrossfade: () -> Void
        let onEditCrossfade: () -> Void
        let onRemove: () -> Void
        let onRemovePause: () -> Void
        let onSetColor: (RGBAColor?) -> Void

        var body: some View {
            HStack {
                if isCurrent { Image(systemName: "speaker.wave.2.fill").foregroundStyle(.tint) }
                if case .track(let t) = item, let rgba = t.tagColor {
                    Circle().fill(Color(rgba)).frame(width: 10, height: 10)
                }
                Text(item.displayName)
                    .font(item.isPause ? .body.italic() : .body)
                    .foregroundStyle(item.isPause ? .red : .primary)
                Spacer()
                if case .track(let t) = item, let d = t.durationSeconds {
                    Text(timeStringStatic(d))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .frame(minWidth: 60, alignment: .trailing)
                }
                if case .track(let t) = item, t.crossfadeEnabled {
                    Text("CF")
                        .font(.caption2).bold()
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.accentColor.opacity(0.15)))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
            .modifier(PauseTint(isPause: item.isPause))
            .onTapGesture(count: 2) { onPlay() }
            .contextMenu {
                if case .track = item {
                    Button("Play", action: onPlay)
                    Divider()
                }
                Button("Insert Pause Before", action: onInsertPauseBefore)
                Button("Insert Pause After", action: onInsertPauseAfter)
                switch item {
                case .track:
                    Button(isCrossfadeEnabled ? "Disable Crossfade" : "Enable Crossfade", action: onToggleCrossfade)
                    Button("Set Crossfade Duration…", action: onEditCrossfade)
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
                case .pause:
                    Button(role: .destructive, action: onRemovePause) { Label("Remove Pause", systemImage: "trash") }
                }
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
            .navigationTitle("Pod Playout")
            .toolbar {
                ToolbarItem(placement: .primaryAction) { importButton }
                ToolbarItem(placement: .automatic) { settingsButton }
                ToolbarItem(placement: .automatic) { importPlaylistButton }
                ToolbarItem(placement: .automatic) { exportPlaylistButton }
                ToolbarItem(placement: .automatic) { clearPlaylistButton }
            }
            .onAppear {
                vm.loadPersistedPlaylist()
                vm.loadDefaults()
            }
            .sheet(isPresented: $showingCrossfadeEditor) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Crossfade Duration")
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
            .sheet(isPresented: $showingSettings) {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Playback Defaults").font(.title2).bold()
                    Toggle("Crossfade new tracks by default", isOn: $vm.defaultCrossfadeEnabled)
                    HStack {
                        Text("Default crossfade duration")
                        Slider(value: $vm.defaultCrossfadeDuration, in: 0...10, step: 0.1)
                        Text(String(format: "%.1fs", vm.defaultCrossfadeDuration)).frame(width: 60, alignment: .trailing)
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
            .sheet(isPresented: $showingExport) {
                FileExportBridge(dataProvider: { vm.exportPlaylistData() }, initialDirectory: lastExportDirectory, onDirectoryChosen: { dir in
                    lastExportDirectory = dir
                }) {
                    showingExport = false
                }
            }
            .sheet(isPresented: $showingKeyboardShortcuts) {
                keyboardShortcutsSheet
            }
            .onKeyPress(.init("?")) { press in
                showingKeyboardShortcuts = true
                return .handled
            }
        }
    }

    private var playlistView: some View {
        List {
            ForEach(Array(vm.items.enumerated()), id: \.offset) { index, item in
                PlaylistRow(
                    index: index,
                    item: item,
                    isCurrent: vm.currentIndex == index,
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
                    }
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
                .background(dropTargetIndex == index ? RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.1)) : nil)
            }
            .onMove { from, to in vm.move(from: from, to: to) }
            .onDelete { offsets in vm.remove(atOffsets: offsets) }
        }
        .listStyle(.inset)
    }

    private var controls: some View {
        VStack(spacing: 12) {
            VStack(spacing: 4) {
                Slider(value: Binding(get: { vm.duration > 0 ? vm.currentTime : 0 }, set: { vm.seek(to: $0) }), in: 0...(vm.duration > 0 ? vm.duration : 1))
                HStack {
                    Text(timeString(vm.currentTime))
                    Spacer()
                    let remaining = max(0, vm.duration - vm.currentTime)
                    Text(timeString(remaining))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 4)
                                .fill(Color.red.opacity(isFlashingRemaining ? 0.5 : 0))
                        )
                        .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: isFlashingRemaining)
                        .onChange(of: remaining) { newValue in
                            let shouldFlash = newValue > 0 && newValue <= 30
                            if shouldFlash && !isFlashingRemaining {
                                isFlashingRemaining = true
                            } else if !shouldFlash && isFlashingRemaining {
                                isFlashingRemaining = false
                            }
                        }
                }
                .font(.title)
                .foregroundStyle(.secondary)
            }
            HStack(spacing: 24) {
                Button { vm.previous() } label: { Label("Previous", systemImage: "backward.fill") }
                    .disabled(vm.items.isEmpty)
                    .keyboardShortcut(.leftArrow, modifiers: [.command])
                Button {
                    vm.togglePlayPause()
                } label: {
                    Image(systemName: vm.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                .buttonStyle(.borderedProminent)
                .disabled(vm.items.isEmpty)
                .keyboardShortcut(.space, modifiers: [])
                Button { vm.next() } label: { Label("Next", systemImage: "forward.fill") }
                    .disabled(vm.items.isEmpty)
                    .keyboardShortcut(.rightArrow, modifiers: [.command])
            }
            Toggle("Auto-advance", isOn: $vm.autoAdvance)

            // Now Playing - Super Visible
            VStack(spacing: 4) {
                if let idx = vm.currentIndex, vm.items.indices.contains(idx) {
                    let remaining = max(0, vm.duration - vm.currentTime)
                    Text(vm.items[idx].displayName)
                        .font(.title2)
                        .fontWeight(.bold)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(remaining <= 30 && remaining > 0 ? .white : .primary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity)
                        .background(
                            RoundedRectangle(cornerRadius: 8)
                                .fill(remaining <= 30 && remaining > 0 ? Color.red : Color.clear)
                                .animation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: remaining <= 30 && remaining > 0)
                        )
                } else {
                    Text("No Track Playing")
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 12)
                }
            }
        }
        .padding()
        .onChange(of: vm.isPlaying) { playing in
            if !playing { isFlashingRemaining = false }
        }
    }

    private var importButton: some View {
        Button {
            showingPickerBridge = true
        } label: {
            Label("Add Audio", systemImage: "plus")
        }
        .keyboardShortcut(.init("o"), modifiers: [.command])
        .help("Import MP3 or WAV files")
        .sheet(isPresented: $showingPickerBridge) {
            FilePickerBridge(allowedExtensions: ["mp3","wav"]) { urls in
                vm.addFiles(urls: urls)
                vm.savePlaylist()
            }
        }
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
        Button {
            showingImport = true
        } label: {
            Label("Import", systemImage: "square.and.arrow.down")
        }
        .help("Import playlist from JSON file")
        .keyboardShortcut(.init("l"), modifiers: [.command])
        .sheet(isPresented: $showingImport) {
            FileImportBridge { data in
                if let data = data {
                    try? vm.importPlaylistData(data)
                }
                showingImport = false
            }
        }
    }

    private var exportPlaylistButton: some View {
        Button {
            showingExport = true
        } label: {
            Label("Export", systemImage: "square.and.arrow.up")
        }
        .help("Export playlist to JSON file")
        .keyboardShortcut(.init("s"), modifiers: [.command])
    }

    private var clearPlaylistButton: some View {
        Button(role: .destructive) {
            vm.items.removeAll()
            vm.currentIndex = nil
            vm.savePlaylist()
        } label: {
            Label("Clear Playlist", systemImage: "trash")
        }
        .help("Clear all tracks from playlist")
        .disabled(vm.items.isEmpty)
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
                }

                Divider().padding(.vertical, 4)

                Group {
                    Text("Playlist").font(.headline)
                    ShortcutRow(key: "⌘ + O", description: "Add audio files")
                    ShortcutRow(key: "⌘ + L", description: "Import playlist")
                    ShortcutRow(key: "⌘ + S", description: "Export playlist")
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
                    ShortcutRow(key: "?", description: "Show this help")
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
    
    private struct PauseTint: ViewModifier {
        let isPause: Bool
        func body(content: Content) -> some View {
            if isPause {
                content.foregroundStyle(.red)
            } else {
                content
            }
        }
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
