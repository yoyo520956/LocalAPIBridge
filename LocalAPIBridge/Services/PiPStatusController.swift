import AVFoundation
import AVKit
import Combine
import UIKit

/// 画中画浮窗需要显示的数据快照。
struct PiPStatusData {
    var modelName: String
    var contextUsed: Int?
    var contextLimit: Int
    var serverRunning: Bool
    var polling: Bool
    var pollCount: Int
    var successCount: Int

    static let placeholder = PiPStatusData(
        modelName: "未识别",
        contextUsed: nil,
        contextLimit: 128_000,
        serverRunning: false,
        polling: false,
        pollCount: 0,
        successCount: 0
    )
}

private struct PiPOverlayContent {
    var statusText: String
    var statusOK: Bool
    var modelName: String
    var contextText: String
    var contextFraction: Double
    var timeText: String
    var systemUptimeText: String
    var appUptimeText: String
    var pollText: String
}

/// 使用 iOS 原生画中画（AVPictureInPictureVideoCallViewController）做后台保活，
/// 并在浮窗里实时显示模型、上下文使用、时间、系统运行秒数。
@MainActor
final class PiPStatusController: NSObject, ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var isActive = false
    @Published private(set) var isPossible = false
    @Published private(set) var lastError: String?

    let isSupported: Bool

    private var pipController: AVPictureInPictureController?
    private var possibleObservation: NSKeyValueObservation?
    private weak var sourceView: UIView?
    private var statusProvider: (() -> PiPStatusData)?
    private let pipHostViewController = AVPictureInPictureVideoCallViewController()
    private let statsViewController = PiPStatsViewController(nibName: nil, bundle: nil)
    private var timer: Timer?
    private var silentPlayer: AVAudioPlayer?
    private var interruptionObserver: NSObjectProtocol?
    private let launchDate = Date()

    override init() {
        isSupported = AVPictureInPictureController.isPictureInPictureSupported()
        super.init()
        setupHostViewController()
    }

    private func setupHostViewController() {
        pipHostViewController.preferredContentSize = CGSize(width: 640, height: 360)
        pipHostViewController.addChild(statsViewController)
        statsViewController.view.translatesAutoresizingMaskIntoConstraints = false
        pipHostViewController.view.addSubview(statsViewController.view)
        NSLayoutConstraint.activate([
            statsViewController.view.leadingAnchor.constraint(equalTo: pipHostViewController.view.leadingAnchor),
            statsViewController.view.trailingAnchor.constraint(equalTo: pipHostViewController.view.trailingAnchor),
            statsViewController.view.topAnchor.constraint(equalTo: pipHostViewController.view.topAnchor),
            statsViewController.view.bottomAnchor.constraint(equalTo: pipHostViewController.view.bottomAnchor)
        ])
        statsViewController.didMove(toParent: pipHostViewController)
    }

    /// SwiftUI 里的 1×1 视图作为画中画的来源锚点，同时注入实时数据源。
    func attach(sourceView: UIView, statusProvider: @escaping () -> PiPStatusData) {
        if self.sourceView !== sourceView {
            self.sourceView = sourceView
            if pipController?.isPictureInPictureActive != true {
                pipController?.stopPictureInPicture()
                pipController = nil
                possibleObservation = nil
                isPossible = false
                isActive = false
            }
        }
        self.statusProvider = statusProvider
        refreshContent()
        if isEnabled {
            buildControllerIfNeeded()
        }
    }

    func setEnabled(_ enabled: Bool) {
        if enabled {
            enable()
        } else {
            disable()
        }
    }

    func startNow() {
        guard isEnabled else {
            lastError = "请先打开画中画保活开关"
            return
        }
        if silentPlayer == nil { activateAudio() }
        buildControllerIfNeeded()
        guard let controller = pipController else {
            lastError = "画中画尚未就绪"
            return
        }
        if controller.isPictureInPicturePossible {
            if !controller.isPictureInPictureActive {
                controller.startPictureInPicture()
            }
            return
        }

        // 刚打开开关时 possible 需要几帧才变 true，稍等后重试一次。
        lastError = nil
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard self.isEnabled, let controller = self.pipController else { return }
            if controller.isPictureInPicturePossible {
                if !controller.isPictureInPictureActive {
                    controller.startPictureInPicture()
                }
            } else {
                self.lastError = "画中画暂时不可用，请回到前台稍后再试"
            }
        }
    }

    /// App 进入后台时再兜底尝试一次；正常情况下由自动画中画接管。
    func startIfPossible() {
        guard isEnabled, let controller = pipController else { return }
        if silentPlayer == nil { activateAudio() }
        refreshContent()
        if controller.isPictureInPicturePossible, !controller.isPictureInPictureActive {
            controller.startPictureInPicture()
        }
    }

    // MARK: - 生命周期

    private func enable() {
        lastError = nil
        guard isSupported else {
            isEnabled = false
            lastError = "此设备或系统版本不支持画中画"
            return
        }
        isEnabled = true
        activateAudio()
        registerInterruptionObserver()
        startTimer()
        refreshContent()
        buildControllerIfNeeded()
    }

    private func disable() {
        isEnabled = false
        isActive = false
        pipController?.stopPictureInPicture()
        pipController?.canStartPictureInPictureAutomaticallyFromInline = false
        timer?.invalidate()
        timer = nil
        silentPlayer?.stop()
        silentPlayer = nil
        if let observer = interruptionObserver {
            NotificationCenter.default.removeObserver(observer)
            interruptionObserver = nil
        }
        possibleObservation = nil
        isPossible = false
    }

    private func buildControllerIfNeeded() {
        guard isEnabled else { return }
        if let existing = pipController {
            existing.canStartPictureInPictureAutomaticallyFromInline = true
            return
        }
        guard let sourceView else { return }

        let contentSource = AVPictureInPictureController.ContentSource(
            activeVideoCallSourceView: sourceView,
            contentViewController: pipHostViewController
        )
        let controller = AVPictureInPictureController(contentSource: contentSource)
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = self

        possibleObservation = controller.observe(
            \.isPictureInPicturePossible,
            options: [.initial, .new]
        ) { [weak self] observed, _ in
            let possible = observed.isPictureInPicturePossible
            Task { @MainActor in
                self?.isPossible = possible
            }
        }

        pipController = controller
        isPossible = controller.isPictureInPicturePossible
    }

    private func activateAudio() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback, options: [.mixWithOthers])
        try? session.setActive(true)

        guard silentPlayer == nil else { return }
        guard let url = try? SilentAudio.fileURL(),
              let player = try? AVAudioPlayer(contentsOf: url) else {
            lastError = "无法创建静音播放器"
            return
        }
        player.numberOfLoops = -1
        player.volume = 0.02
        if player.play() {
            silentPlayer = player
        } else {
            silentPlayer = nil
            lastError = "静音播放器启动失败"
        }
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
                    if self.silentPlayer?.play() != true {
                        self.silentPlayer = nil
                        self.activateAudio()
                    }
                }
            }
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let newTimer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refreshContent()
            }
        }
        RunLoop.main.add(newTimer, forMode: .common)
        timer = newTimer
    }

    // MARK: - 内容更新

    private func refreshContent() {
        let data = statusProvider?() ?? .placeholder
        let now = Date()

        let statusText: String
        let statusOK: Bool
        if data.serverRunning && data.polling {
            statusText = "运行中"
            statusOK = true
        } else if data.serverRunning {
            statusText = "服务运行 · 轮询暂停"
            statusOK = false
        } else {
            statusText = "服务未运行"
            statusOK = false
        }

        let limit = max(data.contextLimit, 1)
        let fraction: Double
        let contextText: String
        if let used = data.contextUsed {
            fraction = min(1.0, max(0.0, Double(used) / Double(limit)))
            contextText = "\(formatted(used)) / \(formatted(limit))  \(Int(fraction * 100))%"
        } else {
            fraction = 0
            contextText = "— / \(formatted(limit))"
        }

        statsViewController.update(
            PiPOverlayContent(
                statusText: statusText,
                statusOK: statusOK,
                modelName: data.modelName,
                contextText: contextText,
                contextFraction: fraction,
                timeText: Self.timeFormatter.string(from: now),
                systemUptimeText: "\(Int(ProcessInfo.processInfo.systemUptime)) 秒",
                appUptimeText: "\(Int(now.timeIntervalSince(launchDate))) 秒",
                pollText: "\(data.pollCount) 次 · 成功 \(data.successCount)"
            )
        )
    }

    private func formatted(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}

// MARK: - AVPictureInPictureControllerDelegate

extension PiPStatusController: AVPictureInPictureControllerDelegate {
    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = true
        startTimer()
        refreshContent()
    }

    func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = true
        lastError = nil
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        failedToStartPictureInPictureWithError error: Error
    ) {
        lastError = error.localizedDescription
        isActive = false
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isActive = false
        lastError = nil
        if isEnabled {
            pipController = nil
            possibleObservation = nil
            buildControllerIfNeeded()
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}

// MARK: - 浮窗界面

@MainActor
private final class PiPStatsViewController: UIViewController {
    private let gradientLayer = CAGradientLayer()
    private let titleLabel = UILabel()
    private let statusLabel = UILabel()
    private let modelLabel = UILabel()
    private let contextLabel = UILabel()
    private let progressView = UIProgressView(progressViewStyle: .default)
    private let timeLabel = UILabel()
    private let systemUptimeLabel = UILabel()
    private let footerLabel = UILabel()

    override func viewDidLoad() {
        super.viewDidLoad()
        preferredContentSize = CGSize(width: 640, height: 360)
        view.backgroundColor = UIColor(red: 0.035, green: 0.06, blue: 0.10, alpha: 1)
        view.clipsToBounds = true

        gradientLayer.colors = [
            UIColor(red: 0.04, green: 0.09, blue: 0.17, alpha: 1).cgColor,
            UIColor(red: 0.02, green: 0.04, blue: 0.07, alpha: 1).cgColor
        ]
        gradientLayer.startPoint = CGPoint(x: 0, y: 0)
        gradientLayer.endPoint = CGPoint(x: 1, y: 1)
        view.layer.insertSublayer(gradientLayer, at: 0)

        configureLabels()

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, UIView(), statusLabel])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = 8

        let stack = UIStackView(arrangedSubviews: [
            titleRow,
            modelLabel,
            contextLabel,
            progressView,
            timeLabel,
            systemUptimeLabel,
            footerLabel
        ])
        stack.axis = .vertical
        stack.alignment = .fill
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 28),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -28),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])

        progressView.heightAnchor.constraint(equalToConstant: 4).isActive = true
        progressView.trackTintColor = UIColor.white.withAlphaComponent(0.12)
        progressView.progressTintColor = .systemBlue

        update(
            PiPOverlayContent(
                statusText: "初始化中",
                statusOK: false,
                modelName: "未识别",
                contextText: "— / 128,000",
                contextFraction: 0,
                timeText: "--:--:--",
                systemUptimeText: "-- 秒",
                appUptimeText: "-- 秒",
                pollText: "0 次"
            )
        )
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        gradientLayer.frame = view.bounds
    }

    func update(_ content: PiPOverlayContent) {
        statusLabel.text = "● \(content.statusText)"
        statusLabel.textColor = content.statusOK ? .systemGreen : .systemOrange
        modelLabel.text = "模型  \(content.modelName)"
        contextLabel.text = "上下文  \(content.contextText)"
        progressView.progress = Float(content.contextFraction)
        timeLabel.text = "时间  \(content.timeText)"
        systemUptimeLabel.text = "系统运行  \(content.systemUptimeText)"
        footerLabel.text = "本 App 运行 \(content.appUptimeText) · 轮询 \(content.pollText)"
    }

    private func configureLabels() {
        titleLabel.text = "LOCAL API BRIDGE"
        titleLabel.textColor = UIColor.white.withAlphaComponent(0.55)
        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.setContentHuggingPriority(.required, for: .horizontal)

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.textAlignment = .right

        modelLabel.font = .systemFont(ofSize: 24, weight: .bold)
        modelLabel.textColor = .white
        modelLabel.adjustsFontSizeToFitWidth = true
        modelLabel.minimumScaleFactor = 0.55
        modelLabel.numberOfLines = 1

        contextLabel.font = .monospacedSystemFont(ofSize: 18, weight: .medium)
        contextLabel.textColor = UIColor(red: 0.62, green: 0.82, blue: 1.0, alpha: 1)
        contextLabel.adjustsFontSizeToFitWidth = true
        contextLabel.minimumScaleFactor = 0.7

        timeLabel.font = .monospacedSystemFont(ofSize: 18, weight: .regular)
        timeLabel.textColor = UIColor.white.withAlphaComponent(0.9)

        systemUptimeLabel.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        systemUptimeLabel.textColor = UIColor.white.withAlphaComponent(0.9)

        footerLabel.font = .systemFont(ofSize: 12, weight: .regular)
        footerLabel.textColor = UIColor.white.withAlphaComponent(0.45)
        footerLabel.adjustsFontSizeToFitWidth = true
        footerLabel.minimumScaleFactor = 0.7
    }
}