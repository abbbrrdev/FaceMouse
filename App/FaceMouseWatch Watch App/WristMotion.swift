import Foundation
import Combine
import CoreMotion
import WatchKit
import simd

nonisolated enum WatchMode: String, Sendable {
    /// Взмахи рукой → ←/→, Double Tap → Play/Pause, колёсико → громкость
    case gestures
    /// «Аэромышь»: направление предплечья → курсор, Double Tap → клик
    case mouse
}

/// Читает гироскоп часов и превращает движения руки в команды.
///
/// Всё считается в системе координат часов, без зависимости от того, на какой руке часы:
///  - «вверх» мира = −gravity (гравитация уже в координатах часов);
///  - поворот влево/вправо = вращение вокруг «вверх»;
///  - подъём/опускание руки = вращение вокруг оси «предплечье × вверх».
@MainActor
final class WristMotion: ObservableObject {
    @Published var mode: WatchMode = .gestures {
        didSet { calibrate() }
    }
    /// Если взмах вправо срабатывает как «влево» — включи.
    @Published var invertSwipes = UserDefaults.standard.bool(forKey: "invertSwipes") {
        didSet { UserDefaults.standard.set(invertSwipes, forKey: "invertSwipes") }
    }
    /// Если в режиме мыши курсор едет вниз, когда поднимаешь руку — включи.
    @Published var invertPitch = UserDefaults.standard.bool(forKey: "invertPitch") {
        didSet { UserDefaults.standard.set(invertPitch, forKey: "invertPitch") }
    }
    @Published private(set) var lastGesture = ""

    var onMessage: ((FaceMessage) -> Void)?

    private enum Threshold {
        /// рад/с вокруг вертикали — резкий взмах рукой влево/вправо
        static let swipeRate = 3.5
        /// после взмаха рука возвращается обратно — этот обратный ход игнорируем
        static let swipeCooldown = 0.7
        /// ниже этого шум гироскопа не интегрируем (меньше дрейф аэромыши)
        static let noiseRate = 0.02
        /// частота отправки позы на iPhone
        static let poseInterval = 1.0 / 25
    }

    private let manager = CMMotionManager()
    private var isActive = true
    private var cooldownUntil: TimeInterval = 0
    private var lastSample: TimeInterval?
    private var lastPoseSent: TimeInterval = 0
    private var yaw: Double = 0    // градусы, >0 вправо
    private var pitch: Double = 0  // градусы, >0 вверх
    private var lastGestureClear: DispatchWorkItem?

    func start() {
        guard manager.isDeviceMotionAvailable, !manager.isDeviceMotionActive else { return }
        manager.deviceMotionUpdateInterval = 1.0 / 50
        manager.startDeviceMotionUpdates(to: .main) { [weak self] motion, _ in
            guard let motion else { return }
            let g = motion.gravity
            let r = motion.rotationRate
            let gravity = SIMD3(g.x, g.y, g.z)
            let rate = SIMD3(r.x, r.y, r.z)
            let time = motion.timestamp
            MainActor.assumeIsolated {
                self?.process(gravity: gravity, rate: rate, time: time)
            }
        }
    }

    func stop() {
        manager.stopDeviceMotionUpdates()
    }

    /// Экран часов активен (рука поднята). В режиме мыши это «сцепление»:
    /// поднял руку — центр там, куда сейчас указываешь; опустил — курсор не трогаем.
    func setActive(_ active: Bool) {
        isActive = active
        if active { calibrate() }
    }

    /// Текущее направление руки = центр экрана.
    func calibrate() {
        yaw = 0
        pitch = 0
        lastSample = nil
    }

    func show(_ text: String) {
        lastGesture = text
        lastGestureClear?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.lastGesture = "" }
        }
        lastGestureClear = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
    }

    // MARK: - Обработка

    private func process(gravity: SIMD3<Double>, rate: SIMD3<Double>, time: TimeInterval) {
        let dt = lastSample.map { min(time - $0, 0.1) } ?? 0
        lastSample = time

        guard simd_length(gravity) > 0.5 else { return }
        let up = -simd_normalize(gravity)
        let yawRate = simd_dot(rate, up) // >0 — поворот влево (против часовой, если смотреть сверху)

        switch mode {
        case .gestures:
            detectSwipe(yawRate: yawRate, time: time)
        case .mouse:
            integratePointer(up: up, rate: rate, yawRate: yawRate, dt: dt, time: time)
        }
    }

    private func detectSwipe(yawRate: Double, time: TimeInterval) {
        guard time >= cooldownUntil, abs(yawRate) > Threshold.swipeRate else { return }
        cooldownUntil = time + Threshold.swipeCooldown
        var toLeft = yawRate > 0
        if invertSwipes { toLeft.toggle() }
        onMessage?(.media(toLeft ? .arrowLeft : .arrowRight))
        WKInterfaceDevice.current().play(.click)
        show(toLeft ? "⬅︎" : "➡︎")
    }

    private func integratePointer(up: SIMD3<Double>, rate: SIMD3<Double>, yawRate: Double, dt: Double, time: TimeInterval) {
        guard isActive, dt > 0 else { return }

        // Ось x часов идёт вдоль предплечья: к кисти, если колёсико смотрит на кисть.
        let device = WKInterfaceDevice.current()
        let crownTowardHand = (device.wristLocation == .left) == (device.crownOrientation == .right)
        let forearm = SIMD3<Double>(crownTowardHand ? 1 : -1, 0, 0)
        let liftAxis = simd_cross(forearm, up) // вращение вокруг неё поднимает руку
        let liftLength = simd_length(liftAxis)

        let toDegrees = 180 / Double.pi
        if abs(yawRate) > Threshold.noiseRate {
            yaw -= yawRate * dt * toDegrees
        }
        if liftLength > 0.3 { // рука не направлена строго вверх/вниз
            var liftRate = simd_dot(rate, liftAxis / liftLength)
            if invertPitch { liftRate = -liftRate }
            if abs(liftRate) > Threshold.noiseRate {
                pitch += liftRate * dt * toDegrees
            }
        }
        yaw = max(-60, min(60, yaw))
        pitch = max(-45, min(45, pitch))

        guard time - lastPoseSent >= Threshold.poseInterval else { return }
        lastPoseSent = time
        onMessage?(.pose(yaw: Float(yaw), pitch: Float(pitch), scrolling: false, freeze: false))
    }
}
