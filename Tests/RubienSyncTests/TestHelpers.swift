#if canImport(RubienSync)
import CloudKit
@testable import RubienSync

/// Build an empty `CKRecord` in the library zone. Centralised so tests don't
/// hardcode the zone lookup and so the construction shape stays consistent
/// as the sync record surface grows.
func makeTestRecord(recordType: String, recordName: String) -> CKRecord {
    let id = CKRecord.ID(recordName: recordName, zoneID: SyncConstants.libraryZoneID)
    return CKRecord(recordType: recordType, recordID: id)
}
#endif
