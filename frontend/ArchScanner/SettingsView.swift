import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var settings = ExportSettingsStore.load()
    @State private var testMessage: String?
    @State private var isTesting = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Экспорт") {
                    Picker("Тип", selection: $settings.method) {
                        ForEach(ExportMethod.allCases) { method in
                            Text(method.title).tag(method)
                        }
                    }
                }

                if settings.method == .s3 {
                    Section {
                        TextField("IP или domain:port", text: $settings.s3.endpoint)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .keyboardType(.URL)
                        Toggle("HTTPS (SSL)", isOn: $settings.s3.useSSL)
                        Toggle("Path-style (MinIO)", isOn: $settings.s3.pathStyle)
                        TextField("Bucket", text: $settings.s3.bucket)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Prefix", text: $settings.s3.prefix)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Region", text: $settings.s3.region)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        TextField("Access Key", text: $settings.s3.accessKey)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                        SecureField("Secret Key", text: $settings.s3.secretKey)
                    } header: {
                        Text("S3 / MinIO")
                    } footer: {
                        Text("Пример endpoint: 192.168.254.184:9000. Для MinIO обычно HTTP + path-style, region us-east-1.")
                    }
                }

                Section {
                    Button {
                        ExportSettingsStore.save(settings)
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
                    .disabled(!settings.s3.isConfigured || isTesting)

                    if let testMessage {
                        Text(testMessage)
                            .font(.footnote)
                            .foregroundStyle(testMessage.hasPrefix("OK") ? .green : .secondary)
                    }
                }
            }
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Закрыть") {
                        ExportSettingsStore.save(settings)
                        dismiss()
                    }
                }
            }
            .onDisappear {
                ExportSettingsStore.save(settings)
            }
        }
    }

    private func testConnection() async {
        ExportSettingsStore.save(settings)
        isTesting = true
        testMessage = nil
        defer { isTesting = false }

        do {
            let exporter = S3Exporter(config: settings.s3)
            try await exporter.ensureBucket()
            let probe = Data("archscanner-ok".utf8)
            let key = [settings.s3.prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
                       "_probe.txt"]
                .filter { !$0.isEmpty }
                .joined(separator: "/")
            try await exporter.put(key: key, data: probe, contentType: "text/plain")
            await MainActor.run {
                testMessage = "OK — bucket \(settings.s3.bucket), объект \(key)"
            }
        } catch {
            await MainActor.run {
                testMessage = "Ошибка: \(error.localizedDescription)"
            }
        }
    }
}
