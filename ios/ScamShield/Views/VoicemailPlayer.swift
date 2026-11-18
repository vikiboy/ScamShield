import AVFoundation
import Observation
import os
import SwiftUI

/// Plays a voicemail recording from the sync folder. The file is first copied (coordinated) into
/// the app's caches, so playback doesn't depend on the folder's security scope or on iCloud.
@Observable
@MainActor
final class VoicemailPlayer {
    enum State: Equatable {
        case idle, loading, ready, failed(String)
    }

    private(set) var state: State = .idle
    private(set) var isPlaying = false
    private(set) var duration: Double
    var currentTime: Double = 0
    var isScrubbing = false

    @ObservationIgnored private var player: AVPlayer?
    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: (any NSObjectProtocol)?
    private static let log = Logger(subsystem: "local.scamshield", category: "audio")

    /// DEBUG `-ScamShieldMuteAudio` (optionally followed by YES/NO): UI tests and screenshots play silently.
    private let muted: Bool

    init(durationHint: Double?) {
        duration = max(durationHint ?? 0, 0)
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-ScamShieldMuteAudio") {
            let value = arguments.indices.contains(index + 1) ? arguments[index + 1].lowercased() : "yes"
            muted = !["no", "0", "false"].contains(value)
        } else {
            muted = false
        }
        #else
        muted = false
        #endif
    }

    func load(relativePath: String, from folder: SyncFolder?) async {
        guard state == .idle || state != .loading, player == nil else { return }
        guard let folder else {
            state = .failed("The ScamShield folder isn’t available.")
            return
        }
        state = .loading
        do {
            let cache = LocalState.audioCache
            let local = try await offMain { try folder.copyAudio(relativePath: relativePath, to: cache) }
            let item = AVPlayerItem(url: local)
            let player = AVPlayer(playerItem: item)
            if muted {
                player.isMuted = true
                player.volume = 0
                Self.log.notice("Voicemail playback muted by -ScamShieldMuteAudio")
            }
            self.player = player
            if let seconds = try? await item.asset.load(.duration).seconds, seconds.isFinite, seconds > 0 {
                duration = seconds
            }
            timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 10),
                                                          queue: .main) { [weak self] time in
                MainActor.assumeIsolated {
                    guard let self, !self.isScrubbing else { return }
                    self.currentTime = time.seconds
                }
            }
            endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification,
                                                                 object: item, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.finished()
                }
            }
            state = .ready
        } catch {
            Self.log.error("Voicemail unavailable: \(error.localizedDescription, privacy: .public)")
            state = .failed((error as? SyncError)?.errorDescription ?? "The recording isn’t available right now.")
        }
    }

    func togglePlayback() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
            return
        }
        if !muted {
            do {
                let session = AVAudioSession.sharedInstance()
                try session.setCategory(.playback, mode: .spokenAudio)
                try session.setActive(true)
            } catch {
                Self.log.error("Audio session: \(error.localizedDescription, privacy: .public)")
            }
        }
        if duration > 0, currentTime >= duration - 0.05 {
            seek(to: 0)
        }
        player.play()
        isPlaying = true
    }

    func seek(to seconds: Double) {
        currentTime = seconds
        player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func stop() {
        player?.pause()
        isPlaying = false
        if let timeObserver { player?.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player = nil
        if state == .ready { state = .idle }
        if !muted { try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation) }
    }

    private func finished() {
        isPlaying = false
        currentTime = duration
    }
}

struct VoicemailPlayerView: View {
    let relativePath: String
    @Environment(InboxStore.self) private var store
    @State private var player: VoicemailPlayer

    @ScaledMetric(relativeTo: .title) private var buttonSize = 44

    init(relativePath: String, durationHint: Double?) {
        self.relativePath = relativePath
        _player = State(initialValue: VoicemailPlayer(durationHint: durationHint))
    }

    var body: some View {
        Group {
            if case .failed(let message) = player.state {
                Label(message, systemImage: "speaker.slash")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                HStack(spacing: 14) {
                    Button {
                        player.togglePlayback()
                    } label: {
                        ZStack {
                            Circle().fill(Color.accentColor)
                            if player.state == .loading {
                                ProgressView().tint(.white)
                            } else {
                                Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                                    .font(.system(size: buttonSize * 0.4, weight: .bold))
                                    .foregroundStyle(.white)
                                    .offset(x: player.isPlaying ? 0 : buttonSize * 0.03)
                            }
                        }
                        .frame(width: buttonSize, height: buttonSize)
                    }
                    .buttonStyle(.plain)
                    .disabled(player.state != .ready)
                    .accessibilityLabel(player.isPlaying ? "Pause voicemail" : "Play voicemail")
                    .accessibilityIdentifier("voicemail.playPause")

                    VStack(spacing: 2) {
                        Slider(value: Binding(get: { player.currentTime }, set: { player.currentTime = $0 }),
                               in: 0...max(player.duration, 0.1)) { editing in
                            player.isScrubbing = editing
                            if !editing { player.seek(to: player.currentTime) }
                        }
                        .disabled(player.state != .ready)
                        .accessibilityLabel("Playback position")
                        .accessibilityValue(Format.duration(player.currentTime))
                        HStack {
                            Text(Format.duration(player.currentTime))
                            Spacer()
                            Text("-" + Format.duration(max(player.duration - player.currentTime, 0)))
                        }
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                    }
                }
                .padding(.vertical, 4)
            }
        }
        .task(id: relativePath) {
            await player.load(relativePath: relativePath, from: store.folder)
        }
        .onDisappear { player.stop() }
    }
}
