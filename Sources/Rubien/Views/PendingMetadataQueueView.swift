#if os(macOS)
import SwiftUI
import RubienCore

@MainActor
private final class PendingMetadataQueueModel: ObservableObject {
    let context: PendingMetadataReviewContext
    let session: ImportReviewSession

    init(
        database: AppDatabase,
        intakes: [MetadataIntake],
        resolver: MetadataResolver,
        onConfirmed: @escaping (Reference) -> Void
    ) {
        let context = PendingMetadataReviewContext(
            database: database,
            resolver: resolver,
            intakes: intakes,
            onConfirmed: onConfirmed
        )
        self.context = context
        self.session = ImportReviewSession(
            title: String(localized: "pendingQueue.title", bundle: .module),
            context: context
        )
    }
}

/// The durable queue reuses the same selected-confirmation sheet as ephemeral
/// imports. Its context gives discard different semantics: closing never
/// deletes pending database rows.
struct PendingMetadataQueueView: View {
    @StateObject private var model: PendingMetadataQueueModel
    private let onDelete: (MetadataIntake) -> Bool

    init(
        database: AppDatabase,
        intakes: [MetadataIntake],
        resolver: MetadataResolver,
        onConfirmed: @escaping (Reference) -> Void,
        onDelete: @escaping (MetadataIntake) -> Bool
    ) {
        _model = StateObject(
            wrappedValue: PendingMetadataQueueModel(
                database: database,
                intakes: intakes,
                resolver: resolver,
                onConfirmed: onConfirmed
            )
        )
        self.onDelete = onDelete
    }

    var body: some View {
        ImportReviewSheet(
            session: model.session,
            onDelete: { itemID in
                guard let intake = model.context.intake(for: itemID) else { return false }
                return onDelete(intake)
            }
        )
    }
}
#endif
