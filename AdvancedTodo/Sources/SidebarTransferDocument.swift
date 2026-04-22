import SwiftUI
import UniformTypeIdentifiers

extension UTType {
    static let advancedTodoSidebar = UTType(exportedAs: "com.asduniontch.advancedtodo.sidebar")
}

struct SidebarTransferDocument: FileDocument {
    static var readableContentTypes: [UTType] {
        [.advancedTodoSidebar, .json]
    }

    var data: Data

    init(data: Data = Data()) {
        self.data = data
    }

    init(configuration: ReadConfiguration) throws {
        guard let fileData = configuration.file.regularFileContents else {
            throw CocoaError(.fileReadCorruptFile)
        }
        self.data = fileData
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
