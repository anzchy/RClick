//
//  EditFileTypeSheetView.swift
//  RClick
//
//  Created by Claude on 2026/06/28.
//

import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct EditFileTypeSheetView: View {
    let file: NewFile
    let appState: AppState

    var isAdding: Bool { file.ext.isEmpty && file.name.isEmpty }

    @Environment(\.dismiss) private var dismiss

    @State private var name: String
    @State private var ext: String
    @State private var icon: String
    @State private var openApp: URL?
    @State private var draft: TemplateDraft
    @State private var replacementID: String?
    @State private var errorTitle = "Template Import Failed"
    @State private var templateError: String?
    @State private var showTemplateError = false

    @State private var showSelectApp = false
    @State private var showSelectTemplate = false

    let messager = Messager.shared

    private let iconToSF: [String: String] = [
        "icon-file-json": "curlybraces",
        "icon-file-txt": "doc.text",
        "icon-file-md": "doc.richtext",
        "icon-file-docx": "doc.richtext.fill",
        "icon-file-pptx": "rectangle.on.rectangle.fill",
        "icon-file-xlsx": "tablecells",
    ]

    init(file: NewFile, appState: AppState) {
        self.file = file
        self.appState = appState
        _name = State(initialValue: file.name)
        _ext = State(initialValue: file.ext)
        _icon = State(initialValue: file.icon)
        _openApp = State(initialValue: file.openApp)
        _draft = State(initialValue: TemplateDraft(file: file))
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(appLocalized: isAdding ? "Add File Type" : "Edit File Type")
                .font(.headline)
                .padding(.top, 20)
                .padding(.bottom, 12)

            Form {
                Section {
                    TextField(AppLocalization.localized("Display Name"), text: $name)
                        .textFieldStyle(.roundedBorder)
                } header: {
                    Text(appLocalized: "Name")
                }

                Section {
                    TextField(AppLocalization.localized("File Extension"), text: $ext)
                        .textFieldStyle(.roundedBorder)
                } header: {
                    Text(appLocalized: "File Extension")
                } footer: {
                    Text(appLocalized: "For example: txt, md, json")
                        .foregroundColor(.secondary)
                }

                Section {
                    Toggle(AppLocalization.localized("Blank"), isOn: $draft.blankEnabled)
                        .accessibilityLabel(AppLocalization.localized("Blank"))
                        .disabled(!file.supportsBlank(forExtension: ext))
                    if !file.supportsBlank(forExtension: ext) {
                        Text(appLocalized: "Blank is unavailable because this format requires a template.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    List {
                        ForEach($draft.entries) { $entry in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    Toggle(AppLocalization.localized("Enabled"), isOn: $entry.enabled)
                                        .labelsHidden()
                                        .accessibilityLabel(String(format: AppLocalization.localized("Enable Template %@"), entry.name))
                                    TextField(AppLocalization.localized("Template Name"), text: $entry.name)
                                        .textFieldStyle(.roundedBorder)
                                        .accessibilityLabel(AppLocalization.localized("Template Name"))
                                        .onSubmit { draft.rename(id: entry.id, name: entry.name) }
                                    Button(AppLocalization.localized("Replace File")) {
                                        replacementID = entry.id
                                        showSelectTemplate = true
                                    }
                                    .accessibilityLabel(String(format: AppLocalization.localized("Replace Template %@"), entry.name))
                                    Button {
                                        draft.entries.removeAll { $0.id == entry.id }
                                    } label: {
                                        Image(systemName: "trash")
                                    }
                                    .accessibilityLabel(String(format: AppLocalization.localized("Remove Template %@"), entry.name))
                                }
                                if entry.isMissing && !draft.hasPendingSnapshot(id: entry.id) {
                                    Text(appLocalized: "Missing Template")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                        .onMove { source, destination in
                            draft.entries.move(fromOffsets: source, toOffset: destination)
                        }
                    }
                    .frame(minHeight: 120, idealHeight: 160)
                    Button(AppLocalization.localized("Add Template")) {
                        replacementID = nil
                        showSelectTemplate = true
                    }
                    .fileImporter(isPresented: $showSelectTemplate, allowedContentTypes: [.item]) { result in
                        do {
                            let url = try result.get()
                            // Only the importer-granted read scope; no bookmark or persistent access.
                            let scoped = url.startAccessingSecurityScopedResource()
                            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                            if let replacementID {
                                try draft.replace(id: replacementID, source: url)
                            } else {
                                try draft.add(url, store: appState.newFileTemplateStore)
                            }
                        } catch {
                            errorTitle = "Template Import Failed"
                            templateError = error.localizedDescription
                            showTemplateError = true
                        }
                    }
                } header: {
                    Text(appLocalized: "Templates")
                }

                Section {
                    TextField(AppLocalization.localized("SF Symbol Name"), text: $icon)
                        .textFieldStyle(.roundedBorder)

                    if !icon.isEmpty {
                        HStack {
                            Text(appLocalized: "Preview:")
                            if let preview = FileTypeIconProvider.shared.icon(for: ext, fallbackSymbol: icon) {
                                Image(nsImage: preview)
                                    .resizable()
                                    .frame(width: 20, height: 20)
                            } else {
                                Image(systemName: "doc")
                                    .resizable()
                                    .frame(width: 20, height: 20)
                            }
                        }
                    }
                } header: {
                    Text(appLocalized: "Icon")
                } footer: {
                    Text(appLocalized: "Enter an SF Symbol name, for example doc.text or curlybraces")
                        .foregroundColor(.secondary)
                }

                Section {
                    HStack {
                        if let appUrl = openApp {
                            Image(nsImage: IconCache.shared.icon(for: appUrl))
                                .resizable()
                                .frame(width: 20, height: 20)
                            Text(appUrl.lastPathComponent)
                        }

                        Button {
                            showSelectApp = true
                        } label: {
                            Text(appLocalized: openApp == nil ? "Choose Default App" : "Change App")
                        }
                        .fileImporter(
                            isPresented: $showSelectApp,
                            allowedContentTypes: [.application],
                            allowsMultipleSelection: false
                        ) { result in
                            switch result {
                            case .success(let files):
                                if let url = files.first {
                                    openApp = url
                                }
                            case .failure:
                                break
                            }
                        }

                        if openApp != nil {
                            Button {
                                openApp = nil
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                        }
                    }
                } header: {
                    Text(appLocalized: "Default Open App")
                }
            }
            .formStyle(.grouped)

            HStack {
                Button(AppLocalization.localized("Cancel")) {
                    dismiss()
                }
                .keyboardShortcut(.escape)

                Button(AppLocalization.localized(isAdding ? "Add" : "Save")) {
                    do { try saveChanges(); dismiss() }
                    catch { errorTitle = "Unable to Save File Type"; templateError = error.localizedDescription; showTemplateError = true }
                }
                .keyboardShortcut(.return)
                .disabled(name.isEmpty || ext.isEmpty)
            }
            .padding(.bottom, 20)
        }
        .frame(width: 620, height: 760)
        .alert(Text(AppLocalization.localized(errorTitle)), isPresented: $showTemplateError) {
            Button(AppLocalization.localized("OK")) {}
        } message: {
            Text(templateError ?? "")
        }
    }

    private func saveChanges() throws {
        for entry in draft.entries { draft.rename(id: entry.id, name: entry.name) }
        var updated = try FileTypeEditDraft(name: name, ext: ext, icon: icon, openApp: openApp).applying(to: file)
        updated.template = nil
        updated.blankEnabled = draft.blankEnabled
        updated.templates = try draft.save(store: appState.newFileTemplateStore, replacing: file.userTemplates,
            retaining: appState.newFiles.filter { $0.id != file.id }.flatMap(\.userTemplates))
        if isAdding {
            updated.idx = appState.newFiles.count
            appState.addNewFile(updated)
        } else if let index = appState.newFiles.firstIndex(where: { $0.id == file.id }) {
            appState.newFiles[index] = updated
            appState.sync()
        }
        messager.sendRunningNotification()
    }
}


/// Fields shared by Add and Edit; template snapshots are committed only after validation.
struct FileTypeEditDraft {
    var name: String
    var ext: String
    var icon: String
    var openApp: URL?

    func applying(to file: NewFile) throws -> NewFile {
        var updated = file
        updated.name = name
        updated.ext = try Self.normalizedExtension(ext)
        updated.icon = icon
        updated.openApp = openApp
        return updated
    }
}


extension FileTypeEditDraft {
    static func normalizedExtension(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, !value.contains("/"), !value.allSatisfy({ $0 == "." }) else {
            throw FileTypeExtensionError.invalid
        }
        return value.hasPrefix(".") ? value : "." + value
    }
}

enum FileTypeExtensionError: LocalizedError {
    case invalid
    var errorDescription: String? {
        AppLocalization.localized("Enter a file extension without slashes, such as txt or .txt.")
    }
}
