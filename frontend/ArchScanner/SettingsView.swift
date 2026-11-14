import SwiftUI

struct SettingsView: View {
    @State private var settings = BackendSettingsStore.load()
    @State private var testMessage: String?
    @State private var isTesting = false

    var body: some View {
        Form {
            Section {
                TextField("host:port или http://…", text: $settings.baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
            } header: {
                Text("Backend")
            } footer: {
                Text("HTTP через VPN, например 100.64.0.2:8780")
                    .font(.caption2)
            }

            Section {
                Button {
                    BackendSettingsStore.save(settings)
                    testMessage = "Сохранено"
                } label: {
                    Text("Сохранить")
                }

                Button {
                    Task { await testConnection() }
                } label: {
                    if isTesting {
                        ProgressView()
                    } else {
                        Text("Проверить соединение")
                    }
                }
                .disabled(!settings.isConfigured || isTesting)

                if let testMessage {
                    Text(testMessage)
                        .font(.footnote)
                        .foregroundStyle(testMessage.hasPrefix("OK") ? .green : .secondary)
                }
            }
        }
        .navigationTitle("Настройки")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear {
            BackendSettingsStore.save(settings)
        }
    }

    private func testConnection() async {
        BackendSettingsStore.save(settings)
        isTesting = true
        testMessage = nil
        defer { isTesting = false }

        do {
            let url = try settings.resolvedBaseURL()
            let client = MeshAPIClient(baseURL: url)
            try await client.pingProjects()
            await MainActor.run {
                testMessage = "OK — \(url.absoluteString)"
            }
        } catch {
            await MainActor.run {
                testMessage = "Ошибка: \(error.localizedDescription)"
            }
        }
    }
}
