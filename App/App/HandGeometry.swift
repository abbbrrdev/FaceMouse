import Foundation
import simd

/// Все суставы кисти, которые различает Vision (зеркало VNHumanHandPoseObservation.JointName).
/// Используются и для метрик жестов, и для отрисовки skeleton-оверлея в debug-режиме.
nonisolated enum HandJoint: Sendable, CaseIterable {
    case wrist
    case thumbCMC, thumbMP, thumbIP, thumbTip
    case indexMCP, indexPIP, indexDIP, indexTip
    case middleMCP, middlePIP, middleDIP, middleTip
    case ringMCP, ringPIP, ringDIP, ringTip
    case littleMCP, littlePIP, littleDIP, littleTip
}

/// Кости для отрисовки скелета — пары соседних суставов.
nonisolated let handBones: [(HandJoint, HandJoint)] = [
    (.wrist, .thumbCMC), (.thumbCMC, .thumbMP), (.thumbMP, .thumbIP), (.thumbIP, .thumbTip),
    (.wrist, .indexMCP), (.indexMCP, .indexPIP), (.indexPIP, .indexDIP), (.indexDIP, .indexTip),
    (.wrist, .middleMCP), (.middleMCP, .middlePIP), (.middlePIP, .middleDIP), (.middleDIP, .middleTip),
    (.wrist, .ringMCP), (.ringMCP, .ringPIP), (.ringPIP, .ringDIP), (.ringDIP, .ringTip),
    (.wrist, .littleMCP), (.littleMCP, .littlePIP), (.littlePIP, .littleDIP), (.littleDIP, .littleTip),
]

/// Сырые точки руки одного кадра, в нормализованных координатах Vision
/// (x вправо, y вверх, origin внизу слева — после ориентации .leftMirrored).
nonisolated struct RawHand: Sendable {
    var points: [HandJoint: SIMD2<Float>]
    var confidences: [HandJoint: Float]
    /// Общая уверенность в распознавании руки (VNHumanHandPoseObservation.confidence).
    var confidence: Float
    /// Отношение сторон ориентированного кадра (высота/ширина), нужно чтобы привести
    /// нормализованные [0,1] координаты Vision к единому масштабу по x и по y.
    var aspect: Float
}

/// Производные метрики одного кадра — все безразмерные отношения,
/// поэтому не важно, левая рука или правая и как далеко она от камеры.
nonisolated struct HandMetrics: Sendable {
    /// Кончик указательного — точка-указка, в width-normalized координатах (ещё не относительно калибровки).
    var anchor: SIMD2<Float>
    /// |wrist - middleMCP| в width-normalized координатах — "единица" размера ладони.
    var handScale: Float
    var pinchIndex: Float
    var pinchMiddle: Float
    var openness: Float
    var spread: Float
    var indexReach: Float
}

nonisolated enum HandPose: Sendable, Equatable {
    case point
    case pinchIndex
    case pinchMiddle
    case fist
    case palm
}

nonisolated enum HandThreshold {
    // Щипки — триггер Шмитта
    static let pinchClose: Float = 0.28          // вход в щипок
    static let pinchOpen: Float = 0.45           // выход из щипка
    static let pinchArm: Float = 0.55            // freeze заранее, до полного схождения пальцев
    static let pinchMargin: Float = 0.12         // указательный vs средний
    static let pinchHold: TimeInterval = 0.10
    static let clickCooldown: TimeInterval = 0.30

    // Классификация позы
    static let fistOpen: Float = 0.45
    static let fistReach: Float = 0.85           // отличает кулак от щипка
    static let palmOpen: Float = 0.75
    static let palmSpread: Float = 0.95
    static let pointReach: Float = 0.90          // щипок/указка требуют вытянутого указательного
    static let modeHold: TimeInterval = 0.15
    static let fistHold: TimeInterval = 0.40     // удержание кулака до срабатывания паузы

    // Трекинг
    static let minConfidence: Float = 0.35
    static let lostGrace: TimeInterval = 0.15
    static let maxJump: Float = 0.35
    static let scaleAlpha: Float = 0.02
    static let scaleClampLow: Float = 0.6
    static let scaleClampHigh: Float = 1.8
    static let calibrationDuration: TimeInterval = 2.0
    static let calibrationMinSamples = 20
    static let calibrationOutlier: Float = 0.15

    // Маппинг указки в градусы под Mac (range по умолчанию = 12°)
    static let spanX: Float = 1.1                // ширин ладони от центра до края экрана
    static let spanY: Float = 0.8
    static let spanScrollY: Float = 0.5
    static let fullScaleX: Float = 12.0
    static let verticalCompensation: Float = 0.75 // Mac делит pitch на range*0.75
    static let clampOvershoot: Float = 1.2
}

/// Считает метрики кадра. nil — если ключевые точки не распознаны с достаточной уверенностью
/// или рука вырождена (handScale слишком мал).
nonisolated func handMetrics(from hand: RawHand) -> HandMetrics? {
    func point(_ joint: HandJoint) -> SIMD2<Float>? {
        guard
            let p = hand.points[joint],
            (hand.confidences[joint] ?? 0) >= HandThreshold.minConfidence
        else { return nil }
        return SIMD2(p.x, p.y * hand.aspect)
    }

    guard
        let wrist = point(.wrist),
        let thumbTip = point(.thumbTip),
        let indexMCP = point(.indexMCP),
        let indexTip = point(.indexTip),
        let middleMCP = point(.middleMCP),
        let middleTip = point(.middleTip),
        let ringMCP = point(.ringMCP),
        let ringTip = point(.ringTip),
        let littleMCP = point(.littleMCP),
        let littleTip = point(.littleTip)
    else { return nil }

    let scale = simd_distance(wrist, middleMCP)
    guard scale > 0.001 else { return nil }

    func ratio(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> Float {
        simd_distance(a, b) / scale
    }

    let openness = (
        ratio(indexTip, indexMCP) + ratio(middleTip, middleMCP)
        + ratio(ringTip, ringMCP) + ratio(littleTip, littleMCP)
    ) / 4

    return HandMetrics(
        anchor: indexTip,
        handScale: scale,
        pinchIndex: ratio(thumbTip, indexTip),
        pinchMiddle: ratio(thumbTip, middleTip),
        openness: openness,
        spread: ratio(indexTip, littleTip),
        indexReach: ratio(indexTip, wrist)
    )
}

/// Классифицирует позу кадра. `previous` нужен для гистерезиса щипков (триггер Шмитта):
/// действующий щипок держится, пока расстояние не превысит pinchOpen, а не только pinchClose.
nonisolated func classifyHandPose(_ m: HandMetrics, previous: HandPose) -> HandPose {
    // 1. Кулак — проверяем первым и строго: расслабленный щипок указательным похож на кулак
    // (три пальца подогнуты), отличитель — indexReach (вытянутость указательного).
    if m.openness < HandThreshold.fistOpen && m.indexReach < HandThreshold.fistReach {
        return .fist
    }

    // 2. Раскрытая ладонь
    if m.openness > HandThreshold.palmOpen && m.spread > HandThreshold.palmSpread {
        return .palm
    }

    // 3-4. Щипки — только если указательный вытянут (иначе ракурс "палец в камеру" даёт ложный кулак)
    guard m.indexReach > HandThreshold.pointReach else { return .point }

    let indexThreshold = previous == .pinchIndex ? HandThreshold.pinchOpen : HandThreshold.pinchClose
    let middleThreshold = previous == .pinchMiddle ? HandThreshold.pinchOpen : HandThreshold.pinchClose

    let indexPinching = m.pinchIndex < indexThreshold
    let middlePinching = m.pinchMiddle < middleThreshold

    if middlePinching && (m.pinchIndex - m.pinchMiddle) > HandThreshold.pinchMargin {
        return .pinchMiddle
    }
    if indexPinching && (m.pinchMiddle - m.pinchIndex) > HandThreshold.pinchMargin {
        return .pinchIndex
    }
    return .point
}
