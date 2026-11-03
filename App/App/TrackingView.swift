import SwiftUI
import UIKit
import AVFoundation

struct TrackingView: View {
    let macName: String
    @ObservedObject var peers: PeerBrowser
    @ObservedObject var tracker: HandTracker
    @ObservedObject var watch: WatchBridge
    /// Выключи, если управляешь только часами — иначе камера может поймать руку и сбить курсор.
    @State private var cameraOn = true

    var body: some View {
        ZStack {
            CameraPreview(session: tracker.camera.session)
                .ignoresSafeArea()
            Color.black.opacity(0.35)
                .ignoresSafeArea()
            HandSkeletonOverlay(points: tracker.debug.points)
                .ignoresSafeArea()

            VStack(spacing: 14) {
                statusBar
                watchBar
                Spacer()
                if tracker.isCalibrating {
                    calibrationCard
                } else if !tracker.lastGesture.isEmpty {
                    Text(tracker.lastGesture)
                        .font(.title2.bold())
                        .padding(.horizontal, 20)
                        .padding(.vertical, 12)
                        .background(.ultraThinMaterial, in: Capsule())
                        .transition(.scale.combined(with: .opacity))
                }
                Spacer()
                debugPanel
                controls
            }
            .padding()
            .animation(.spring(duration: 0.25), value: tracker.lastGesture)
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            if cameraOn { tracker.start() }
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            tracker.stop()
        }
    }

    // MARK: - Верхняя плашка

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text(statusText)
                .font(.subheadline.weight(.semibold))
            Spacer()
            Label(macName, systemImage: "laptopcomputer")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    // MARK: - Apple Watch

    private var watchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "applewatch")
            Text(watchText)
                .font(.caption.weight(.semibold))
            Spacer()
            Toggle("Камера", isOn: $cameraOn)
                .font(.caption)
                .fixedSize()
                .onChange(of: cameraOn) { _, on in
                    if on { tracker.start() } else { tracker.stop() }
                }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private var watchText: String {
        if !watch.isWatchAppInstalled { return "Приложение на часах не установлено" }
        if !watch.isWatchReachable { return "Открой FaceMouse на часах" }
        return watch.lastCommand.isEmpty ? "Часы на связи" : "Часы: \(watch.lastCommand)"
    }

    private var statusText: String {
        if !tracker.debug.tracked { return "Рука не найдена" }
        if tracker.isCalibrating { return "Калибровка" }
        if tracker.isPaused { return "Пауза" }
        return "Трекинг"
    }

    private var statusColor: Color {
        if !tracker.debug.tracked { return .red }
        if tracker.isCalibrating || tracker.isPaused { return .yellow }
        return .green
    }

    // MARK: - Калибровка

    private var calibrationCard: some View {
        VStack(spacing: 12) {
            Image(systemName: "hand.point.up.left")
                .font(.system(size: 40))
            Text("Укажи пальцем в центр экрана Mac")
                .font(.headline)
            Text(tracker.debug.tracked ? "Держи указательный палец вытянутым и ровным" : "Покажи ладонь камере")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            ProgressView(value: tracker.calibrationProgress)
                .frame(width: 200)
        }
        .padding(24)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20))
    }

    // MARK: - Debug

    private var debugPanel: some View {
        let d = tracker.debug
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(String(format: "Указка  ↔ %+.1f°   ↕ %+.1f°   · %@", d.yaw, d.pitch, poseLabel(d.pose)))
                    .font(.system(.footnote, design: .monospaced))
                Spacer()
            }
            meter("Щипок указ.", 1 - d.pinchIndex)
            meter("Щипок средн.", 1 - d.pinchMiddle)
            meter("Раскрытость", d.openness)
            meter("Разброс", d.spread)
            Text("Щипок указательным — клик · щипок средним — правый клик · кулак (держать) — пауза · раскрытая ладонь, веди рукой вверх/вниз — скролл")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    private func poseLabel(_ pose: HandPose) -> String {
        switch pose {
        case .point: return "указка"
        case .pinchIndex: return "щипок указ."
        case .pinchMiddle: return "щипок средн."
        case .fist: return "кулак"
        case .palm: return "ладонь"
        }
    }

    private func meter(_ title: String, _ value: Float) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .frame(width: 90, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule()
                        .fill(value > 0.6 ? Color.orange : Color.white.opacity(0.8))
                        .frame(width: geo.size.width * CGFloat(min(max(value, 0), 1)))
                }
            }
            .frame(height: 6)
            Text(String(format: "%.2f", value))
                .font(.system(.caption, design: .monospaced))
                .frame(width: 36, alignment: .trailing)
        }
    }

    // MARK: - Кнопки

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    tracker.calibrate()
                } label: {
                    Label("Калибровать", systemImage: "hand.point.up.left")
                        .frame(maxWidth: .infinity)
                }
                Button {
                    tracker.togglePause()
                } label: {
                    Label(tracker.isPaused ? "Продолжить" : "Пауза",
                          systemImage: tracker.isPaused ? "play.fill" : "pause.fill")
                        .frame(maxWidth: .infinity)
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(tracker.isCalibrating)

            HStack {
                Toggle("Зеркалить по горизонтали", isOn: $tracker.mirrorX)
                    .font(.caption)
                Spacer(minLength: 16)
                Button("Отключить", role: .destructive) {
                    peers.disconnect()
                }
                .font(.caption)
            }
        }
    }
}

// MARK: - Превью камеры

final class PreviewContainerView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
}

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewContainerView {
        let view = PreviewContainerView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        if let connection = view.previewLayer.connection {
            if connection.isVideoRotationAngleSupported(90) {
                connection.videoRotationAngle = 90
            }
            if connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = true
            }
        }
        return view
    }

    func updateUIView(_ uiView: PreviewContainerView, context: Context) {}
}

// MARK: - Skeleton-оверлей (debug)

/// Точки Vision уже в "исправленной" ориентации (после .leftMirrored в VNImageRequestHandler),
/// поэтому x=0 слева/x=1 справа и y=0 снизу/y=1 сверху совпадают с тем, что видит пользователь
/// в зеркальном превью. Маппинг приблизительный (без учёта обрезки resizeAspectFill) — для
/// подбора порогов жестов точности достаточно.
private struct HandSkeletonOverlay: View {
    let points: [HandJoint: SIMD2<Float>]

    var body: some View {
        Canvas { context, size in
            func toView(_ p: SIMD2<Float>) -> CGPoint {
                CGPoint(x: CGFloat(p.x) * size.width, y: (1 - CGFloat(p.y)) * size.height)
            }
            for (a, b) in handBones {
                guard let pa = points[a], let pb = points[b] else { continue }
                var path = Path()
                path.move(to: toView(pa))
                path.addLine(to: toView(pb))
                context.stroke(path, with: .color(.green.opacity(0.8)), lineWidth: 2)
            }
            for (_, p) in points {
                let c = toView(p)
                let r: CGFloat = 4
                context.fill(
                    Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2)),
                    with: .color(.green)
                )
            }
        }
        .allowsHitTesting(false)
    }
}
