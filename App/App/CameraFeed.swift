import AVFoundation
import Vision
import simd

/// Захват фронтальной камеры + распознавание руки через Vision.
/// Намеренно НЕ @MainActor: AVCaptureSession.startRunning() блокирующий, его нельзя звать
/// с главного потока, а делегат AVCaptureVideoDataOutput сам приходит на фоновой очереди.
/// Наружу отдаёт только иммутабельный Sendable RawHand через onHand, с явным переходом на MainActor.
nonisolated final class CameraFeed: NSObject {

    /// Зовётся на MainActor с данными текущего кадра (nil — рука не найдена/потеряна).
    var onHand: ((RawHand?) -> Void)?

    static func authorizationStatus() -> AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    static func hasFrontCamera() -> Bool {
        AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) != nil
    }

    static func requestAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }

    /// Сессия камеры — нужна превью-слою (AVCaptureVideoPreviewLayer). Сама по себе thread-safe
    /// для чтения/присвоения .session, вся мутация конфигурации идёт через sessionQueue.
    let session = AVCaptureSession()

    private let sessionQueue = DispatchQueue(label: "facemouse.camera.session")
    private let visionQueue = DispatchQueue(label: "facemouse.camera.vision", qos: .userInteractive)
    private let output = AVCaptureVideoDataOutput()
    private let request: VNDetectHumanHandPoseRequest = {
        let r = VNDetectHumanHandPoseRequest()
        r.maximumHandCount = 1
        return r
    }()
    private var isConfigured = false

    func start() {
        sessionQueue.async { [self] in
            if !isConfigured {
                configure()
                isConfigured = true
            }
            if !session.isRunning {
                session.startRunning()
            }
        }
    }

    func stop() {
        sessionQueue.async { [self] in
            if session.isRunning {
                session.stopRunning()
            }
        }
    }

    // MARK: - Конфигурация (только на sessionQueue)

    private func configure() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        session.sessionPreset = .vga640x480

        guard
            let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front),
            let input = try? AVCaptureDeviceInput(device: device),
            session.canAddInput(input)
        else { return }
        session.addInput(input)

        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: visionQueue)
        guard session.canAddOutput(output) else { return }
        session.addOutput(output)
        // Буфер для Vision НЕ поворачиваем (лишняя нагрузка) — ориентация/зеркало
        // передаются через VNImageRequestHandler(orientation: .leftMirrored) в captureOutput.
        // Превью для пользователя разворачивает отдельная AVCaptureVideoPreviewLayer (свой connection).

        if let range = device.activeFormat.videoSupportedFrameRateRanges.first {
            do {
                try device.lockForConfiguration()
                let fps = min(60, range.maxFrameRate)
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: Int32(fps))
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: Int32(fps))
                device.unlockForConfiguration()
            } catch {
                // не критично — просто останемся на стандартном fps устройства
            }
        }
    }

    // MARK: - Извлечение руки из наблюдения Vision

    private static let jointMap: [(HandJoint, VNHumanHandPoseObservation.JointName)] = [
        (.wrist, .wrist),
        (.thumbCMC, .thumbCMC), (.thumbMP, .thumbMP), (.thumbIP, .thumbIP), (.thumbTip, .thumbTip),
        (.indexMCP, .indexMCP), (.indexPIP, .indexPIP), (.indexDIP, .indexDIP), (.indexTip, .indexTip),
        (.middleMCP, .middleMCP), (.middlePIP, .middlePIP), (.middleDIP, .middleDIP), (.middleTip, .middleTip),
        (.ringMCP, .ringMCP), (.ringPIP, .ringPIP), (.ringDIP, .ringDIP), (.ringTip, .ringTip),
        (.littleMCP, .littleMCP), (.littlePIP, .littlePIP), (.littleDIP, .littleDIP), (.littleTip, .littleTip),
    ]

    private static func extract(_ observation: VNHumanHandPoseObservation, aspect: Float) -> RawHand? {
        guard let all = try? observation.recognizedPoints(.all) else { return nil }

        var points: [HandJoint: SIMD2<Float>] = [:]
        var confidences: [HandJoint: Float] = [:]
        for (joint, name) in jointMap {
            guard let p = all[name], p.confidence > 0 else { continue }
            points[joint] = SIMD2(Float(p.location.x), Float(p.location.y))
            confidences[joint] = Float(p.confidence)
        }
        guard !points.isEmpty else { return nil }

        return RawHand(
            points: points, confidences: confidences,
            confidence: Float(observation.confidence), aspect: aspect
        )
    }

    private func deliver(_ raw: RawHand?) {
        let box = Unchecked(value: raw)
        let callback = onHand
        DispatchQueue.main.async {
            MainActor.assumeIsolated { callback?(box.value) }
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraFeed: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            deliver(nil)
            return
        }
        // Ориентированный кадр (после поворота .leftMirrored) — портрет, высота/ширина ≈ 4/3.
        // Исходный буфер landscape, поэтому aspect = оригинальные width/height (без свопа).
        let aspect = Float(CVPixelBufferGetWidth(pixelBuffer)) / Float(CVPixelBufferGetHeight(pixelBuffer))

        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .leftMirrored, options: [:])
        do {
            try handler.perform([request])
        } catch {
            deliver(nil)
            return
        }

        guard let observation = request.results?.first else {
            deliver(nil)
            return
        }
        deliver(Self.extract(observation, aspect: aspect))
    }
}
