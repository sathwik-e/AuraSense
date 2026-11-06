import SwiftUI
import AppKit

/// Dashboard section for choosing the unlock/lock sound (built-in or your own audio file)
/// and the unlock animation.
public struct UnlockExperienceView: View {
    @ObservedObject var engine = BLEProximityEngine.shared
    @ObservedObject var sounds = UnlockSoundLibrary.shared
    @ObservedObject var celebration = UnlockCelebrationCoordinator.shared

    public init() {}

    public var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                unlockSoundCard
                lockSoundCard
                customSoundsCard
                animationCard
            }
            .padding(24)
        }
        .onAppear { sounds.reloadCustomSounds() }
        .onDisappear { sounds.stopPlayback() }
    }

    // MARK: - Unlock sound

    private var unlockSoundCard: some View {
        AuraGlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Unlock Sound")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                        Text("Plays once macOS confirms AuraSense unlocked your Mac.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Sounds", isOn: $engine.playSoundEffects)
                        .toggleStyle(.switch)
                }

                soundPicker(selection: $sounds.unlockSoundID, label: "Sound")
                    .disabled(!engine.playSoundEffects)

                HStack(spacing: 12) {
                    Image(systemName: "speaker.fill").foregroundStyle(.secondary)
                    Slider(value: $sounds.volume, in: 0...1)
                    Image(systemName: "speaker.wave.3.fill").foregroundStyle(.secondary)
                    Text("\(Int(sounds.volume * 100))%")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                        .frame(width: 44, alignment: .trailing)
                }
                .disabled(!engine.playSoundEffects)

                HStack(spacing: 12) {
                    Text("Long sounds and songs fade out after")
                        .font(.system(size: 12))
                    Stepper(value: $sounds.maxPlaybackSeconds, in: 2...30, step: 1) {
                        Text("\(Int(sounds.maxPlaybackSeconds))s")
                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    }
                    .fixedSize()
                    Spacer()
                }
                .disabled(!engine.playSoundEffects)
            }
        }
    }

    // MARK: - Lock sound

    private var lockSoundCard: some View {
        AuraGlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Lock Sound")
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                Text("Plays when AuraSense locks your Mac as you walk away.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                soundPicker(selection: $sounds.lockSoundID, label: "Sound")
                    .disabled(!engine.playSoundEffects)
            }
        }
    }

    // MARK: - Custom sounds

    private var customSoundsCard: some View {
        AuraGlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Your Sounds")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                        Text("Add a song or sound file (MP3, M4A, WAV, AIFF, up to 60 MB). AuraSense copies it to this Mac in ~/Library/Application Support/AuraSense/Sounds.")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        if let id = sounds.presentImportPanel() {
                            sounds.unlockSoundID = id
                            engine.playSoundEffects = true
                        }
                    } label: {
                        Label("Add Sound…", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AuraTheme.indigoGlow)
                }

                if let message = sounds.lastImportMessage {
                    Text(message)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(message.hasPrefix("Added") ? AuraTheme.emeraldGlow : AuraTheme.amberGlow)
                }

                if sounds.customSounds.isEmpty {
                    Text("No custom sounds yet.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                } else {
                    ForEach(sounds.customSounds) { option in
                        HStack(spacing: 10) {
                            Image(systemName: "music.note")
                                .foregroundStyle(AuraTheme.cyanGlow)
                                .frame(width: 20)
                            Text(option.displayName)
                                .font(.system(size: 13, weight: .medium))
                                .lineLimit(1)
                            if sounds.unlockSoundID == option.id {
                                AuraStatusPill(title: "Unlock", symbol: "lock.open.fill", color: AuraTheme.emeraldGlow)
                            }
                            if sounds.lockSoundID == option.id {
                                AuraStatusPill(title: "Lock", symbol: "lock.fill", color: AuraTheme.crimsonGlow)
                            }
                            Spacer()
                            Button {
                                sounds.play(id: option.id)
                            } label: {
                                Image(systemName: "play.fill")
                            }
                            .buttonStyle(.bordered)
                            .help("Preview")
                            Button("Use for Unlock") {
                                sounds.unlockSoundID = option.id
                            }
                            .buttonStyle(.bordered)
                            .disabled(sounds.unlockSoundID == option.id)
                            Button(role: .destructive) {
                                sounds.deleteCustomSound(option)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.bordered)
                            .help("Remove this sound from AuraSense")
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
                    }
                }
            }
        }
    }

    // MARK: - Animation

    private var animationCard: some View {
        AuraGlassCard(padding: 20) {
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Unlock Animation")
                            .font(.system(size: 18, weight: .bold, design: .rounded))
                        Text("A short eclipse animation on every display when AuraSense unlocks your Mac. It never blocks clicks or typing, and it is simplified when Reduce Motion is on.")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Toggle("Animation", isOn: $celebration.showUnlockAnimation)
                        .toggleStyle(.switch)
                        .labelsHidden()
                }

                Toggle(isOn: $celebration.celebrateManualUnlocks) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Also play when I unlock manually")
                            .font(.system(size: 13, weight: .medium))
                        Text("Use the sound and animation for Touch ID, Apple Watch, and typed-password unlocks too.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)

                HStack(spacing: 10) {
                    Button {
                        celebration.previewAnimationOnly()
                    } label: {
                        Label("Preview Animation", systemImage: "sparkles")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        celebration.celebrate(deviceName: engine.selectedDeviceName, forcePreview: true)
                    } label: {
                        Label("Preview Sound + Animation", systemImage: "play.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(AuraTheme.indigoGlow)
                }
            }
        }
    }

    // MARK: - Picker

    private func soundPicker(selection: Binding<String>, label: String) -> some View {
        HStack(spacing: 10) {
            // Preview only when the user picks a sound (not when a deleted file resets the selection).
            Picker(label, selection: Binding(
                get: { selection.wrappedValue },
                set: { newValue in
                    selection.wrappedValue = newValue
                    sounds.play(id: newValue)
                }
            )) {
                Text(SoundOption.none.displayName).tag(SoundOption.none.id)
                Section("AuraSense") {
                    ForEach(sounds.auraChimes) { Text($0.displayName).tag($0.id) }
                }
                Section("macOS") {
                    ForEach(sounds.systemSounds) { Text($0.displayName).tag($0.id) }
                }
                if !sounds.customSounds.isEmpty {
                    Section("Your Sounds") {
                        ForEach(sounds.customSounds) { Text($0.displayName).tag($0.id) }
                    }
                }
            }
            .frame(maxWidth: 360)

            Button {
                sounds.play(id: selection.wrappedValue)
            } label: {
                Label("Preview", systemImage: "play.fill")
            }
            .buttonStyle(.bordered)
            .disabled(selection.wrappedValue == SoundOption.none.id)
        }
    }
}
