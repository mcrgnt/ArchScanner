import SwiftUI
import RealityKit
import ARKit
import simd
import UIKit

struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var scanner: AutoScannerModel

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)

        let config = ARWorldTrackingConfiguration()
        if ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
        }
        config.isAutoFocusEnabled = true
        config.environmentTexturing = .automatic

        arView.debugOptions.insert(.showSceneUnderstanding)
        arView.session.delegate = scanner
        arView.session.run(config)
        scanner.arView = arView

        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

final class AutoScannerModel: NSObject, ObservableObject, ARSessionDelegate {
    @Published var isScanning = false
    @Published var capturedCount = 0
    @Published var statusText = "Наведите на арку и нажмите Начать"

    weak var arView: ARView?
    private var lastCaptureTransform: simd_float4x4?
    private var saveDirectory: URL?
    private var isSavingFrame = false

    private let minDistanceMeters: Float = 0.05
    private let minAngleDegrees: Float = 10.0
    private let minAmbientIntensity: CGFloat = 300

    override init() {
        super.init()
        setupFolder()
    }

    private func setupFolder() {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let folder = docs.appendingPathComponent("WheelArchScan", isDirectory: true)
        try? FileManager.default.removeItem(at: folder)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        saveDirectory = folder
    }

    func resetSession() {
        isScanning = false
        capturedCount = 0
        lastCaptureTransform = nil
        setupFolder()
        statusText = "Сброшено. Готов к новому скану"
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isScanning, !isSavingFrame else { return }

        if let lightEstimate = frame.lightEstimate,
           lightEstimate.ambientIntensity < minAmbientIntensity {
            DispatchQueue.main.async {
                self.statusText = "Темновато — подсветите зону"
            }
            return
        }

        let currentTransform = frame.camera.transform
        if shouldCapture(currentTransform: currentTransform, trackingState: frame.camera.trackingState) {
            lastCaptureTransform = currentTransform
            captureHighResFrame(frame: frame)
        }
    }

    private func shouldCapture(
        currentTransform: simd_float4x4,
        trackingState: ARCamera.TrackingState
    ) -> Bool {
        guard case .normal = trackingState else { return false }
        guard let lastTransform = lastCaptureTransform else { return true }

        let distance = simd_distance(currentTransform.columns.3, lastTransform.columns.3)
        if distance >= minDistanceMeters { return true }

        let currentForward = -simd_normalize(simd_make_float3(currentTransform.columns.2))
        let lastForward = -simd_normalize(simd_make_float3(lastTransform.columns.2))
        let dotProduct = simd_clamp(simd_dot(currentForward, lastForward), -1.0, 1.0)
        let angleDegrees = acos(dotProduct) * (180.0 / .pi)
        return angleDegrees >= minAngleDegrees
    }

    private func captureHighResFrame(frame: ARFrame) {
        guard let folder = saveDirectory else { return }
        isSavingFrame = true

        let pixelBuffer = frame.capturedImage
        let currentCount = capturedCount + 1

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { self?.isSavingFrame = false }

            let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(.right)
            let context = CIContext()
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let jpegData = context.jpegRepresentation(
                    of: ciImage,
                    colorSpace: colorSpace,
                    options: [.compressionQuality: 0.92]
                  ) else { return }

            let fileName = String(format: "img_%04d.jpg", currentCount)
            let fileURL = folder.appendingPathComponent(fileName)

            do {
                try jpegData.write(to: fileURL)
                DispatchQueue.main.async {
                    self?.capturedCount = currentCount
                    self?.statusText = "Кадров: \(currentCount) • закрывайте пробелы в сетке"
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            } catch {
                print("Save error: \(error)")
            }
        }
    }
}
