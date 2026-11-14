import SwiftUI

struct ContentView: View {
    @StateObject private var scanner = AutoScannerModel()
    @State private var showSettings = false

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

                    if showExportButton {
                        Button {
                            scanner.exportCurrentSeries()
                        } label: {
                            Text(scanner.exportState.buttonTitle)
                                .font(.title3.bold())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 20)
                                .padding(.vertical, 14)
                                .background(exportButtonColor)
                                .clipShape(RoundedRectangle(cornerRadius: 16))
                        }
                        .disabled(isExporting)
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
                        .disabled(isExporting)
                    }
                }
            }
            .padding(.bottom, 30)
        }
        .sheet(isPresented: $showSettings, onDismiss: {
            scanner.reloadExportSettings()
        }) {
            SettingsView()
        }
    }

    private var isExporting: Bool {
        if case .exporting = scanner.exportState { return true }
        return false
    }

    private var showExportButton: Bool {
        guard scanner.exportConfigured, scanner.capturedCount > 0 else { return false }
        if scanner.isScanning { return false }
        return true
    }

    private var exportButtonColor: Color {
        switch scanner.exportState {
        case .idle:
            return Color.blue
        case .exporting:
            return Color.orange
        case .success:
            return Color.teal
        case .failed:
            return Color.red
        }
    }
}
