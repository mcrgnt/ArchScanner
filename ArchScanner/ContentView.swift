import SwiftUI

struct ContentView: View {
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

                HStack(spacing: 20) {
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
                    }
                }
            }
            .padding(.bottom, 30)
        }
    }
}
