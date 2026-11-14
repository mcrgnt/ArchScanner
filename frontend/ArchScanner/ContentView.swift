import SwiftUI

struct ContentView: View {
    @StateObject private var scanner = AutoScannerModel()
    @State private var showSettings = false
    @State private var showPreview = false
    @State private var previewURL: URL?

    var body: some View {
        ZStack(alignment: .bottom) {
            ARViewContainer(scanner: scanner)
                .ignoresSafeArea()

            VStack(spacing: 12) {
                HStack {
                    Spacer()
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape.fill")
                            .font(.title2)
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.ultraThinMaterial)
                            .clipShape(Circle())
                    }
                    .padding(.trailing, 16)
                    .padding(.top, 8)
                }
                Spacer()

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
                        Text(scanner.isScanning ? "Пауза" : "Начать скан")
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
                            if case .ready = scanner.meshState, let url = scanner.localMeshURL {
                                previewURL = url
                                showPreview = true
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

                    if scanner.capturedCount > 0 {
                        Button {
                            scanner.resetSession()
                        } label: {
                            Image(systemName: "plus.rectangle.on.folder")
                                .font(.title2)
                                .foregroundStyle(.white)
                                .padding(14)
                                .background(Color.gray.opacity(0.8))
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .accessibilityLabel("Новая серия")
                        .disabled(isMeshBusy)
                    }
                }
            }
            .padding(.bottom, 30)
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            scanner.reloadBackendSettings()
        }) {
            SettingsView()
        }
        .sheet(isPresented: $showPreview) {
            if let previewURL {
                USDZPreviewSheet(url: previewURL)
                    .ignoresSafeArea()
            }
        }
        .onChange(of: scanner.previewTicket) { ticket in
            guard let ticket else { return }
            previewURL = ticket
            showPreview = true
        }
    }

    private var isMeshBusy: Bool {
        switch scanner.meshState {
        case .submitting, .processing: return true
        default: return false
        }
    }

    private var showMeshButton: Bool {
        guard scanner.backendConfigured, scanner.capturedCount > 0 else { return false }
        if scanner.isScanning { return false }
        return true
    }

    private var showViewButton: Bool {
        guard scanner.backendConfigured, scanner.capturedCount > 0 else { return false }
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
