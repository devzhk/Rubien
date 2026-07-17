#if os(macOS)
import Foundation

extension Notification.Name {
    static let rubienOpenAssistantPaperReference = Notification.Name(
        "Rubien.openAssistantPaperReference")
    static let rubienAddAssistantPaperSource = Notification.Name(
        "Rubien.addAssistantPaperSource")
}

enum ChatPaperActionNotificationKeys {
    static let referenceID = "referenceID"
    static let sourceURL = "sourceURL"
}

/// Reader chat lives in an independent window, while reference-detail navigation
/// and Add Reference sheets belong to the main library window. Route those actions
/// through the main `ContentView`; ordinary source links can open directly.
@MainActor
enum ReaderChatPaperActions {
    static func openReference(_ referenceID: Int64) {
        openReference(referenceID, router: .shared)
    }

    static func openReference(
        _ referenceID: Int64,
        router: ContentWindowNotificationRouter
    ) {
        router.post(
            name: .rubienOpenAssistantPaperReference,
            userInfo: [ChatPaperActionNotificationKeys.referenceID: referenceID])
    }

    static func openSource(_ urlString: String) {
        ChatExternalLinkOpener.open(urlString)
    }

    static func addSource(_ urlString: String) {
        addSource(urlString, router: .shared)
    }

    static func addSource(
        _ urlString: String,
        router: ContentWindowNotificationRouter
    ) {
        guard ChatExternalLink.classify(urlString) != .reject else { return }
        router.post(
            name: .rubienAddAssistantPaperSource,
            userInfo: [ChatPaperActionNotificationKeys.sourceURL: urlString])
    }
}
#endif
