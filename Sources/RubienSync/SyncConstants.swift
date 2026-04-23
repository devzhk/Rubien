import Foundation
import CloudKit

/// Constants shared between the CKRecord mapping layer and the future
/// `SyncedLibrary` actor. Single source of truth for CloudKit identifiers so
/// rename-style refactors don't silently drift between mapping code and the
/// sync engine's zone/record-type references.
public enum SyncConstants {

    /// CloudKit container identifier. Reads `RUBIEN_CLOUDKIT_CONTAINER`
    /// env var first (dev override) and falls back to the hardcoded
    /// production default. Must match the
    /// `com.apple.developer.icloud-container-identifiers` entitlement
    /// on both Mac and iPad builds.
    public static var containerIdentifier: String {
        ProcessInfo.processInfo.environment["RUBIEN_CLOUDKIT_CONTAINER"]
            ?? "iCloud.com.rubien.app"
    }

    /// Single custom zone holding all synced records. Custom zones (vs. the default zone)
    /// are required for `CKSyncEngine`'s incremental fetch and per-zone state tokens.
    public static let libraryZoneID = CKRecordZone.ID(
        zoneName: "Library",
        ownerName: CKCurrentUserDefaultName
    )

    /// Record-type names, one per synced GRDB entity. Matching
    /// `AppDatabase.syncedTables` / the dirty-tracking trigger set. The `CD`
    /// prefix ("CloudKit Data") keeps the names distinct from the local Swift
    /// types so grepping for either is unambiguous.
    public enum RecordType {
        public static let reference          = "CDReference"
        public static let tag                = "CDTag"
        public static let referenceTag       = "CDReferenceTag"
        public static let pdfAnnotation      = "CDPDFAnnotation"
        public static let webAnnotation      = "CDWebAnnotation"
        public static let metadataIntake     = "CDMetadataIntake"
        public static let metadataEvidence   = "CDMetadataEvidence"
        public static let propertyDefinition = "CDPropertyDefinition"
        public static let propertyValue      = "CDPropertyValue"
        public static let databaseView       = "CDDatabaseView"
        // Note: CDReferencePDF (sibling asset record) is deferred to B8 when
        // the CKAsset pipeline lands. Adding the constant without a
        // corresponding `SyncEntityType` case creates silent drift: pull
        // path's `forRecordType("CDReferencePDF")` would return nil and the
        // unknown-type log would fire on every PDF record.
    }

    /// Separator for composite-key pivot recordNames. `ReferenceTag`'s
    /// recordName is `"<referenceId>\(pivotSeparator)<tagId>"`; the same
    /// literal appears in `AppDatabase.pkExpression` trigger SQL. Keeping
    /// one constant means a future rename can't desync the two layers.
    public static let pivotSeparator: String = "/"

    /// Age at which server-confirmed tombstones become eligible for GC.
    /// Picked to exceed CKSyncEngine's worst-case retry + any plausible
    /// in-flight push window; anything shorter risks evicting a marker
    /// before a lingering push hits `.unknownItem`.
    public static let tombstoneRetention: TimeInterval = 30 * 24 * 60 * 60
}
