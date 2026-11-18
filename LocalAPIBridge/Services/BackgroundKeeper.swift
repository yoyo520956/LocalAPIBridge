import AVFoundation
import Combine
import UIKit

/// 后台保活：循环播放一段静音 WAV，并请求音频后台模式。
///
/// iOS 在 App 进入后台后默认会挂起进程，监听中的本地端口也会随之停摆。
/// 声明 `UIBackgroundModes = audio` 并持续播放音频，可以让 App 在后台继续运行，
/// 从而让本地 HTTP 服务和轮询保持可用。代价是耗电，且这种方式不符合
/// App Store 对后台音频用途的审核要求，适合个人自用 / 侧载。
@MainActor
final class BackgroundKeeper: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var lastError: String?
    @Published private(set) var isScreenAlwaysOn = false

    private var player: AVAudioPlayer?
    private var interruptionObserver: NSObjectProtocol?
    private var sessionActivated = false

    @discardableResult
    func start() -> Bool {
        guard !isActive else { return true }
        lastError = nil
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            sessionActivated = true

            let url = try SilentAudio.fileURL()
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            newPlayer.numberOfLoops = -1
            newPlayer.volume = 0.02
            newPlayer.prepareToPlay()
            guard newPlayer.play() else {
                throw NSError(domain: "LocalAPIBridge", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "静音播放器启动失败"
                ])
            }
            player = newPlayer
            isActive = true
            registerInterruptionObserver()
            return true
        } catch {
            player?.stop()
            player = nil
            isActive = false
            sessionActivated = false
            lastError = error.localizedDescription
            return false
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isActive = false
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        // 不主动 deactivate：画中画可能正在共用这个音频会话。
        sessionActivated = false
    }

    /// 调试 / 长时间观察时让屏幕不自动锁定（由用户在设置里手动开启）。
    func setScreenAlwaysOn(_ enabled: Bool) {
        isScreenAlwaysOn = enabled
        UIApplication.shared.isIdleTimerDisabled = enabled
    }

    private func registerInterruptionObserver() {
        guard interruptionObserver == nil else { return }
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self else { return }
            guard let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawValue) else {
                return
            }
            if type == .ended {
                Task { @MainActor in
                    try? AVAudioSession.sharedInstance().setActive(true)
                    self.player?.play()
                }
            }
        }
    }
}
