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
    @Published var statusText = "Наведите на объект и нажмите Старт"
    @Published var currentSeriesName = ""
    @Published var meshState: MeshJobState = .idle
    @Published var backendConfigured = BackendSettingsStore.load().isConfigured
    @Published var localMeshURL: URL?
    /// Bumped when a freshly downloaded mesh should open in the viewer.
    @Published var previewTicket: URL?

    weak var arView: ARView?
    private var lastCaptureTransform: simd_float4x4?
    private var saveDirectory: URL?
    private var isSavingFrame = false
    private var meshTask: Task<Void, Never>?
    private var boundProjectID: String = ""
    private var cameraStarted = false

    private let minDistanceMeters: Float = 0.05
    private let minAngleDegrees: Float = 10.0
    private let minAmbientIntensity: CGFloat = 300

    override init() {
        super.init()
    }

    func reloadBackendSettings() {
        backendConfigured = BackendSettingsStore.load().isConfigured
    }

    /// Bind to an existing project version folder and start the camera preview (not scanning yet).
    func bind(projectID: String, versionID: String, folder: URL) {
        meshTask?.cancel()
        meshTask = nil
        setScanning(false)
        boundProjectID = projectID
        currentSeriesName = versionID
        saveDirectory = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let existing = countExistingFrames(in: folder)
        capturedCount = existing
        lastCaptureTransform = nil
        meshState = .idle
        localMeshURL = nil
        previewTicket = nil

        if let meshURL = ProjectsStore.shared.localMeshURL(projectID: projectID, versionID: versionID) {
            localMeshURL = meshURL
            meshState = .ready
        }

        if existing > 0 {
            statusText = "Кадров: \(existing) • \(versionID). Старт / Стоп"
        } else {
            statusText = "Камера готова • \(versionID). Нажмите Старт"
        }

        startCameraIfNeeded()
    }

    func startCameraIfNeeded() {
        guard !cameraStarted else {
            applyARConfiguration(scanning: isScanning)
            return
        }
        cameraStarted = true
        applyARConfiguration(scanning: false)
    }

    func setScanning(_ scanning: Bool) {
        isScanning = scanning
        UIApplication.shared.isIdleTimerDisabled = scanning
        applyARConfiguration(scanning: scanning)

        if scanning {
            if case .failed = meshState { meshState = .idle }
            if capturedCount == 0 {
                statusText = "Сканирую… \(currentSeriesName)"
            } else {
                statusText = "Сканирую… кадров: \(capturedCount) • \(currentSeriesName)"
            }
        } else if !currentSeriesName.isEmpty {
            statusText = "Стоп. Снято: \(capturedCount) • \(currentSeriesName)"
            if let folder = saveDirectory {
                FrameMetadataWriter.writeSeriesManifest(
                    seriesName: currentSeriesName,
                    folder: folder,
                    frameCount: capturedCount
                )
                ProjectsStore.shared.updateFrameCount(
                    projectID: boundProjectID,
                    versionID: currentSeriesName,
                    count: capturedCount
                )
            }
        }
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

        let projectID = boundProjectID
        let versionID = currentSeriesName
        guard !projectID.isEmpty, !versionID.isEmpty else {
            meshState = .failed("Нет проекта/версии")
            return
        }

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
        let projectID = boundProjectID
        let versionID = currentSeriesName
        guard !projectID.isEmpty, !versionID.isEmpty else { return }

        meshTask?.cancel()
        meshTask = Task { [weak self] in
            await self?.runFetchMesh(baseURL: baseURL, projectID: projectID, versionID: versionID, openPreview: true)
        }
    }

    private func runSubmitMesh(baseURL: URL, projectID: String, versionID: String, folder: URL) async {
        await MainActor.run {
            meshState = .submitting
            ProjectsStore.shared.clearMesh(projectID: projectID, versionID: versionID)
            localMeshURL = nil
        }

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
    ) async throws {
        for _ in 0..<120 {
            try Task.checkCancellation()
            let status = try await client.fetchMeshFile(projectID: projectID, versionID: versionID)
            switch status {
            case .ready(let data, let name):
                let url = try saveMeshData(data, suggestedName: name, projectID: projectID, versionID: versionID)
                await MainActor.run {
                    localMeshURL = url
                    meshState = .ready
                    statusText = "Меш готов • \(versionID)"
                    ProjectsStore.shared.markMeshReady(
                        projectID: projectID,
                        versionID: versionID,
                        fileName: url.lastPathComponent
                    )
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

    private func saveMeshData(
        _ data: Data,
        suggestedName: String,
        projectID: String,
        versionID: String
    ) throws -> URL {
        let url = ProjectPaths.meshSaveURL(
            projectID: projectID,
            versionID: versionID,
            suggestedName: suggestedName.isEmpty ? "\(versionID).usdz" : suggestedName
        )
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

    func pauseCamera() {
        setScanning(false)
        arView?.session.pause()
        cameraStarted = false
        UIApplication.shared.isIdleTimerDisabled = false
    }

    private func countExistingFrames(in folder: URL) -> Int {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "jpg" || $0.pathExtension.lowercased() == "jpeg" }.count
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
        let projectID = boundProjectID
        let seriesName = currentSeriesName

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
                    seriesName: seriesName,
                    folder: folder,
                    frameCount: currentCount
                )
                DispatchQueue.main.async {
                    self?.capturedCount = currentCount
                    self?.statusText = "Кадров: \(currentCount) • \(seriesName)"
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    if !projectID.isEmpty {
                        ProjectsStore.shared.updateFrameCount(
                            projectID: projectID,
                            versionID: seriesName,
                            count: currentCount
                        )
                    }
                }
            } catch {
                print("Save error: \(error)")
            }
        }
    }
}
