import SwiftUI
import RealityKit
import ARKit
import simd
import UIKit

struct ARViewContainer: UIViewRepresentable {
    @ObservedObject var scanner: AutoScannerModel

    func makeUIView(context: Context) -> ARView {
        let arView = ARView(frame: .zero)
        arView.session.delegate = scanner
        scanner.arView = arView
        scanner.applyARConfiguration(scanning: false)
        return arView
    }

    func updateUIView(_ uiView: ARView, context: Context) {}
}

final class AutoScannerModel: NSObject, ObservableObject, ARSessionDelegate {
    @Published var isScanning = false
    @Published var capturedCount = 0
    @Published var statusText = "Наведите на объект и нажмите Начать"
    @Published var currentSeriesName = ""
    @Published var exportState: SeriesExportState = .idle
    @Published var exportConfigured = ExportSettingsStore.load().isConfigured

    weak var arView: ARView?
    private var lastCaptureTransform: simd_float4x4?
    private var saveDirectory: URL?
    private var isSavingFrame = false
    private var exportTask: Task<Void, Never>?

    private let minDistanceMeters: Float = 0.05
    private let minAngleDegrees: Float = 10.0
    private let minAmbientIntensity: CGFloat = 300
    private let scansRootName = "Scans"

    var canExport: Bool {
        capturedCount > 0 && exportConfigured && !isScanning
    }

    override init() {
        super.init()
        startNewSeries()
    }

    func reloadExportSettings() {
        exportConfigured = ExportSettingsStore.load().isConfigured
    }

    func setScanning(_ scanning: Bool) {
        isScanning = scanning
        UIApplication.shared.isIdleTimerDisabled = scanning
        applyARConfiguration(scanning: scanning)

        if scanning {
            if case .success = exportState { exportState = .idle }
            if case .failed = exportState { exportState = .idle }
            if capturedCount == 0 {
                statusText = "Сканирую… \(currentSeriesName)"
            }
        } else {
            statusText = "Пауза. Снято: \(capturedCount) • \(currentSeriesName)"
            if let folder = saveDirectory {
                FrameMetadataWriter.writeSeriesManifest(
                    seriesName: currentSeriesName,
                    folder: folder,
                    frameCount: capturedCount
                )
            }
        }
    }

    func resetSession() {
        exportTask?.cancel()
        exportTask = nil
        setScanning(false)
        capturedCount = 0
        lastCaptureTransform = nil
        exportState = .idle
        startNewSeries()
        statusText = "Новая серия \(currentSeriesName). Готов к скану"
    }

    func exportCurrentSeries() {
        guard capturedCount > 0, exportConfigured, !isScanning else { return }
        if case .exporting = exportState { return }

        let settings = ExportSettingsStore.load()
        guard settings.isConfigured, let folder = saveDirectory else {
            exportState = .failed("Экспорт не настроен")
            return
        }

        let seriesName = currentSeriesName
        exportTask?.cancel()
        exportTask = Task { [weak self] in
            await self?.runExport(settings: settings, folder: folder, seriesName: seriesName)
        }
    }

    private func runExport(settings: ExportSettings, folder: URL, seriesName: String) async {
        await MainActor.run { exportState = .exporting(done: 0, total: 0) }

        do {
            switch settings.method {
            case .s3:
                try await exportToS3(config: settings.s3, folder: folder, seriesName: seriesName)
            }
            await MainActor.run {
                exportState = .success
                statusText = "Экспорт OK • \(seriesName)"
            }
        } catch is CancellationError {
            await MainActor.run { exportState = .idle }
        } catch {
            await MainActor.run {
                exportState = .failed(error.localizedDescription)
                statusText = "Экспорт ошибка • \(seriesName)"
            }
        }
    }

    private func exportToS3(config: S3ExportConfig, folder: URL, seriesName: String) async throws {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil))?
            .filter { !$0.hasDirectoryPath }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []
        guard !files.isEmpty else { throw S3ExportError.emptySeries }

        let exporter = S3Exporter(config: config)
        try await exporter.ensureBucket()

        let prefix = config.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let total = files.count
        await MainActor.run { exportState = .exporting(done: 0, total: total) }

        for (idx, file) in files.enumerated() {
            try Task.checkCancellation()
            let keyParts = [prefix, seriesName, file.lastPathComponent].filter { !$0.isEmpty }
            let key = keyParts.joined(separator: "/")
            let contentType: String
            switch file.pathExtension.lowercased() {
            case "jpg", "jpeg": contentType = "image/jpeg"
            case "json": contentType = "application/json"
            default: contentType = "application/octet-stream"
            }
            try await exporter.uploadFile(localURL: file, key: key, contentType: contentType)
            await MainActor.run { exportState = .exporting(done: idx + 1, total: total) }
        }
    }

    func applyARConfiguration(scanning: Bool) {
        guard let arView else { return }

        let config = ARWorldTrackingConfiguration()
        config.isAutoFocusEnabled = true
        config.environmentTexturing = .automatic

        if scanning, ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) {
            config.sceneReconstruction = .mesh
            arView.debugOptions.insert(.showSceneUnderstanding)
        } else {
            config.sceneReconstruction = []
            arView.debugOptions.remove(.showSceneUnderstanding)
        }

        arView.session.run(config, options: [])
    }

    private func scansRootURL() -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = docs.appendingPathComponent(scansRootName, isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func todayPrefix() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    private func startNewSeries() {
        let root = scansRootURL()
        let prefix = todayPrefix()
        let nextIndex = nextSeriesIndex(in: root, prefix: prefix)
        let name = String(format: "%@_%03d", prefix, nextIndex)
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        saveDirectory = folder
        currentSeriesName = name
        FrameMetadataWriter.writeSeriesManifest(seriesName: name, folder: folder, frameCount: 0)
    }

    private func nextSeriesIndex(in root: URL, prefix: String) -> Int {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        var maxIndex = 0
        let pattern = #"^\#(NSRegularExpression.escapedPattern(for: prefix))_(\d+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return 1 }

        for name in names {
            let range = NSRange(name.startIndex..<name.endIndex, in: name)
            guard let match = regex.firstMatch(in: name, range: range),
                  match.numberOfRanges == 2,
                  let idxRange = Range(match.range(at: 1), in: name),
                  let value = Int(name[idxRange]) else { continue }
            maxIndex = max(maxIndex, value)
        }
        return maxIndex + 1
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard isScanning, !isSavingFrame else { return }

        if let lightEstimate = frame.lightEstimate,
           lightEstimate.ambientIntensity < minAmbientIntensity {
            DispatchQueue.main.async {
                self.statusText = "Темновато — подсветите зону • \(self.currentSeriesName)"
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
        let orientation = CGImagePropertyOrientation.right

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            defer { self?.isSavingFrame = false }

            let ciImage = CIImage(cvPixelBuffer: pixelBuffer).oriented(orientation)
            let context = CIContext()
            guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else { return }
            let jpegData = UIImage(cgImage: cgImage).jpegData(compressionQuality: 0.92)
            guard let jpegData else { return }

            let fileName = String(format: "img_%04d.jpg", currentCount)
            let fileURL = folder.appendingPathComponent(fileName)

            do {
                try jpegData.write(to: fileURL)
                FrameMetadataWriter.write(
                    frame: frame,
                    index: currentCount,
                    fileName: fileName,
                    savedPixelWidth: cgImage.width,
                    savedPixelHeight: cgImage.height,
                    appliedOrientation: orientation,
                    to: folder
                )
                FrameMetadataWriter.writeSeriesManifest(
                    seriesName: self?.currentSeriesName ?? "",
                    folder: folder,
                    frameCount: currentCount
                )
                DispatchQueue.main.async {
                    self?.capturedCount = currentCount
                    let series = self?.currentSeriesName ?? ""
                    self?.statusText = "Кадров: \(currentCount) • \(series)"
                    if case .success = self?.exportState { self?.exportState = .idle }
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            } catch {
                print("Save error: \(error)")
            }
        }
    }
}
