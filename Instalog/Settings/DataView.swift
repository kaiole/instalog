import InstalogCore
import SwiftUI
import UniformTypeIdentifiers

/// Lossless JSON export and validated full-replacement import.
struct DataView: View {
    let model: DiaryModel
    @State private var exportDocument: ExportFile?
    @State private var exporting = false
    @State private var importing = false
    @State private var pendingImport: PersonalDataSet?
    @State private var recoveryURL: URL?
    @State private var status: String?

    var body: some View {
        List {
            SwiftUI.Section {
                Button {
                    Task { await prepareExport() }
                } label: {
                    Label("Export all data", systemImage: "square.and.arrow.up")
                }
                .listRowBackground(Palette.raised)
            } header: {
                Caption("Export")
            } footer: {
                Text("A versioned JSON file with your foods, saved meals, sections, every logged entry with its nutrition snapshot, targets and preferences. It contains personal dietary information, so keep it somewhere private.")
            }
            SwiftUI.Section {
                Button(role: .destructive) {
                    importing = true
                } label: {
                    Label("Import and replace…", systemImage: "square.and.arrow.down")
                }
                .listRowBackground(Palette.raised)
            } header: {
                Caption("Import")
            } footer: {
                Text("Replaces everything on this device with the file’s contents after you confirm. A recovery export of your current data is saved first. Merging is not supported.")
            }
            if let status {
                SwiftUI.Section {
                    Text(status).font(Typeface.sans(13)).foregroundStyle(Palette.secondary)
                    if let recoveryURL {
                        ShareLink(item: recoveryURL) { Label("Share recovery export", systemImage: "doc") }
                    }
                }
                .listRowBackground(Palette.raised)
            }
            SwiftUI.Section {
                Text("Instalog keeps data only on this device. There’s no account and no app cloud sync; uninstalling deletes it unless you’ve exported it or your device backup includes it.")
                    .font(Typeface.sans(12))
                    .foregroundStyle(Palette.tertiary)
                    .listRowBackground(Color.clear)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.sheet)
        .navigationTitle("Your data")
        .navigationBarTitleDisplayMode(.inline)
        .fileExporter(
            isPresented: $exporting, document: exportDocument, contentType: .json,
            defaultFilename: "instalog-export-\(model.today)"
        ) { result in
            if case .failure(let error) = result { status = "Export failed: \(error.localizedDescription)" }
            if case .success = result { status = "Exported." }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            handleImport(result)
        }
        .alert(
            "Replace all data?", isPresented: Binding(get: { pendingImport != nil }, set: { if !$0 { pendingImport = nil } }),
            presenting: pendingImport
        ) { data in
            Button("Replace", role: .destructive) { Task { await performImport(data) } }
            Button("Cancel", role: .cancel) {}
        } message: { data in
            let preview = ExportService.preview(data)
            Text("The file has \(preview.entries) entries\(dateRange(preview)), \(preview.meals) saved meals, \(preview.sections) sections and \(preview.foods) foods. Everything currently on this device will be replaced. A recovery export is saved first.")
        }
        .foregroundStyle(Palette.text)
    }

    private func dateRange(_ preview: ImportPreview) -> String {
        guard let first = preview.firstDay, let last = preview.lastDay else { return "" }
        return " from \(first) to \(last)"
    }

    private func prepareExport() async {
        do {
            exportDocument = ExportFile(data: try await model.exportData())
            exporting = true
        } catch {
            status = "Export failed: \(error.localizedDescription)"
        }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            pendingImport = try ExportService.decode(try Data(contentsOf: url))
        } catch {
            status = "Nothing was imported. \(error.localizedDescription)"
        }
    }

    private func performImport(_ data: PersonalDataSet) async {
        do {
            let directory = try FileManager.default.url(
                for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            ).appendingPathComponent("Instalog/Recovery", isDirectory: true)
            recoveryURL = try await model.replaceAllData(with: data, recoveryDirectory: directory)
            status = "Imported. Your previous data was saved as a recovery export."
        } catch {
            status = "Nothing was imported; your existing data is unchanged. \(error.localizedDescription)"
        }
    }
}

struct ExportFile: FileDocument {
    static let readableContentTypes: [UTType] = [.json]
    let data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
