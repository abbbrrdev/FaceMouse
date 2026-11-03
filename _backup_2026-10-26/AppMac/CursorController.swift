import AppKit
import CoreGraphics
import QuartzCore

/// One Euro Filter: убирает дрожание в покое и почти не добавляет задержку при быстром движении.
nonisolated struct OneEuroFilter {
    var minCutoff: Double = 1.0
    var beta: Double = 0.05
    var derivativeCutoff: Double = 1.0

    private var value: Double?
    private var derivative: Double = 0
    private var time: Double?

    mutating func filter(_ newValue: Double, at newTime: Double) -> Double {
        guard let previous = value, let previousTime = time, newTime > previousTime else {
            value = newValue
            time = newTime
            return newValue
        }
        let dt = newTime - previousTime
        let rawDerivative = (newValue - previous) / dt
        let aD = alpha(cutoff: derivativeCutoff, dt: dt)
        derivative = aD * rawDerivative + (1 - aD) * derivative

        let cutoff = minCutoff + beta * abs(derivative)
        let a = alpha(cutoff: cutoff, dt: dt)
        let filtered = a * newValue + (1 - a) * previous

        value = filtered
        time = newTime
        return filtered
    }

    mutating func reset() {
        value = nil
        time = nil
        derivative = 0
    }

    private func alpha(cutoff: Double, dt: Double) -> Double {
        let tau = 1 / (2 * Double.pi * cutoff)
        return 1 / (1 + tau / dt)
    }
}

/// Превращает позы головы в движение курсора, клики и скролл через CGEvent.
@MainActor
final class CursorController {
    var enabled = true
    var onDebug: ((Float, Float) -> Void)?

    private let settings: MouseSettings
    private var timer: Timer?

    private var filterX = OneEuroFilter()
    private var filterY = OneEuroFilter()
    private var yaw: Double = 0
    private var pitch: Double = 0
    private var scrolling = false
    private var freeze = false
    private var paused = false

    private var lastPoseTime: CFTimeInterval = 0
    private var lastTick: CFTimeInterval = CACurrentMediaTime()
    private var frozenUntil: CFTimeInterval = 0
    private var scrollRemainder: Double = 0
    private var lastAbsoluteTarget: CGPoint?

    private var lastLeftClickTime: CFTimeInterval = 0
    private var lastLeftClickPoint = CGPoint.zero
    private var clickCount: Int64 = 1

    init(settings: MouseSettings) {
        self.settings = settings
    }

    func start() {
        let timer = Timer(timeInterval: 1.0 / 120.0, repeats: true) { _ in
            MainActor.assumeIsolated { self.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func reset() {
        paused = false
        resetMotion()
    }

    // MARK: - Входящие сообщения

    func handle(_ message: FaceMessage) {
        let now = CACurrentMediaTime()
        switch message {
        case let .pose(newYaw, newPitch, isScrolling, isFrozen):
            let minCutoff = 3.0 - 2.7 * settings.smoothing // 3 Гц (резко) … 0.3 Гц (плавно)
            filterX.minCutoff = minCutoff
            filterY.minCutoff = minCutoff
            yaw = filterX.filter(Double(newYaw), at: now)
            pitch = filterY.filter(Double(newPitch), at: now)
            scrolling = isScrolling
            freeze = isFrozen
            lastPoseTime = now
            onDebug?(Float(yaw), Float(pitch))

        case .leftClick:
            click(left: true)
            frozenUntil = now + 0.25 // глаз открывается — голова может дёрнуться

        case .rightClick:
            click(left: false)
            frozenUntil = now + 0.25

        case let .state(isPaused):
            paused = isPaused
            resetMotion()
        }
    }

    private func resetMotion() {
        filterX.reset()
        filterY.reset()
        lastPoseTime = 0
        scrollRemainder = 0
        lastAbsoluteTarget = nil
    }

    // MARK: - Цикл 120 Гц

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = min(now - lastTick, 0.05)
        lastTick = now

        // Нет свежих поз > 0.3 с (лицо пропало, телефон отключился) — стоим
        guard enabled, !paused, now - lastPoseTime < 0.3, !freeze, now >= frozenUntil else { return }

        let x = settings.invertX ? -yaw : yaw
        let y = settings.invertY ? -pitch : pitch

        if scrolling {
            scroll(pitch: y, dt: dt)
            lastAbsoluteTarget = nil
            return
        }

        switch settings.mode {
        case .joystick: joystick(x: x, y: y, dt: dt)
        case .absolute: absolute(x: x, y: y)
        }
    }

    /// Скорость с мёртвой зоной и плавной кривой: маленький наклон — точно, большой — быстро.
    private func velocity(_ angle: Double) -> Double {
        let excess = abs(angle) - settings.deadzone
        guard excess > 0 else { return 0 }
        let normalized = min(excess / 15, 1.5)
        return (angle < 0 ? -1 : 1) * pow(normalized, 1.6) * settings.speed
    }

    private func joystick(x: Double, y: Double, dt: Double) {
        let dx = velocity(x) * dt
        let dy = -velocity(y) * dt // экранная Y растёт вниз
        guard dx != 0 || dy != 0, let current = currentLocation() else { return }
        moveCursor(to: CGPoint(x: current.x + dx, y: current.y + dy))
    }

    private func absolute(x: Double, y: Double) {
        let bounds = CGDisplayBounds(CGMainDisplayID())
        let nx = max(-1, min(1, x / settings.range))
        let ny = max(-1, min(1, y / (settings.range * 0.75))) // вверх-вниз голова поворачивается меньше
        let target = CGPoint(
            x: min(bounds.maxX - 1, bounds.midX + nx * bounds.width / 2),
            y: min(bounds.maxY - 1, bounds.midY - ny * bounds.height / 2)
        )
        // Не двигаем, если цель почти не изменилась — чтобы не мешать обычной мышке
        if let last = lastAbsoluteTarget, hypot(target.x - last.x, target.y - last.y) < 1 { return }
        lastAbsoluteTarget = target
        moveCursor(to: target)
    }

    private func scroll(pitch: Double, dt: Double) {
        scrollRemainder += velocity(pitch) * dt * 0.5
        let amount = scrollRemainder.rounded(.towardZero)
        guard amount != 0 else { return }
        scrollRemainder -= amount
        CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel,
            wheelCount: 1, wheel1: Int32(amount), wheel2: 0, wheel3: 0
        )?.post(tap: .cghidEventTap)
    }

    // MARK: - CGEvent

    private func currentLocation() -> CGPoint? {
        CGEvent(source: nil)?.location
    }

    private func moveCursor(to point: CGPoint) {
        let target = clampToDisplays(point)
        CGEvent(mouseEventSource: nil, mouseType: .mouseMoved,
                mouseCursorPosition: target, mouseButton: .left)?
            .post(tap: .cghidEventTap)
    }

    private func clampToDisplays(_ point: CGPoint) -> CGPoint {
        if isOnDisplay(point) { return point }
        guard let current = currentLocation() else { return point }
        let xOnly = CGPoint(x: point.x, y: current.y)
        if isOnDisplay(xOnly) { return xOnly }
        let yOnly = CGPoint(x: current.x, y: point.y)
        if isOnDisplay(yOnly) { return yOnly }
        return current
    }

    private func isOnDisplay(_ point: CGPoint) -> Bool {
        var displays = [CGDirectDisplayID](repeating: 0, count: 8)
        var count: UInt32 = 0
        CGGetDisplaysWithPoint(point, 8, &displays, &count)
        return count > 0
    }

    private func click(left: Bool) {
        guard enabled, !paused, let position = currentLocation() else { return }
        let now = CACurrentMediaTime()

        var clickState: Int64 = 1
        if left {
            // Два быстрых подмигивания в одной точке — двойной клик
            let isDouble = now - lastLeftClickTime < NSEvent.doubleClickInterval
                && hypot(position.x - lastLeftClickPoint.x, position.y - lastLeftClickPoint.y) < 8
            clickCount = isDouble ? clickCount + 1 : 1
            clickState = clickCount
            lastLeftClickTime = now
            lastLeftClickPoint = position
        }

        let button: CGMouseButton = left ? .left : .right
        let down: CGEventType = left ? .leftMouseDown : .rightMouseDown
        let up: CGEventType = left ? .leftMouseUp : .rightMouseUp

        for type in [down, up] {
            let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                mouseCursorPosition: position, mouseButton: button)
            event?.setIntegerValueField(.mouseEventClickState, value: clickState)
            event?.post(tap: .cghidEventTap)
        }
    }
}
