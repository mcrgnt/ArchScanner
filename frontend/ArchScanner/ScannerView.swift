import SwiftUI

struct ScannerView: View {
    @EnvironmentObject private var router: AppRouter
    let projectID: String
    let versionID: String

    @StateObject private var scanner = AutoScannerModel()

    var body: some View {
        ZStack(alignment: .bottom) {
            ARViewContainer(scanner: scanner)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                Text(scanner.statusText)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial)
                    .clipShape(RoundedRectangle(cornerRadius: 12))

                if !scanner.currentSeriesName.isEmpty {
                    Text(scanner.currentSeriesName)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                }

                HStack(spacing: 16) {
                    Button {
                        scanner.setScanning(!scanner.isScanning)
                    } label: {
                        Text(scanner.isScanning ? "Стоп" : "Старт")
                            .font(.title3.bold())
                            .foregroundStyle(.white)
                            .padding(.horizontal, 24)
                            .padding(.vertical, 14)
                            .background(scanner.isScanning ? Color.red : Color.green)
                            .clipShape(RoundedRectangle(cornerRadius: 16))
                    }

                    if showMeshButton {
                        Button {
                            scanner.submitMesh()
                        } label: {
                            Text(scanner.meshState.meshButtonTitle)
                                .font(.title3.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 14)
                                .background(meshButtonColor)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .disabled(isMeshBusy)
                    }

                    if showViewButton {
                        Button {
                            if case .ready = scanner.meshState, scanner.localMeshURL != nil {
                                router.open(.mesh(projectID: projectID, versionID: versionID))
                            } else {
                                scanner.fetchMeshForPreview()
                            }
                        } label: {
                            Image(systemName: "cube.transparent")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .padding(14)
                                .background(Color.purple.opacity(viewButtonOpacity))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .disabled(viewButtonDisabled)
                        .accessibilityLabel("Просмотр меша")
                    }
                }
            }
            .padding(.bottom, 30)
        }
        .navigationTitle("Сканер")
        .navigationBarTitleDisplayMode(.inline)
        .settingsGear()
        .toolbarBackground(.hidden, for: .navigationBar)
        .onAppear {
            let folder = ProjectPaths.versionFolder(projectID: projectID, versionID: versionID)
            scanner.reloadBackendSettings()
            scanner.bind(projectID: projectID, versionID: versionID, folder: folder)
        }
        .onDisappear {
            scanner.pauseCamera()
        }
        .onChange(of: scanner.previewTicket) { ticket in
            guard ticket != nil else { return }
            router.open(.mesh(projectID: projectID, versionID: versionID))
        }
    }

    private var isMeshBusy: Bool {
        switch scanner.meshState {
        case .submitting, .processing: return true
        default: return false
        }
    }

    private var backendOK: Bool {
        BackendSettingsStore.load().isConfigured
    }

    private var showMeshButton: Bool {
        guard backendOK, scanner.capturedCount > 0 else { return false }
        if scanner.isScanning { return false }
        return true
    }

    private var showViewButton: Bool {
        guard backendOK, scanner.capturedCount > 0 else { return false }
        if scanner.isScanning { return false }
        switch scanner.meshState {
        case .idle: return false
        default: return true
        }
    }

    private var viewButtonDisabled: Bool {
        switch scanner.meshState {
        case .idle, .submitting: return true
        case .processing, .ready, .failed: return false
        }
    }

    private var viewButtonOpacity: Double {
        switch scanner.meshState {
        case .ready: return 0.9
        case .processing: return 0.45
        case .failed: return 0.5
        default: return 0.25
        }
    }

    private var meshButtonColor: Color {
        switch scanner.meshState {
        case .idle: return Color.blue
        case .submitting, .processing: return Color.orange
        case .ready: return Color.teal
        case .failed: return Color.red
        }
    }
}
