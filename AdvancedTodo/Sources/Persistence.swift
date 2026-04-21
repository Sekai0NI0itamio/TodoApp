import Foundation
import AppKit

struct WindowFrame: Codable, Equatable {
    var x: Double
    var y: Double
    var width: Double
    var height: Double
}

struct StoredTodo: Codable, Identifiable, Equatable {
    var id: UUID
    var title: String
    var descriptionRTF: Data
    var dueDate: Date
    var isCompleted: Bool
    var completionDate: Date?

    init(todo: TodoItem) {
        id = todo.id
        title = todo.title
        descriptionRTF = todo.description.rtfData() ?? Data()
        dueDate = todo.dueDate
        isCompleted = todo.isCompleted
        completionDate = todo.completionDate
    }

    func makeTodo() -> TodoItem {
        TodoItem(
            id: id,
            title: title,
            description: NSAttributedString.fromRTFData(descriptionRTF),
            dueDate: dueDate,
            isCompleted: isCompleted,
            completionDate: completionDate
        )
    }
}

struct AppSnapshot: Codable, Equatable {
    var todos: [StoredTodo]
    var selectedCategory: String
    var scrollAnchorTodoID: UUID?
    var mainWindowFrame: WindowFrame?
}

extension NSAttributedString {
    func rtfData() -> Data? {
        try? data(from: NSRange(location: 0, length: length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
    }

    static func fromRTFData(_ data: Data) -> NSAttributedString {
        guard !data.isEmpty else { return NSAttributedString(string: "") }
        return (try? NSAttributedString(
            data: data,
            options: [.documentType: NSAttributedString.DocumentType.rtf],
            documentAttributes: nil
        )) ?? NSAttributedString(string: "")
    }
}
