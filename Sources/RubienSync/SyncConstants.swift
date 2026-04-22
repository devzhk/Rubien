import Foundation
import CloudKit

/// Constants shared between the CKRecord mapping layer and the future
/// `SyncedLibrary` actor. Single source of truth for CloudKit identifiers so
/// rename-style refactors don't silently drift between mapping code and the
/// sync engine's zone/record-type references.
public enum SyncConstants {

    /// CloudKit container identifier. Must match the `com.apple.developer.icloud-container-identifiers`
    /// entitlement on both the Mac and iPad apps. Pending user confirmation / dashboard registration.
    public static let containerIdentifier = "iCloud.com.rubien.app"

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
        /// Sibling of CDReference holding the optional PDF CKAsset and filename.
        /// Kept separate so PDF attach/detach merges independently of scalar edits.
        public static let referencePDF       = "CDReferencePDF"
    }
}
