import Foundation
import AppKit
import AVFoundation
import UniformTypeIdentifiers

/// One selectable sound.
public struct SoundOption: Identifiable, Hashable {
    public enum Kind: String, Hashable {
        case none
        case auraChime     // synthesized AuraSense signature tones
        case system        // /System/Library/Sounds and ~/Library/Sounds
        case custom        // user-imported audio copied into Application Support
    }

    /// Stable identifier persisted in UserDefaults, e.g. `system:Glass`, `aura:orbit`, `custom:<file>`.
    public let id: String
    public let kind: Kind
    public let displayName: String
    public let fileURL: URL?

    public static let none = SoundOption(id: "none", kind: .none, displayName: "No Sound", fileURL: nil)
}

/// Lists, imports, previews, and plays the sounds AuraSense uses for unlock and lock events.
@MainActor
public final class UnlockSoundLibrary: ObservableObject {
    public static let shared = UnlockSoundLibrary()

    public static let defaultUnlockSoundID = "aura:bloom"
    public static let defaultLockSoundID = "system:Tink"
    public static let supportedImportTypes: [UTType] = [.audio, .mp3, .mpeg4Audio, .wav, .aiff]
    public static let maxImportBytes = 60 * 1024 * 1024

    @Published public var unlockSoundID: String {
        didSet { UserDefaults.standard.set(unlockSoundID, forKey: Keys.unlockSound) }
    }
    @Published public var lockSoundID: String {
        didSet { UserDefaults.standard.set(lockSoundID, forKey: Keys.lockSound) }
    }
    @Published public var volume: Double {
        didSet { UserDefaults.standard.set(volume, forKey: Keys.volume) }
    }
    /// Longer files (songs) are faded out after this many seconds.
    @Published public var maxPlaybackSeconds: Double {
        didSet { UserDefaults.standard.set(maxPlaybackSeconds, forKey: Keys.maxPlayback) }
    }
    @Published public private(set) var customSounds: [SoundOption] = []
    @Published public private(set) var lastImportMessage: String?

    private enum Keys {
        static let unlockSound = "aurasense.unlockSoundID"
        static let lockSound = "aurasense.lockSoundID"
        static let volume = "aurasense.soundVolume"
        static let maxPlayback = "aurasense.soundMaxPlaybackSeconds"
    }

    private var player: AVAudioPlayer?
    private var stopWorkItem: DispatchWorkItem?

    private init() {
        let defaults = UserDefaults.standard
        unlockSoundID = defaults.string(forKey: Keys.unlockSound) ?? Self.defaultUnlockSoundID
        lockSoundID = defaults.string(forKey: Keys.lockSound) ?? Self.defaultLockSoundID
        volume = defaults.object(forKey: Keys.volume) as? Double ?? 0.8
        maxPlaybackSeconds = defaults.object(forKey: Keys.maxPlayback) as? Double ?? 8
        reloadCustomSounds()
    }

    // MARK: - Storage

    public static var soundsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("AuraSense/Sounds", isDirectory: true)
    }

    private static var customDirectory: URL { soundsDirectory.appendingPathComponent("Custom", isDirectory: true) }
    private static var generatedDirectory: URL { soundsDirectory.appendingPathComponent("Generated", isDirectory: true) }

    // MARK: - Catalog

    public var auraChimes: [SoundOption] {
        AuraChime.allCases.map { chime in
            SoundOption(id: "aura:\(chime.rawValue)", kind: .auraChime, displayName: chime.displayName, fileURL: nil)
        }
    }

    private var cachedSystemSounds: [SoundOption]?

    public var systemSounds: [SoundOption] {
        if let cachedSystemSounds { return cachedSystemSounds }
        let dirs = [
            URL(fileURLWithPath: "/System/Library/Sounds"),
            FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Sounds"),
        ]
        var seen = Set<String>()
        var result: [SoundOption] = []
        for dir in dirs {
            let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
            for url in files where ["aiff", "aif", "caf", "wav", "m4a", "mp3"].contains(url.pathExtension.lowercased()) {
                let name = url.deletingPathExtension().lastPathComponent
                guard seen.insert(name).inserted else { continue }
                result.append(SoundOption(id: "system:\(name)", kind: .system, displayName: name, fileURL: url))
            }
        }
        let sorted = result.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        cachedSystemSounds = sorted
        return sorted
    }

    public var allOptions: [SoundOption] {
        [SoundOption.none] + auraChimes + systemSounds + customSounds
    }

    public func option(for id: String) -> SoundOption {
        allOptions.first { $0.id == id } ?? .none
    }

    public func reloadCustomSounds() {
        let dir = Self.customDirectory
        let files = (try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: [.creationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        customSounds = files
            .sorted { $0.lastPathComponent.localizedCaseInsensitiveCompare($1.lastPathComponent) == .orderedAscending }
            .map { url in
                SoundOption(
                    id: "custom:\(url.lastPathComponent)",
                    kind: .custom,
                    displayName: Self.displayName(forStoredFile: url),
                    fileURL: url
                )
            }
        // If a selected custom file disappeared, fall back to defaults.
        if unlockSoundID.hasPrefix("custom:") && !customSounds.contains(where: { $0.id == unlockSoundID }) {
            unlockSoundID = Self.defaultUnlockSoundID
        }
        if lockSoundID.hasPrefix("custom:") && !customSounds.contains(where: { $0.id == lockSoundID }) {
            lockSoundID = Self.defaultLockSoundID
        }
    }

    private static func displayName(forStoredFile url: URL) -> String {
        // Stored as "<8-char-id>-<original name>.<ext>"
        let base = url.deletingPathExtension().lastPathComponent
        if let dash = base.firstIndex(of: "-"), base.distance(from: base.startIndex, to: dash) == 8 {
            return String(base[base.index(after: dash)...])
        }
        return base
    }

    // MARK: - Import / Delete

    /// Shows an open panel and imports the chosen audio file. Returns the new option's id on success.
    @discardableResult
    public func presentImportPanel() -> String? {
        let panel = NSOpenPanel()
        panel.title = "Choose an Unlock Sound or Song"
        panel.prompt = "Use Sound"
        panel.allowedContentTypes = Self.supportedImportTypes
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        NSApplication.shared.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        return importSound(from: url)
    }

    /// Copies an audio file into AuraSense's sound folder after validating it can be played.
    @discardableResult
    public func importSound(from sourceURL: URL) -> String? {
        let fm = FileManager.default
        do {
            let size = (try sourceURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0 else {
                lastImportMessage = "That file is empty."
                return nil
            }
            guard size <= Self.maxImportBytes else {
                lastImportMessage = "That file is larger than 60 MB. Choose a shorter clip."
                return nil
            }
            // Validate before copying: AVAudioPlayer must be able to decode it.
            let probe = try AVAudioPlayer(contentsOf: sourceURL)
            guard probe.duration > 0 else {
                lastImportMessage = "AuraSense couldn't read any audio in that file."
                return nil
            }

            try fm.createDirectory(at: Self.customDirectory, withIntermediateDirectories: true)
            let safeName = sourceURL.deletingPathExtension().lastPathComponent
                .replacingOccurrences(of: "/", with: "-")
                .replacingOccurrences(of: ":", with: "-")
            let ext = sourceURL.pathExtension.isEmpty ? "m4a" : sourceURL.pathExtension.lowercased()
            let prefix = String(UUID().uuidString.prefix(8)).lowercased()
            let dest = Self.customDirectory.appendingPathComponent("\(prefix)-\(safeName).\(ext)")
            try fm.copyItem(at: sourceURL, to: dest)

            reloadCustomSounds()
            let id = "custom:\(dest.lastPathComponent)"
            lastImportMessage = "Added “\(safeName)” (\(Self.formatDuration(probe.duration)))."
            return id
        } catch {
            lastImportMessage = "Couldn't import that file: \(error.localizedDescription)"
            return nil
        }
    }

    public func deleteCustomSound(_ option: SoundOption) {
        guard option.kind == .custom, let url = option.fileURL else { return }
        stopPlayback()
        try? FileManager.default.removeItem(at: url)
        reloadCustomSounds()
    }

    private static func formatDuration(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        return total >= 60 ? String(format: "%d:%02d", total / 60, total % 60) : "\(total)s"
    }

    // MARK: - Playback

    public func playUnlockSound() { play(id: unlockSoundID) }
    public func playLockSound() { play(id: lockSoundID) }

    public func play(id: String) {
        let option = option(for: id)
        guard option.kind != .none else { return }
        guard let url = resolveURL(for: option) else { return }
        stopPlayback()
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.volume = Float(min(max(volume, 0), 1))
            newPlayer.prepareToPlay()
            newPlayer.play()
            player = newPlayer

            let limit = max(1, maxPlaybackSeconds)
            if newPlayer.duration > limit {
                let fade: TimeInterval = min(1.5, limit / 3)
                let item = DispatchWorkItem { [weak self, weak newPlayer] in
                    guard let self, let p = newPlayer, self.player === p else { return }
                    p.setVolume(0, fadeDuration: fade)
                    DispatchQueue.main.asyncAfter(deadline: .now() + fade) { [weak self, weak p] in
                        guard let self, let p, self.player === p else { return }
                        self.stopPlayback()
                    }
                }
                stopWorkItem = item
                DispatchQueue.main.asyncAfter(deadline: .now() + limit - fade, execute: item)
            }
        } catch {
            NSSound(named: NSSound.Name("Glass"))?.play()
        }
    }

    public func stopPlayback() {
        stopWorkItem?.cancel()
        stopWorkItem = nil
        player?.stop()
        player = nil
    }

    private func resolveURL(for option: SoundOption) -> URL? {
        switch option.kind {
        case .none:
            return nil
        case .system, .custom:
            return option.fileURL
        case .auraChime:
            let raw = option.id.replacingOccurrences(of: "aura:", with: "")
            guard let chime = AuraChime(rawValue: raw) else { return nil }
            return chime.renderedFileURL(in: Self.generatedDirectory)
        }
    }
}

// MARK: - Synthesized AuraSense chimes

/// Small signature tones rendered once to WAV with additive synthesis, so AuraSense ships
/// its own sounds without bundling audio assets.
enum AuraChime: String, CaseIterable {
    case bloom, orbit, eclipse, halo

    var displayName: String {
        switch self {
        case .bloom: return "Aura Bloom"
        case .orbit: return "Orbit Rise"
        case .eclipse: return "Eclipse Bell"
        case .halo: return "Soft Halo"
        }
    }

    /// (frequency Hz, start s, duration s, gain)
    private var notes: [(Double, Double, Double, Double)] {
        switch self {
        case .bloom:   // bright major arpeggio, C6-E6-G6-C7
            return [(1046.5, 0.00, 0.9, 0.42), (1318.5, 0.07, 0.9, 0.36), (1568.0, 0.14, 1.0, 0.32), (2093.0, 0.22, 1.2, 0.24)]
        case .orbit:   // rising fifth glide feel, A5-E6-A6
            return [(880.0, 0.00, 0.6, 0.40), (1318.5, 0.12, 0.7, 0.34), (1760.0, 0.26, 1.1, 0.30)]
        case .eclipse: // bell with inharmonic partials
            return [(659.3, 0.00, 1.8, 0.45), (1648.0, 0.00, 1.2, 0.18), (2637.0, 0.00, 0.7, 0.10)]
        case .halo:    // gentle two-note chord
            return [(784.0, 0.00, 1.4, 0.32), (1174.7, 0.05, 1.4, 0.26)]
        }
    }

    func renderedFileURL(in directory: URL) -> URL? {
        let url = directory.appendingPathComponent("\(rawValue)-v1.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try renderWAV().write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    private func renderWAV() -> Data {
        let sampleRate = 44_100.0
        let totalSeconds = (notes.map { $0.1 + $0.2 }.max() ?? 1) + 0.05
        let frameCount = Int(totalSeconds * sampleRate)
        var samples = [Double](repeating: 0, count: frameCount)

        for (freq, start, duration, gain) in notes {
            let startFrame = Int(start * sampleRate)
            let length = Int(duration * sampleRate)
            for i in 0..<length where startFrame + i < frameCount {
                let t = Double(i) / sampleRate
                let attack = min(1, t / 0.008)
                let decay = exp(-t * (3.2 / duration) * 1.6)
                let env = attack * decay
                let tone = sin(2 * .pi * freq * t) + 0.18 * sin(2 * .pi * freq * 2 * t)
                samples[startFrame + i] += tone * env * gain
            }
        }

        let peak = max(samples.map { abs($0) }.max() ?? 1, 0.0001)
        let scale = 0.85 / peak
        var pcm = Data(capacity: frameCount * 2)
        for s in samples {
            var v = Int16(max(-1, min(1, s * scale)) * Double(Int16.max)).littleEndian
            withUnsafeBytes(of: &v) { pcm.append(contentsOf: $0) }
        }

        var data = Data()
        func append<T>(_ value: T) {
            var v = value
            withUnsafeBytes(of: &v) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: Array("RIFF".utf8))
        append(UInt32(36 + pcm.count).littleEndian)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        append(UInt32(16).littleEndian)          // PCM header size
        append(UInt16(1).littleEndian)           // PCM
        append(UInt16(1).littleEndian)           // mono
        append(UInt32(44_100).littleEndian)      // sample rate
        append(UInt32(44_100 * 2).littleEndian)  // byte rate
        append(UInt16(2).littleEndian)           // block align
        append(UInt16(16).littleEndian)          // bits per sample
        data.append(contentsOf: Array("data".utf8))
        append(UInt32(pcm.count).littleEndian)
        data.append(pcm)
        return data
    }
}
