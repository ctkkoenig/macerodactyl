import SwiftUI

/// Files tab. Availability is decided by FileService's init: no stack folder
/// under the stacks root means the tab explains why instead of failing later.
struct FilesView: View {
    let store: ContainerStore
    let container: DockerContainer

    var body: some View {
        if let service = FileService(container: container, stacksRoot: AppSettings.stacksRoot) {
            FilesBrowserView(model: FilesModel(service: service))
        } else {
            unavailable
        }
    }

    private var unavailable: some View {
        let stacksPath = abbreviatePath(AppSettings.stacksRoot.path)
        let (title, reason): (String, String) = if container.composeWorkingDir == nil {
            (
                "No files to manage",
                "This is a bare docker run container — it has no stack folder. File editing is available for compose stacks whose folder lives under \(stacksPath)."
            )
        } else {
            (
                "Stack folder is outside \(stacksPath)",
                "This stack's compose project lives at \(abbreviatePath(container.composeWorkingDir ?? "")), outside the stacks folder, so file access is disabled. Move the stack under \(stacksPath) or change the stacks folder in Settings."
            )
        }
        return ContentUnavailableView {
            Label(title, systemImage: "folder.badge.questionmark")
        } description: {
            Text(reason)
        }
    }
}

private func abbreviatePath(_ path: String) -> String {
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
}

@MainActor
@Observable
final class FilesModel {
    let service: FileService

    private(set) var currentDirectory = ""
    private(set) var entries: [FileService.Entry] = []
    private(set) var listError: String?

    // Open file state
    private(set) var openPath: String?
    var editorText = ""
    private(set) var savedText = ""
    private(set) var lineEnding: LineEnding = .lf
    private(set) var knownModified: Date?
    private(set) var externallyChanged = false
    private(set) var fileMessage: String?

    var isDirty: Bool { openPath != nil && editorText != savedText }

    init(service: FileService) {
        self.service = service
        loadDirectory("")
    }

    func loadDirectory(_ relative: String) {
        do {
            entries = try service.list(relative)
            currentDirectory = relative
            listError = nil
        } catch {
            listError = Self.describe(error)
        }
    }

    func openFile(_ relativePath: String) {
        fileMessage = nil
        externallyChanged = false
        do {
            let content = try service.read(relativePath)
            openPath = relativePath
            editorText = content.text
            savedText = content.text
            lineEnding = content.lineEnding
            knownModified = content.modified
        } catch {
            openPath = relativePath
            editorText = ""
            savedText = ""
            fileMessage = Self.describe(error)
        }
    }

    func save() {
        guard let openPath, fileMessage == nil else { return }
        do {
            try service.write(openPath, text: editorText, lineEnding: lineEnding)
            savedText = editorText
            knownModified = service.modificationDate(openPath)
            externallyChanged = false
            loadDirectory(currentDirectory) // refresh sizes/dates
        } catch {
            fileMessage = Self.describe(error)
        }
    }

    func revert() {
        guard let openPath else { return }
        openFile(openPath)
    }

    func checkExternalChange() {
        guard let openPath, fileMessage == nil else { return }
        let current = service.modificationDate(openPath)
        if let known = knownModified, let current, current > known {
            externallyChanged = true
        }
    }

    func reloadFromDisk() {
        guard let openPath else { return }
        openFile(openPath)
    }

    func keepMineDespiteExternalChange() {
        knownModified = service.modificationDate(openPath ?? "")
        externallyChanged = false
    }

    static func describe(_ error: Error) -> String {
        switch error {
        case FileServiceError.tooLarge(let actual, let limit):
            let fmt = ByteCountFormatter()
            return "This file is \(fmt.string(fromByteCount: Int64(actual))) — larger than the \(fmt.string(fromByteCount: Int64(limit))) editing limit. Open it in another tool."
        case FileServiceError.binaryFile:
            return "This looks like a binary file (an archive, image, or similar). The editor only opens text so it can't mangle it."
        case FileServiceError.notFound:
            return "The file no longer exists."
        case FileServiceError.isDirectory:
            return "That's a directory."
        case FileServiceError.notARegularFile:
            return "Not a regular file."
        case FileServiceError.escapesRoot, FileServiceError.invalidPath:
            return "That path leaves the stack folder and was blocked."
        case FileServiceError.io(let detail):
            return "File error: \(detail)"
        default:
            return String(describing: error)
        }
    }
}

struct FilesBrowserView: View {
    @State var model: FilesModel

    var body: some View {
        HSplitView {
            browser
                .frame(minWidth: 220, idealWidth: 260, maxWidth: 400)
            editorPane
                .frame(minWidth: 320, maxWidth: .infinity)
        }
    }

    // MARK: Browser column

    private var browser: some View {
        VStack(spacing: 0) {
            breadcrumb
            Divider()
            if let listError = model.listError {
                ContentUnavailableView("Can't list folder", systemImage: "exclamationmark.triangle", description: Text(listError))
            } else {
                List(model.entries) { entry in
                    entryRow(entry)
                }
                .listStyle(.inset)
            }
        }
    }

    private var breadcrumb: some View {
        HStack(spacing: 4) {
            Button {
                model.loadDirectory("")
            } label: {
                Image(systemName: "folder")
            }
            .buttonStyle(.borderless)
            let parts = model.currentDirectory.split(separator: "/").map(String.init)
            ForEach(Array(parts.enumerated()), id: \.offset) { index, part in
                Text("/").foregroundStyle(.tertiary)
                Button(part) {
                    model.loadDirectory(parts[0...index].joined(separator: "/"))
                }
                .buttonStyle(.borderless)
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([
                    model.service.root.appending(path: model.currentDirectory),
                ])
            } label: {
                Image(systemName: "arrow.up.forward.app")
            }
            .buttonStyle(.borderless)
            .help("Open in Finder")
        }
        .font(.callout)
        .lineLimit(1)
        .padding(8)
    }

    @ViewBuilder
    private func entryRow(_ entry: FileService.Entry) -> some View {
        Button {
            if entry.isDirectory {
                model.loadDirectory(entry.relativePath)
            } else {
                model.openFile(entry.relativePath)
            }
        } label: {
            HStack {
                Image(systemName: entry.isDirectory ? "folder.fill" : "doc.text")
                    .foregroundStyle(entry.isDirectory ? Color.accentColor : .secondary)
                Text(entry.name)
                    .lineLimit(1)
                Spacer()
                if !entry.isDirectory {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(entry.sizeBytes), countStyle: .file))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(entry.relativePath == model.openPath ? Color.accentColor.opacity(0.12) : nil)
    }

    // MARK: Editor pane

    @ViewBuilder
    private var editorPane: some View {
        if let openPath = model.openPath {
            VStack(spacing: 0) {
                editorHeader(openPath)
                Divider()
                if model.externallyChanged {
                    externalChangeBanner
                    Divider()
                }
                if let message = model.fileMessage {
                    ContentUnavailableView("Can't edit this file", systemImage: "doc.questionmark", description: Text(message))
                } else {
                    TextEditor(text: $model.editorText)
                        .font(.system(size: 12.5, design: .monospaced))
                        .autocorrectionDisabled()
                        .scrollContentBackground(.hidden)
                        .background(Color(nsColor: .textBackgroundColor))
                        .task(id: openPath) {
                            while !Task.isCancelled {
                                try? await Task.sleep(for: .seconds(2))
                                model.checkExternalChange()
                            }
                        }
                }
            }
        } else {
            ContentUnavailableView(
                "Select a file",
                systemImage: "doc.text",
                description: Text("Pick a text file on the left to view and edit it.")
            )
        }
    }

    private func editorHeader(_ openPath: String) -> some View {
        HStack(spacing: 8) {
            if model.isDirty {
                Circle().fill(Color.accentColor).frame(width: 7, height: 7)
                    .help("Unsaved changes")
            }
            Text(openPath)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.head)
            Spacer()
            Button("Revert") { model.revert() }
                .disabled(!model.isDirty)
            Button("Save") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
                .disabled(!model.isDirty || model.fileMessage != nil)
                .buttonStyle(.borderedProminent)
        }
        .controlSize(.small)
        .padding(8)
    }

    private var externalChangeBanner: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)
            Text("This file changed on disk while you were editing.")
                .font(.callout)
            Spacer()
            Button("Reload from disk") { model.reloadFromDisk() }
            Button("Keep my version") { model.keepMineDespiteExternalChange() }
        }
        .controlSize(.small)
        .padding(8)
        .background(.yellow.opacity(0.1))
    }
}
