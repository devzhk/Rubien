import Foundation

extension Notification.Name {
    static let rubienClipImported = Notification.Name("RubienClipImported")
}

enum RubienClipImportedKeys {
    static let id = "id"
    static let title = "title"
}
