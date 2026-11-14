import SwiftUI
import RealityKit
import UIKit
import simd

struct MeshViewerScreen: View {
    @EnvironmentObject private var store: ProjectsStore
    let projectID: String
    let versionID: String

    private var meshURL: URL? {
        store.localMeshURL(projectID: projectID, versionID: versionID)
    }

    var body: some View {
        Group {
            if let meshURL {
                MeshViewerView(url: meshURL)
            } else {
                ContentUnavailableView(
                    "Меш не найден",
                    systemImage: "cube.transparent",
                    description: Text("Сначала создайте меш для этой версии")
                )
            }
        }
        .navigationTitle("Меш")
        .navigationBarTitleDisplayMode(.inline)
        .settingsGear()
    }
}

struct MeshViewerView: View {
    let url: URL
    @StateObject private var model = MeshOrbitModel()

    var body: some View {
        ZStack {
            MeshOrbitView(url: url, model: model)
                .ignoresSafeArea()
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            model.applyDrag(translation: value.translation, isEnded: false)
                        }
                        .onEnded { value in
                            model.applyDrag(translation: value.translation, isEnded: true)
                        }
                )

            VStack {
                Spacer()
                HStack {
                    Spacer()
                    OrbitJoystick { dx, dy in
                        model.applyJoystick(dx: dx, dy: dy)
                    }
                    .frame(width: 120, height: 120)
                    .padding(24)
                }
            }
        }
        .background(Color.black)
    }
}

@MainActor
final class MeshOrbitModel: ObservableObject {
    weak var root: Entity?
    private var lastDrag: CGSize = .zero
    private var yaw: Float = 0
    private var pitch: Float = 0

    func attach(_ entity: Entity) {
        root = entity
        applyTransform()
    }

    func applyDrag(translation: CGSize, isEnded: Bool) {
        let dx = Float(translation.width - lastDrag.width)
        let dy = Float(translation.height - lastDrag.height)
        yaw += dx * 0.01
        pitch += dy * 0.01
        pitch = max(-1.2, min(1.2, pitch))
        applyTransform()
        lastDrag = isEnded ? .zero : translation
    }

    func applyJoystick(dx: Float, dy: Float) {
        // dx/dy in -1...1
        yaw += dx * 0.06
        pitch += dy * 0.06
        pitch = max(-1.2, min(1.2, pitch))
        applyTransform()
    }

    private func applyTransform() {
        guard let root else { return }
        let yawQ = simd_quatf(angle: yaw, axis: [0, 1, 0])
        let pitchQ = simd_quatf(angle: pitch, axis: [1, 0, 0])
        root.orientation = yawQ * pitchQ
    }
}

struct MeshOrbitView: UIViewRepresentable {
    let url: URL
    @ObservedObject var model: MeshOrbitModel

    func makeUIView(context: Context) -> ARView {
        let view = ARView(
            frame: .zero,
            cameraMode: .nonAR,
            automaticallyConfigureSession: false
        )
        view.environment.background = .color(.black)

        let anchor = AnchorEntity(world: .zero)
        view.scene.addAnchor(anchor)

        context.coordinator.anchor = anchor
        context.coordinator.model = model
        context.coordinator.load(url: url)

        let cam = PerspectiveCamera()
        cam.camera.fieldOfViewInDegrees = 45
        let camAnchor = AnchorEntity(world: [0, 0.12, 1.6])
        camAnchor.addChild(cam)
        view.scene.addAnchor(camAnchor)

        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    final class Coordinator {
        var anchor: AnchorEntity?
        weak var model: MeshOrbitModel?

        @MainActor
        func load(url: URL) {
            Task {
                do {
                    let entity = try await Task.detached {
                        try Entity.load(contentsOf: url)
                    }.value
                    await MainActor.run {
                        let bounds = entity.visualBounds(relativeTo: nil)
                        let extent = bounds.extents
                        let maxDim = max(extent.x, max(extent.y, extent.z))
                        if maxDim > 0.001 {
                            let scale = 1.0 / maxDim
                            entity.scale = SIMD3<Float>(repeating: scale)
                            entity.position = -bounds.center * scale
                        }
                        let pivot = Entity()
                        pivot.addChild(entity)
                        self.anchor?.children.removeAll()
                        self.anchor?.addChild(pivot)
                        self.model?.attach(pivot)
                    }
                } catch {
                    print("USDZ load error: \(error)")
                }
            }
        }
    }
}

private final class JoystickState {
    var vector: CGSize = .zero
    var timer: Timer?
}

struct OrbitJoystick: View {
    var onMove: (Float, Float) -> Void

    @State private var knobOffset: CGSize = .zero
    @State private var state = JoystickState()
    private let radius: CGFloat = 48

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .overlay(Circle().strokeBorder(.white.opacity(0.35), lineWidth: 1))

            Circle()
                .fill(.white.opacity(0.85))
                .frame(width: 44, height: 44)
                .offset(knobOffset)
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let clamped = clamp(value.translation, radius: radius)
                            knobOffset = clamped
                            state.vector = clamped
                            startTimerIfNeeded()
                        }
                        .onEnded { _ in
                            stopTimer()
                            state.vector = .zero
                            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) {
                                knobOffset = .zero
                            }
                        }
                )
        }
        .frame(width: radius * 2 + 24, height: radius * 2 + 24)
        .onDisappear { stopTimer() }
    }

    private func startTimerIfNeeded() {
        guard state.timer == nil else { return }
        let radius = self.radius
        let state = self.state
        let onMove = self.onMove
        state.timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { _ in
            DispatchQueue.main.async {
                let dx = Float(state.vector.width / radius)
                let dy = Float(state.vector.height / radius)
                if abs(dx) > 0.01 || abs(dy) > 0.01 {
                    onMove(dx, dy)
                }
            }
        }
    }

    private func stopTimer() {
        state.timer?.invalidate()
        state.timer = nil
    }

    private func clamp(_ translation: CGSize, radius: CGFloat) -> CGSize {
        let len = sqrt(translation.width * translation.width + translation.height * translation.height)
        if len <= radius || len == 0 { return translation }
        let scale = radius / len
        return CGSize(width: translation.width * scale, height: translation.height * scale)
    }
}
