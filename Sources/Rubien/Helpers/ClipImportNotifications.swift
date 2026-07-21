#if os(macOS)
import Foundation

extension Notification.Name {
    static let rubienClipImported = Notification.Name("RubienClipImported")
    static let rubienOpenBrowserImport = Notification.Name("RubienOpenBrowserImport")
}

enum RubienClipImportedKeys {
    static let id = "id"
    static let title = "title"
}

enum RubienOpenBrowserImportKeys {
    static let referenceID = "referenceID"
    static let intakeID = "intakeID"
}
#endif
