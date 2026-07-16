#if canImport(CloudKit)
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
        public static let readingActivity    = "CDReadingActivity"
        public static let assistantActivity  = "CDAssistantActivity"
        public static let activityEpoch      = "CDActivityEpoch"
        public static let referencePDF       = "CDReferencePDF"
    }

    /// Separator for composite-key pivot recordNames. `ReferenceTag`'s
    /// recordName is `"<referenceId>\(pivotSeparator)<tagId>"`; the same
    /// literal appears in `AppDatabase.pkExpression` trigger SQL. Keeping
    /// one constant means a future rename can't desync the two layers.
    public static let pivotSeparator: String = "/"

    /// Separator between the entity-type tag and the local id in a CKRecord
    /// recordName: `"<type>\(typeSeparator)<entityId>"`. Required because
    /// CloudKit's record key is `(recordName, zoneID)` without recordType,
    /// so Reference(1) and Tag(1) would collide without a type namespace.
    public static let typeSeparator: Character = ":"

    /// Age at which server-confirmed tombstones become eligible for GC.
    /// Picked to exceed CKSyncEngine's worst-case retry + any plausible
    /// in-flight push window; anything shorter risks evicting a marker
    /// before a lingering push hits `.unknownItem`.
    public static let tombstoneRetention: TimeInterval = 30 * 24 * 60 * 60

    /// Steady-state idle poll interval (seconds) while the app is frontmost
    /// and sync is active. Bounds worst-case idle-window staleness: a remote
    /// change made while you stare at an idle window appears within ~this long.
    /// Tunable — lower is snappier but spends more no-op fetch round-trips;
    /// mostly moot once push (Layer B) lands. Foreground/launch fetches are
    /// always immediate regardless of this value.
    public static let idleFetchInterval: TimeInterval = 90

    /// Backoff cap (seconds) for the idle poll after repeated fetch failures.
    public static let maxIdleFetchInterval: TimeInterval = 900
}
#endif
