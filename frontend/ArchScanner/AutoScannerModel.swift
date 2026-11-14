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
    @Published var meshState: MeshJobState = .idle
    @Published var backendConfigured = BackendSettingsStore.load().isConfigured
    @Published var localMeshURL: URL?
    /// Bumped when a freshly downloaded mesh should open in Quick Look.
    @Published var previewTicket: URL?

    weak var arView: ARView?
    private var lastCaptureTransform: simd_float4x4?
    private var saveDirectory: URL?
    private var isSavingFrame = false
    private var meshTask: Task<Void, Never>?

    private let minDistanceMeters: Float = 0.05
    private let minAngleDegrees: Float = 10.0
    private let minAmbientIntensity: CGFloat = 300
    private let scansRootName = "Scans"
    private let meshesRootName = "Meshes"

    override init() {
        super.init()
        startNewSeries()
    }

    func reloadBackendSettings() {
        backendConfigured = BackendSettingsStore.load().isConfigured
    }

    func setScanning(_ scanning: Bool) {
        isScanning = scanning
        UIApplication.shared.isIdleTimerDisabled = scanning
        applyARConfiguration(scanning: scanning)

        if scanning {
            if case .failed = meshState { meshState = .idle }
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
        meshTask?.cancel()
        meshTask = nil
        setScanning(false)
        capturedCount = 0
        lastCaptureTransform = nil
        meshState = .idle
        localMeshURL = nil
        previewTicket = nil
        startNewSeries()
        statusText = "Новая серия \(currentSeriesName). Готов к скану"
    }

    func submitMesh() {
        guard capturedCount > 0, backendConfigured, !isScanning else { return }
        if case .submitting = meshState { return }
        if case .processing = meshState { return }

        let settings = BackendSettingsStore.load()
        guard let baseURL = try? settings.resolvedBaseURL(), let folder = saveDirectory else {
            meshState = .failed("Backend не настроен")
            return
        }

        let projectID = ProjectIdentity.projectID()
        let versionID = currentSeriesName
        meshTask?.cancel()
        meshTask = Task { [weak self] in
            await self?.runSubmitMesh(baseURL: baseURL, projectID: projectID, versionID: versionID, folder: folder)
        }
    }

    func fetchMeshForPreview() {
        guard backendConfigured else { return }
        if case .ready = meshState, let url = localMeshURL {
            previewTicket = url
            return
        }

        let settings = BackendSettingsStore.load()
        guard let baseURL = try? settings.resolvedBaseURL() else {
            meshState = .failed("Backend не настроен")
            return
        }
        let projectID = ProjectIdentity.projectID()
        let versionID = currentSeriesName
        meshTask?.cancel()
        meshTask = Task { [weak self] in
            await self?.runFetchMesh(baseURL: baseURL, projectID: projectID, versionID: versionID, openPreview: true)
        }
    }

    private func runSubmitMesh(baseURL: URL, projectID: String, versionID: String, folder: URL) async {
        await MainActor.run { meshState = .submitting }

        do {
            let client = MeshAPIClient(baseURL: baseURL)
            let jobID = try await client.submitMesh(
                projectID: projectID,
                versionID: versionID,
                folder: folder,
                format: "usdz"
            )
            await MainActor.run {
                meshState = .processing(jobID: jobID)
                localMeshURL = nil
                statusText = "Меш в очереди • \(versionID)"
            }
            try await pollUntilReady(client: client, projectID: projectID, versionID: versionID, openPreview: false)
        } catch is CancellationError {
            await MainActor.run { meshState = .idle }
        } catch {
            await MainActor.run {
                meshState = .failed(error.localizedDescription)
                statusText = "Меш ошибка • \(versionID)"
            }
        }
    }

    private func runFetchMesh(baseURL: URL, projectID: String, versionID: String, openPreview: Bool) async {
        do {
            let client = MeshAPIClient(baseURL: baseURL)
            try await pollUntilReady(client: client, projectID: projectID, versionID: versionID, openPreview: openPreview)
        } catch is CancellationError {
            // keep current state
        } catch {
            await MainActor.run {
                meshState = .failed(error.localizedDescription)
                statusText = "Меш ошибка • \(versionID)"
            }
        }
    }

    private func pollUntilReady(
        client: MeshAPIClient,
        projectID: String,
        versionID: String,
        openPreview: Bool
    ) async {
        for _ in 0..<120 {
            try Task.checkCancellation()
            let status = try await client.fetchMeshFile(projectID: projectID, versionID: versionID)
            switch status {
            case .ready(let data, let name):
                let url = try saveMeshData(data, suggestedName: name, versionID: versionID)
                await MainActor.run {
                    localMeshURL = url
                    meshState = .ready
                    statusText = "Меш готов • \(versionID)"
                    if openPreview {
                        previewTicket = url
                    }
                }
                return
            case .processing:
                await MainActor.run {
                    if case .processing = meshState {
                        // keep
                    } else {
                        meshState = .processing(jobID: "")
                    }
                    statusText = "Меш считается… • \(versionID)"
                }
                try await Task.sleep(nanoseconds: 2_000_000_000)
            case .missing:
                await MainActor.run {
                    meshState = .failed("Меш не найден")
                    statusText = "Меш не найден • \(versionID)"
                }
                return
            }
        }
        await MainActor.run {
            meshState = .failed("Таймаут ожидания меша")
            statusText = "Меш таймаут • \(versionID)"
        }
    }

    private func saveMeshData(_ data: Data, suggestedName: String, versionID: String) throws -> URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let root = docs.appendingPathComponent(meshesRootName, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let safeName = suggestedName.isEmpty ? "\(versionID).usdz" : suggestedName
        let url = root.appendingPathComponent(safeName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
        try data.write(to: url)
        return url
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
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                }
            } catch {
                print("Save error: \(error)")
            }
        }
    }
}
