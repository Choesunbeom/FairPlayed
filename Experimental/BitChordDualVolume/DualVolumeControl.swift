#if os(iOS)
import SwiftUI
import UIKit
import AVFAudio
import MediaPlayer

// A single volume bar with two independent controls:
//   - tap/ordinary drag: iOS hardware/system volume (white)
//   - hold for 0.42 s, then drag: BitChord's native output gain (orange)
// We deliberately do not change AVAudioSession category/mixWithOthers.
struct DualVolumeControl: UIViewRepresentable {
    @Binding var appVolume: Double

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> DualVolumeTrackView {
        let view = DualVolumeTrackView()
        let coordinator = context.coordinator
        view.onAppVolumeChange = { [weak coordinator] value in
            coordinator?.parent.appVolume = value
        }
        view.appVolume = appVolume
        return view
    }

    func updateUIView(_ uiView: DualVolumeTrackView, context: Context) {
        context.coordinator.parent = self
        uiView.appVolume = appVolume
    }

    final class Coordinator {
        var parent: DualVolumeControl
        init(_ parent: DualVolumeControl) { self.parent = parent }
    }
}

final class DualVolumeTrackView: UIView {
    private enum TouchMode {
        case idle, waiting, system, app
    }

    var onAppVolumeChange: ((Double) -> Void)?
    var appVolume: Double = 0.9 {
        didSet { setNeedsDisplay() }
    }

    private var touchMode: TouchMode = .idle
    private var startPoint: CGPoint = .zero
    private var holdTimer: Timer?
    private var systemVolume: CGFloat = CGFloat(AVAudioSession.sharedInstance().outputVolume) {
        didSet { setNeedsDisplay(); refreshAccessibility() }
    }
    private var observation: NSKeyValueObservation?
    // MPVolumeView is Apple's public volume UI; its internal UISlider lets
    // this custom visual track preserve the standard device-volume control.
    private let nativeVolumeView = MPVolumeView(frame: .zero)

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        isMultipleTouchEnabled = false
        contentMode = .redraw

        nativeVolumeView.showsRouteButton = false
        nativeVolumeView.showsVolumeSlider = true
        nativeVolumeView.alpha = 0.015
        nativeVolumeView.isUserInteractionEnabled = false
        addSubview(nativeVolumeView)
        nativeVolumeView.frame = CGRect(x: -30, y: -30, width: 1, height: 1)

        observation = AVAudioSession.sharedInstance().observe(
            \.outputVolume,
            options: [.initial, .new]
        ) { [weak self] session, change in
            let level = CGFloat(change.newValue ?? session.outputVolume)
            DispatchQueue.main.async { [weak self] in
                self?.systemVolume = min(max(level, 0), 1)
            }
        }
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityHint = "Swipe to adjust system volume. Press and hold, then drag, to adjust BitChord volume."
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Increase BitChord volume", target: self, selector: #selector(increaseAppVolume)),
            UIAccessibilityCustomAction(name: "Decrease BitChord volume", target: self, selector: #selector(decreaseAppVolume))
        ]
        refreshAccessibility()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        holdTimer?.invalidate()
        observation?.invalidate()
    }

    private func refreshAccessibility() {
        accessibilityLabel = "System volume"
        accessibilityValue = "System \\(Int((systemVolume * 100).rounded())) percent. BitChord \\(Int((appVolume * 100).rounded())) percent."
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // Keep the public MPVolumeView in our hierarchy and out of the touch area.
        nativeVolumeView.frame = CGRect(x: -30, y: -30, width: 1, height: 1)
    }

    override func draw(_ rect: CGRect) {
        guard bounds.width > 2, bounds.height > 1 else { return }
        let width = bounds.width
        let system = min(max(systemVolume, 0), 1)
        let local = CGFloat(min(max(appVolume, 0), 1))

        func capsule(_ rect: CGRect, _ color: UIColor) {
            guard rect.width > 0, rect.height > 0 else { return }
            color.setFill()
            UIBezierPath(roundedRect: rect, cornerRadius: rect.height / 2).fill()
        }

        // System volume is the wide white line, like the original slider.
        let y = bounds.midY - 5
        let height: CGFloat = touchMode == .system ? 7 : 5
        capsule(CGRect(x: 0, y: y, width: width, height: height), .white.withAlphaComponent(0.23))
        capsule(CGRect(x: 0, y: y, width: width * system, height: height), .white.withAlphaComponent(0.90))

        // The independent gain is ALWAYS shown below as a slim orange line.
        // The emphasized orange bar shows which control is held.
        let orangeHeight: CGFloat = touchMode == .app ? 5 : 3
        let orangeY = bounds.midY + 5
        capsule(CGRect(x: 0, y: orangeY, width: width, height: orangeHeight),
                .systemOrange.withAlphaComponent(0.24))
        capsule(CGRect(x: 0, y: orangeY, width: width * local, height: orangeHeight),
                .systemOrange)
        let dotSize: CGFloat = touchMode == .app ? 9 : 5
        let dotX = min(max(width * local - dotSize / 2, 0), width - dotSize)
        capsule(CGRect(x: dotX, y: orangeY - (dotSize - orangeHeight) / 2,
                       width: dotSize, height: dotSize), .systemOrange)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        holdTimer?.invalidate()
        startPoint = touch.location(in: self)
        touchMode = .waiting
        setNeedsDisplay()

        let timer = Timer(timeInterval: 0.42, repeats: false) { [weak self] _ in
            guard let self = self, self.touchMode == .waiting else { return }
            self.touchMode = .app
            self.setNeedsDisplay()
            Haptics.play(.select)
        }
        holdTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard let touch = touches.first else { return }
        let point = touch.location(in: self)
        if touchMode == .waiting {
            if hypot(point.x - startPoint.x, point.y - startPoint.y) > 9 {
                holdTimer?.invalidate()
                holdTimer = nil
                touchMode = .system
            }
        }
        switch touchMode {
        case .system:
            setSystemVolume(at: point)
        case .app:
            setAppVolume(at: point)
        case .idle, .waiting:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        if touchMode == .waiting, let touch = touches.first {
            // A tap, even without a drag, continues to act on iOS volume.
            setSystemVolume(at: touch.location(in: self))
        }
        resetTouch()
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        resetTouch()
    }

    private func resetTouch() {
        holdTimer?.invalidate()
        holdTimer = nil
        touchMode = .idle
        setNeedsDisplay()
    }

    private func clampedFraction(at point: CGPoint) -> CGFloat {
        guard bounds.width > 0 else { return 0 }
        return min(max(point.x / bounds.width, 0), 1)
    }

    private func setSystemVolume(at point: CGPoint) {
        let next = Float(clampedFraction(at: point))
        guard let slider = findSystemSlider(in: nativeVolumeView) else { return }
        slider.value = next
        slider.sendActions(for: .valueChanged)
        systemVolume = CGFloat(next)
    }

    private func findSystemSlider(in view: UIView) -> UISlider? {
        if let slider = view as? UISlider { return slider }
        for child in view.subviews {
            if let slider = findSystemSlider(in: child) { return slider }
        }
        return nil
    }

    private func setAppVolume(at point: CGPoint) {
        setAppVolume(Double(clampedFraction(at: point)))
    }

    private func setAppVolume(_ value: Double) {
        let bounded = min(max(value, 0), 1)
        appVolume = bounded
        onAppVolumeChange?(bounded)
        refreshAccessibility()
    }

    override func accessibilityIncrement() {
        setSystemVolume(at: CGPoint(x: bounds.width * min(1, systemVolume + 0.05), y: bounds.midY))
    }

    override func accessibilityDecrement() {
        setSystemVolume(at: CGPoint(x: bounds.width * max(0, systemVolume - 0.05), y: bounds.midY))
    }

    @objc private func increaseAppVolume() -> Bool {
        setAppVolume(appVolume + 0.05)
        Haptics.play(.select)
        return true
    }

    @objc private func decreaseAppVolume() -> Bool {
        setAppVolume(appVolume - 0.05)
        Haptics.play(.select)
        return true
    }
}
#endif
