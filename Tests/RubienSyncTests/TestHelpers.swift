#if os(macOS)
import CloudKit
import XCTest
@testable import RubienSync

/// Build an empty `CKRecord` in the library zone. Centralised so tests don't
/// hardcode the zone lookup and so the construction shape stays consistent
/// as the sync record surface grows.
func makeTestRecord(recordType: String, recordName: String) -> CKRecord {
    let id = CKRecord.ID(recordName: recordName, zoneID: SyncConstants.libraryZoneID)
    return CKRecord(recordType: recordType, recordID: id)
}
/// CKRecord routes setValue(forKey:) to user fields, including reserved-key
/// rejection. Use its test-only Objective-C setter to model a server response.
func setTestRecordChangeTag(_ record: CKRecord, _ tag: String) {
    let setter = NSSelectorFromString("setRecordChangeTag:")
    guard record.responds(to: setter) else {
        XCTFail("CloudKit fixture cannot set a server change tag on this SDK")
        return
    }
    record.perform(setter, with: tag)
}
#endif
