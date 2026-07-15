import Foundation
import GRDB
// swift-corelibs-foundation does NOT re-export CoreFoundation symbols
// (`CFGetTypeID`, `CFBooleanGetTypeID`, …) through `import Foundation`, and the
// checkbox validator below needs the CFBoolean type-id check to tell a JSON
// `true` from a JSON `1` (`NSNumber(1) is Bool` is `true` on Apple platforms —
// the only reliable discriminator is the CFBoolean type id). Precedent:
// `Sources/RubienCLI/MCPToolCatalog.swift`.
#if canImport(CoreFoundation)
import CoreFoundation
#endif

// MARK: - Payload value model
//
// `update_reference`'s `properties` payload arrives as JSON parsed by
// JSONSerialization, so a JSON boolean and a JSON number both bridge to
// `NSNumber`. Decoding classifies each scalar once, up front, so downstream
// validation compares against a clean, closed representation instead of
// re-sniffing `NSNumber` everywhere.

/// A single JSON value from an `update_reference` cell payload, classified at
/// decode time. `integer` vs `decimal` is settled here (numbers must be
/// integral per §4.4) and `bool` is split from number via the CFBoolean check.
public enum PayloadValue: Equatable, Sendable {
    case string(String)
    case integer(Int64)
    /// A non-integral JSON number (`1.5`) — no property type accepts one, so it
    /// is preserved distinctly and rejected at validation with a typed error.
    case decimal(Double)
    case bool(Bool)
    case array([PayloadValue])
}

/// One entry in the `properties` cell payload. `replace` overwrites the cell,
/// `addRemove` is the idempotent multiSelect/Tags set mutation (`add` applies
/// before `remove`), `clear` (JSON `null`) empties a nullable cell.
public enum PropertyEntry: Equatable, Sendable {
    case replace(PayloadValue)
    case addRemove(add: [PayloadValue], remove: [PayloadValue])
    case clear
}

// MARK: - Built-in field classification (the §4.3 normative table)

/// Routing class for a seeded, column-backed built-in property. This is the
/// contract encoded in one place (`ReferenceFieldClassification.table`); the
/// exhaustiveness test asserts every seeded `defaultFieldKey` appears here
/// exactly once with the spec's class. Fail-closed: a seeded key absent from
/// the table is rejected at runtime as read-only.
public enum BuiltinFieldClass: Equatable, Sendable {
    /// Verbatim string → a `String?` Reference column; payload `null` clears it.
    case writableSimple
    /// Needs conversion before storage (type/status validated, year int,
    /// editors/translators `encodeNames`, accessedDate `YYYY-MM-DD` literal).
    case writableConverted
    /// The seeded Tags property — values are stringified tag ids diffed against
    /// the `referenceTag` pivot; `null` clears every tag.
    case tagsPivot
    /// App-managed reading telemetry (Last Read / Read Count) — never writable
    /// through the cell payload; no shadow `propertyValue` row is ever created.
    case readOnly
}

/// A row of the §4.3 classification table.
public struct BuiltinFieldRule: Equatable, Sendable {
    public let fieldClass: BuiltinFieldClass
    /// Whether payload `null` / a `clear` entry is accepted. `false` for the
    /// two non-nullable columns (Type/Status) and irrelevant for `readOnly`.
    public let clearable: Bool

    public init(fieldClass: BuiltinFieldClass, clearable: Bool) {
        self.fieldClass = fieldClass
        self.clearable = clearable
    }
}

/// The single source of truth for §4.3: every seeded `defaultFieldKey` mapped
/// to its routing class. Keyed by the `defaultFieldKey` code, not the display
/// name, because payload resolution ends at the definition's `defaultFieldKey`.
public enum ReferenceFieldClassification {
    public static let table: [String: BuiltinFieldRule] = {
        var t: [String: BuiltinFieldRule] = [:]

        // Type / Status — validated + converted, non-nullable columns.
        t["referenceType"] = BuiltinFieldRule(fieldClass: .writableConverted, clearable: false)
        t["readingStatus"] = BuiltinFieldRule(fieldClass: .writableConverted, clearable: false)

        // Tags — pivot exception.
        t["tags"] = BuiltinFieldRule(fieldClass: .tagsPivot, clearable: true)

        // Year — integer-converted, clearable.
        t["year"] = BuiltinFieldRule(fieldClass: .writableConverted, clearable: true)

        // Editors / Translators — display grammar → JSON author arrays.
        t["editors"] = BuiltinFieldRule(fieldClass: .writableConverted, clearable: true)
        t["translators"] = BuiltinFieldRule(fieldClass: .writableConverted, clearable: true)

        // Accessed Date — YYYY-MM-DD literal (seeded `string`, not `date`).
        t["accessedDate"] = BuiltinFieldRule(fieldClass: .writableConverted, clearable: true)

        // Writable-simple: verbatim string → same-named Reference column.
        for key in Self.simpleStringColumnKeys {
            t[key] = BuiltinFieldRule(fieldClass: .writableSimple, clearable: true)
        }

        // Reader telemetry — read-only.
        t["lastReadAt"] = BuiltinFieldRule(fieldClass: .readOnly, clearable: false)
        t["readCount"] = BuiltinFieldRule(fieldClass: .readOnly, clearable: false)

        return t
    }()

    /// The 21 writable-simple built-ins, each backed by a `String?` Reference
    /// column of the same name as its `defaultFieldKey`.
    static let simpleStringColumns: [String: WritableKeyPath<Reference, String?>] = [
        "doi": \.doi,
        "url": \.url,
        "journal": \.journal,
        "volume": \.volume,
        "issue": \.issue,
        "pages": \.pages,
        "publisher": \.publisher,
        "publisherPlace": \.publisherPlace,
        "edition": \.edition,
        "isbn": \.isbn,
        "issn": \.issn,
        "eventTitle": \.eventTitle,
        "eventPlace": \.eventPlace,
        "genre": \.genre,
        "institution": \.institution,
        "number": \.number,
        "collectionTitle": \.collectionTitle,
        "numberOfPages": \.numberOfPages,
        "language": \.language,
        "pmid": \.pmid,
        "pmcid": \.pmcid,
    ]

    static let simpleStringColumnKeys = Array(simpleStringColumns.keys)
}

// MARK: - ReferenceEdit input model

/// The decoded input for `AppDatabase.applyReferenceEdit`. Top-level metadata
/// fields mirror the CLI `update` flags (nil = not provided); `clearFields`
/// carries the top-level `--clear-field` spellings; `properties` is the decoded
/// cell payload. One value of this type = one `update_reference` call = one
/// transaction.
public struct ReferenceEdit: Sendable {
    public var title: String?
    public var year: Int?
    /// `--authors` display grammar (`"Last, First; Last, First"`), parsed via
    /// `AuthorName.parseList`.
    public var authors: String?
    /// A `ReferenceType` rawValue label (validated).
    public var referenceType: String?
    /// Live-validated against the current Status option set.
    public var readingStatus: String?
    public var journal: String?
    public var volume: String?
    public var issue: String?
    public var pages: String?
    public var doi: String?
    public var url: String?
    public var abstract: String?
    public var notes: String?
    public var publisher: String?
    public var isbn: String?
    public var issn: String?
    public var language: String?
    public var edition: String?
    /// Top-level field clears — the existing lowercase `--clear-field` list.
    public var clearFields: [String]
    /// The decoded cell payload, keyed by property id (all-digit) or exact name.
    public var properties: [String: PropertyEntry]

    public init(
        title: String? = nil,
        year: Int? = nil,
        authors: String? = nil,
        referenceType: String? = nil,
        readingStatus: String? = nil,
        journal: String? = nil,
        volume: String? = nil,
        issue: String? = nil,
        pages: String? = nil,
        doi: String? = nil,
        url: String? = nil,
        abstract: String? = nil,
        notes: String? = nil,
        publisher: String? = nil,
        isbn: String? = nil,
        issn: String? = nil,
        language: String? = nil,
        edition: String? = nil,
        clearFields: [String] = [],
        properties: [String: PropertyEntry] = [:]
    ) {
        self.title = title
        self.year = year
        self.authors = authors
        self.referenceType = referenceType
        self.readingStatus = readingStatus
        self.journal = journal
        self.volume = volume
        self.issue = issue
        self.pages = pages
        self.doi = doi
        self.url = url
        self.abstract = abstract
        self.notes = notes
        self.publisher = publisher
        self.isbn = isbn
        self.issn = issn
        self.language = language
        self.edition = edition
        self.clearFields = clearFields
        self.properties = properties
    }
}

// MARK: - Payload JSON decoding (pure)

extension ReferenceEdit {
    /// Decode the `--properties` / `properties` JSON object into a keyed
    /// `PropertyEntry` map. Pure — no database access. Structural problems
    /// (non-object root, an object value that isn't `add`/`remove`, a nested
    /// object or `null` element) throw `ReferenceEditError.invalidPayload`.
    public static func decodeProperties(fromJSON string: String) throws -> [String: PropertyEntry] {
        guard let data = string.data(using: .utf8) else {
            throw ReferenceEditError.invalidPayload(key: nil, message: "properties payload is not valid UTF-8")
        }
        return try decodeProperties(fromJSON: data)
    }

    public static func decodeProperties(fromJSON data: Data) throws -> [String: PropertyEntry] {
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ReferenceEditError.invalidPayload(key: nil, message: "properties payload is not valid JSON")
        }
        guard let dict = object as? [String: Any] else {
            throw ReferenceEditError.invalidPayload(key: nil, message: "properties payload must be a JSON object")
        }
        var result: [String: PropertyEntry] = [:]
        for (key, raw) in dict {
            result[key] = try decodeEntry(raw, key: key)
        }
        return result
    }

    private static func decodeEntry(_ raw: Any, key: String) throws -> PropertyEntry {
        if raw is NSNull { return .clear }
        if let object = raw as? [String: Any] {
            let allowed: Set<String> = ["add", "remove"]
            for k in object.keys where !allowed.contains(k) {
                throw ReferenceEditError.invalidPayload(
                    key: key,
                    message: "an object value accepts only 'add' and 'remove' keys"
                )
            }
            guard object["add"] != nil || object["remove"] != nil else {
                throw ReferenceEditError.invalidPayload(
                    key: key,
                    message: "an object value needs 'add' or 'remove'"
                )
            }
            let add = try decodeStringArray(object["add"], key: key, field: "add")
            let remove = try decodeStringArray(object["remove"], key: key, field: "remove")
            return .addRemove(add: add, remove: remove)
        }
        return .replace(try decodeScalarOrArray(raw, key: key))
    }

    /// `add` / `remove` must each be an array of JSON strings (multiSelect / Tags
    /// only). Absent → empty. A non-array or a non-string element is a structural
    /// error, matching §4.4 ("arrays of strings only").
    private static func decodeStringArray(_ raw: Any?, key: String, field: String) throws -> [PayloadValue] {
        guard let raw, !(raw is NSNull) else { return [] }
        guard let array = raw as? [Any] else {
            throw ReferenceEditError.invalidPayload(key: key, message: "'\(field)' must be an array of strings")
        }
        return try array.map { element in
            guard let s = element as? String else {
                throw ReferenceEditError.invalidPayload(key: key, message: "'\(field)' must contain only strings")
            }
            return .string(s)
        }
    }

    private static func decodeScalarOrArray(_ raw: Any, key: String) throws -> PayloadValue {
        if let s = raw as? String { return .string(s) }
        if let array = raw as? [Any] {
            return .array(try array.map { try decodeScalarOrArray($0, key: key) })
        }
        if let number = raw as? NSNumber {
            if payloadIsJSONBool(number) { return .bool(number.boolValue) }
            // Classify by the NSNumber's underlying CF type, not a magnitude
            // heuristic: JSONSerialization backs an integer literal with an
            // integer CFNumber and a fractional one with a float CFNumber, so any
            // in-range Int64 stays an integer (a JS-safe-integer cutoff would
            // wrongly reject large valid ids that the model + SQLite hold fine).
            if payloadIsIntegerNumber(number) {
                // Guard exact Int64 representability: on Linux a nonnegative
                // literal above Int64.max parses as a UInt64-backed integer
                // NSNumber whose `int64Value` silently wraps to a negative value.
                // The round-trip only holds when the value fits Int64.
                let i = number.int64Value
                if NSNumber(value: i) == number {
                    return .integer(i)
                }
            }
            return .decimal(number.doubleValue)
        }
        if raw is [String: Any] {
            throw ReferenceEditError.invalidPayload(key: key, message: "a nested object is not a valid value")
        }
        if raw is NSNull {
            throw ReferenceEditError.invalidPayload(key: key, message: "null is only valid as the whole value (clear)")
        }
        throw ReferenceEditError.invalidPayload(key: key, message: "unsupported value type")
    }
}

/// JSON `true`/`false` are backed by CFBoolean, numbers by CFNumber. `value is
/// Bool` is unreliable on Apple platforms (the lenient bridge), so use the
/// CFBoolean type id — the only reliable discriminator.
private func payloadIsJSONBool(_ number: NSNumber) -> Bool {
    #if canImport(CoreFoundation)
    return CFGetTypeID(number) == CFBooleanGetTypeID()
    #else
    return false
    #endif
}

/// True when a (non-boolean) JSON number is integer-backed. `CFNumberIsFloatType`
/// is the reliable test — `1` and `1.0` differ only in CFNumber subtype, and any
/// Int64-range integer literal is integer-backed regardless of magnitude.
private func payloadIsIntegerNumber(_ number: NSNumber) -> Bool {
    #if canImport(CoreFoundation)
    return !CFNumberIsFloatType(number)
    #else
    // Fallback (no CoreFoundation): integral only if the double round-trips.
    let d = number.doubleValue
    return d.rounded() == d && d >= -9.223e18 && d <= 9.223e18
    #endif
}

// MARK: - Errors

/// Surfaced by `applyReferenceEdit`. Cases stay distinct where the spec (§4.2–
/// §4.4) requires callers to tell them apart — notably read-only vs
/// non-nullable vs unresolved.
public enum ReferenceEditError: Error, Equatable {
    /// No reference with the given id.
    case referenceNotFound(Int64)
    /// A digit-only payload key that does not parse into `Int64`. It never falls
    /// back to name resolution (§4.2).
    case invalidSelector(String)
    /// One or more payload keys resolved to no property. Reported together — no
    /// partial application (§4.2 / §4.6). Sorted for deterministic output.
    case unresolvedSelectors([String])
    /// Two payload keys resolved to the same property (`{"7": …, "Themes": …}`
    /// where 7 is Themes). The whole call is rejected (§4.2).
    case duplicateResolution(propertyId: Int64, keys: [String])
    /// A payload entry targets the same canonical column as a top-level field or
    /// a `clearFields` entry (§4.4 conflict detection). Both spellings named.
    case conflict(field: String, payloadKey: String)
    /// A payload entry targets Last Read / Read Count (app-managed telemetry) or
    /// a seeded key missing from the classification table (fail-closed) (§4.3).
    case readOnlyBuiltin(String)
    /// Payload `null` / `clear` for a non-nullable built-in (Type/Status).
    /// Distinct from the unknown-field / unresolved error (§4.3).
    case nonNullableBuiltin(String)
    /// A `clearFields` spelling outside the accepted lowercase list.
    case unknownField(String)
    /// A value failed §4.4 validation (wrong JSON type, unknown option/tag,
    /// empty string, non-integer number, malformed date, …). `key` is the
    /// payload key.
    case invalidValue(key: String, message: String)
    /// Structural problem in the raw payload JSON (pure-decode stage). `key` is
    /// nil for whole-payload problems.
    case invalidPayload(key: String?, message: String)
}

/// Surfaced by the combined property/option mutation APIs. Kept separate from
/// `PropertyOptionError` so adding cases here never forces a recompile of the
/// CLI's exhaustive `PropertyOptionError` switch.
public enum PropertyMutationError: Error, Equatable {
    /// No property with the given id.
    case propertyNotFound
    /// Built-in property names are immutable (Tags et al.).
    case builtInRenameForbidden(String)
    /// A property name consisting entirely of ASCII digits is rejected so it can
    /// never shadow an id selector in the cell payload (§4.2).
    case allDigitName(String)
    /// Option mutations are refused on a fixed built-in (currently Type — its
    /// options drive BibTeX/RIS export buckets). Recolor included (§6).
    case immutableBuiltInOptions(String)
    /// A supplied color is not a `#RRGGBB` hex string.
    case invalidColor(String)
    /// The call requested no change (neither name nor visible; neither name nor
    /// color).
    case nothingToUpdate
}

// MARK: - applyReferenceEdit

extension AppDatabase {
    /// Apply a single-row cell edit atomically (spec §4.2–§4.5). Resolves and
    /// validates *everything* (selectors, conflicts, types, read-only/non-null
    /// guards) before writing, inside one `dbWriter.write` — so any failure
    /// rolls the whole call back. Returns the post-edit `Reference`.
    ///
    /// One `now` is captured per call and stamped only on rows that actually
    /// change: the `Reference` row when a column changed, each inserted/updated
    /// `PropertyValue`, and only the Tags pivots inserted/removed. A no-op entry
    /// (incoming value equals stored value) performs no write.
    @discardableResult
    public func applyReferenceEdit(id: Int64, edit: ReferenceEdit, now: Date = Date()) throws -> Reference {
        try applyReferenceEditReportingChange(id: id, edit: edit, now: now).reference
    }

    /// `applyReferenceEdit` variant that also reports whether the transaction
    /// actually wrote any row. The CLI uses it to suppress `notifyLibraryChanged`
    /// on a no-op edit (empty payload or every value already equal), so an
    /// unchanged edit produces no dirty-queue traffic or spurious sync upload
    /// (spec §4.5). The plain `applyReferenceEdit` delegates here and drops the
    /// flag, keeping every existing caller unchanged.
    public func applyReferenceEditReportingChange(
        id: Int64,
        edit: ReferenceEdit,
        now: Date = Date()
    ) throws -> (reference: Reference, didChange: Bool) {
        try dbWriter.write { db in
            guard let original = try Reference.fetchOne(db, id: id) else {
                throw ReferenceEditError.referenceNotFound(id)
            }

            // --- Build phase: mutate an in-memory copy + stage side writes,
            // validating as we go. No DB writes happen here, so a throw rolls
            // back to the pristine row.
            var edited = original

            // 1. Top-level metadata fields (mirror the CLI `update` flags).
            try applyTopLevelFields(edit: edit, to: &edited, db: db)

            // 2. Top-level clears (the lowercase `--clear-field` list).
            for field in edit.clearFields {
                try clearTopLevelField(field, on: &edited)
            }

            // 3. Resolve every payload selector to a PropertyDefinition.
            let resolutions = try resolvePayloadSelectors(edit.properties, db: db)

            // 4. Conflict detection — payload target vs top-level / clearFields.
            try detectConflicts(edit: edit, resolutions: resolutions)

            // 5. Classify + validate + stage each payload entry.
            var propertyValueOps: [(propertyId: Int64, value: String?)] = []
            var tagsFinalSet: Set<Int64>? = nil
            for resolution in resolutions {
                let entry = edit.properties[resolution.key]!
                if let fieldKey = resolution.definition.defaultFieldKey {
                    try stageBuiltinEntry(
                        key: resolution.key,
                        fieldKey: fieldKey,
                        entry: entry,
                        edited: &edited,
                        tagsFinalSet: &tagsFinalSet,
                        db: db
                    )
                } else {
                    let value = try convertCustomEntry(
                        key: resolution.key,
                        definition: resolution.definition,
                        entry: entry,
                        referenceId: id,
                        db: db
                    )
                    propertyValueOps.append((propertyId: resolution.definition.id!, value: value))
                }
            }

            // --- Apply phase: the only DB writes. `didChange` is true iff at
            // least one row was actually written (drives the CLI's no-op notify
            // suppression).
            var didChange = false

            // Reference row: stamp `now` only if a column actually changed.
            var withOriginalStamp = edited
            withOriginalStamp.dateModified = original.dateModified
            if withOriginalStamp != original {
                edited.dateModified = now
                try edited.update(db)
                didChange = true
            }

            // Custom property values: upsert/delete with per-row no-op + stamp.
            for op in propertyValueOps {
                if try upsertPropertyValueRow(
                    db,
                    referenceId: id,
                    propertyId: op.propertyId,
                    value: op.value,
                    now: now
                ) {
                    didChange = true
                }
            }

            // Tags: diff the pivot set — never delete-all + reinsert.
            if let finalSet = tagsFinalSet {
                if try applyTagsPivotDiff(db, referenceId: id, finalSet: finalSet, now: now) {
                    didChange = true
                }
            }

            let result = try Reference.fetchOne(db, id: id) ?? edited
            return (result, didChange)
        }
    }

    // MARK: Top-level fields

    private func applyTopLevelFields(edit: ReferenceEdit, to edited: inout Reference, db: Database) throws {
        if let title = edit.title { edited.title = title }
        if let year = edit.year { edited.year = year }
        if let authors = edit.authors { edited.authors = AuthorName.parseList(authors) }
        if let rt = edit.referenceType {
            guard let type = ReferenceType(rawValue: rt) else {
                let valid = ReferenceType.allCases.map(\.rawValue).joined(separator: ", ")
                throw ReferenceEditError.invalidValue(key: "type", message: "Unknown reference type '\(rt)'. Valid: \(valid)")
            }
            edited.referenceType = type
        }
        if let rs = edit.readingStatus {
            let options = try liveStatusOptions(db)
            guard options.contains(rs) else {
                throw ReferenceEditError.invalidValue(key: "readingStatus", message: "Unknown reading status '\(rs)'. Valid: \(options.joined(separator: ", "))")
            }
            edited.readingStatus = rs
        }
        if let v = edit.journal { edited.journal = v }
        if let v = edit.volume { edited.volume = v }
        if let v = edit.issue { edited.issue = v }
        if let v = edit.pages { edited.pages = v }
        if let v = edit.doi { edited.doi = v }
        if let v = edit.url { edited.url = v }
        if let v = edit.abstract { edited.abstract = v }
        if let v = edit.notes { edited.notes = v }
        if let v = edit.publisher { edited.publisher = v }
        if let v = edit.isbn { edited.isbn = v }
        if let v = edit.issn { edited.issn = v }
        if let v = edit.language { edited.language = v }
        if let v = edit.edition { edited.edition = v }
    }

    /// Column setters for the accepted lowercase `--clear-field` spellings — the
    /// existing CLI contract verbatim (`RubienCLI.swift:822`).
    private static let clearableStringColumns: [String: WritableKeyPath<Reference, String?>] = [
        "journal": \.journal,
        "volume": \.volume,
        "issue": \.issue,
        "pages": \.pages,
        "doi": \.doi,
        "url": \.url,
        "abstract": \.abstract,
        "notes": \.notes,
        "publisher": \.publisher,
        "isbn": \.isbn,
        "issn": \.issn,
        "language": \.language,
        "edition": \.edition,
    ]

    private func clearTopLevelField(_ field: String, on edited: inout Reference) throws {
        let lowered = field.lowercased()
        if lowered == "year" {
            edited.year = nil
            return
        }
        guard let keyPath = Self.clearableStringColumns[lowered] else {
            let valid = "year, " + Self.clearableStringColumns.keys.sorted().joined(separator: ", ")
            throw ReferenceEditError.unknownField("Unknown field '\(field)'. Valid: \(valid)")
        }
        edited[keyPath: keyPath] = nil
    }

    // MARK: Selector resolution

    private struct SelectorResolution {
        let key: String
        let definition: PropertyDefinition
    }

    private func resolvePayloadSelectors(
        _ properties: [String: PropertyEntry],
        db: Database
    ) throws -> [SelectorResolution] {
        var resolutions: [SelectorResolution] = []
        var unresolved: [String] = []
        // Deterministic iteration so error output is stable across runs.
        for key in properties.keys.sorted() {
            if isAllASCIIDigits(key) {
                guard let idValue = Int64(key) else {
                    // Digit-only but out of Int64 range → invalid selector; never
                    // fall back to name resolution.
                    throw ReferenceEditError.invalidSelector(key)
                }
                if let def = try PropertyDefinition.fetchOne(db, id: idValue) {
                    resolutions.append(SelectorResolution(key: key, definition: def))
                } else {
                    unresolved.append(key)
                }
            } else {
                if let def = try PropertyDefinition
                    .filter(PropertyDefinition.Columns.name == key)
                    .fetchOne(db) {
                    resolutions.append(SelectorResolution(key: key, definition: def))
                } else {
                    unresolved.append(key)
                }
            }
        }
        if !unresolved.isEmpty {
            throw ReferenceEditError.unresolvedSelectors(unresolved.sorted())
        }
        // Duplicate resolution: two keys → one property is an error.
        var byProperty: [Int64: [String]] = [:]
        for resolution in resolutions {
            byProperty[resolution.definition.id!, default: []].append(resolution.key)
        }
        for (propertyId, keys) in byProperty where keys.count > 1 {
            throw ReferenceEditError.duplicateResolution(propertyId: propertyId, keys: keys.sorted())
        }
        return resolutions
    }

    // MARK: Conflict detection

    private func detectConflicts(edit: ReferenceEdit, resolutions: [SelectorResolution]) throws {
        // Canonical targets already claimed by top-level values / clearFields.
        var claimed: [String: String] = [:]  // canonicalKey → spelling
        for (spelling, key) in topLevelFieldCanonicalKeys(edit: edit) {
            claimed[key] = spelling
        }
        for field in edit.clearFields {
            let lowered = field.lowercased()
            if lowered == "year" {
                claimed["year"] = field
            } else if Self.clearableStringColumns[lowered] != nil {
                claimed[lowered] = field
            }
            // Unknown clearFields spellings are rejected earlier in the apply
            // path; ignore here.
        }
        for resolution in resolutions {
            let canonical: String
            if let fieldKey = resolution.definition.defaultFieldKey {
                canonical = fieldKey
            } else {
                canonical = "custom:\(resolution.definition.id!)"
            }
            if let spelling = claimed[canonical] {
                throw ReferenceEditError.conflict(field: spelling, payloadKey: resolution.key)
            }
        }
    }

    /// Provided top-level fields → (spelling, canonicalKey). Only fields backed
    /// by a seeded `defaultFieldKey` can collide with a payload key; the rest
    /// (title/authors/abstract/notes) map to their own name, which no seeded
    /// definition uses, so they never produce a false conflict.
    private func topLevelFieldCanonicalKeys(edit: ReferenceEdit) -> [(spelling: String, key: String)] {
        var pairs: [(String, String)] = []
        if edit.title != nil { pairs.append(("title", "title")) }
        if edit.year != nil { pairs.append(("year", "year")) }
        if edit.authors != nil { pairs.append(("authors", "authors")) }
        if edit.referenceType != nil { pairs.append(("type", "referenceType")) }
        if edit.readingStatus != nil { pairs.append(("readingStatus", "readingStatus")) }
        if edit.journal != nil { pairs.append(("journal", "journal")) }
        if edit.volume != nil { pairs.append(("volume", "volume")) }
        if edit.issue != nil { pairs.append(("issue", "issue")) }
        if edit.pages != nil { pairs.append(("pages", "pages")) }
        if edit.doi != nil { pairs.append(("doi", "doi")) }
        if edit.url != nil { pairs.append(("url", "url")) }
        if edit.abstract != nil { pairs.append(("abstract", "abstract")) }
        if edit.notes != nil { pairs.append(("notes", "notes")) }
        if edit.publisher != nil { pairs.append(("publisher", "publisher")) }
        if edit.isbn != nil { pairs.append(("isbn", "isbn")) }
        if edit.issn != nil { pairs.append(("issn", "issn")) }
        if edit.language != nil { pairs.append(("language", "language")) }
        if edit.edition != nil { pairs.append(("edition", "edition")) }
        return pairs
    }

    // MARK: Built-in payload entries

    private func stageBuiltinEntry(
        key: String,
        fieldKey: String,
        entry: PropertyEntry,
        edited: inout Reference,
        tagsFinalSet: inout Set<Int64>?,
        db: Database
    ) throws {
        // Fail-closed: a seeded built-in absent from the table is read-only.
        guard let rule = ReferenceFieldClassification.table[fieldKey] else {
            throw ReferenceEditError.readOnlyBuiltin(key)
        }
        switch rule.fieldClass {
        case .readOnly:
            throw ReferenceEditError.readOnlyBuiltin(key)

        case .tagsPivot:
            tagsFinalSet = try resolveTagsFinalSet(key: key, entry: entry, referenceId: edited.id!, db: db)

        case .writableSimple:
            switch entry {
            case .clear:
                edited[keyPath: ReferenceFieldClassification.simpleStringColumns[fieldKey]!] = nil
            case .replace(let value):
                let string = try requireNonEmptyString(value, key: key)
                edited[keyPath: ReferenceFieldClassification.simpleStringColumns[fieldKey]!] = string
            case .addRemove:
                throw ReferenceEditError.invalidValue(key: key, message: "add/remove applies only to multiSelect properties")
            }

        case .writableConverted:
            try stageConvertedBuiltin(key: key, fieldKey: fieldKey, rule: rule, entry: entry, edited: &edited, db: db)
        }
    }

    private func stageConvertedBuiltin(
        key: String,
        fieldKey: String,
        rule: BuiltinFieldRule,
        entry: PropertyEntry,
        edited: inout Reference,
        db: Database
    ) throws {
        // Clears: guarded by nullability (Type/Status are non-nullable).
        if case .clear = entry {
            guard rule.clearable else {
                throw ReferenceEditError.nonNullableBuiltin(key)
            }
            switch fieldKey {
            case "year": edited.year = nil
            case "editors": edited.editors = nil
            case "translators": edited.translators = nil
            case "accessedDate": edited.accessedDate = nil
            default: throw ReferenceEditError.readOnlyBuiltin(key)
            }
            return
        }
        if case .addRemove = entry {
            throw ReferenceEditError.invalidValue(key: key, message: "add/remove applies only to multiSelect properties")
        }
        guard case .replace(let value) = entry else { return }

        switch fieldKey {
        case "referenceType":
            let label = try requireNonEmptyString(value, key: key)
            guard let type = ReferenceType(rawValue: label) else {
                let valid = ReferenceType.allCases.map(\.rawValue).joined(separator: ", ")
                throw ReferenceEditError.invalidValue(key: key, message: "Unknown reference type '\(label)'. Valid: \(valid)")
            }
            edited.referenceType = type

        case "readingStatus":
            let status = try requireNonEmptyString(value, key: key)
            let options = try liveStatusOptions(db)
            guard options.contains(status) else {
                throw ReferenceEditError.invalidValue(key: key, message: "Unknown reading status '\(status)'. Valid: \(options.joined(separator: ", "))")
            }
            edited.readingStatus = status

        case "year":
            guard case .integer(let n) = value else {
                throw ReferenceEditError.invalidValue(key: key, message: "Year must be a JSON integer")
            }
            edited.year = Int(n)

        case "editors", "translators":
            let display = try requireNonEmptyString(value, key: key)
            let parsed = AuthorName.parseList(display)
            // Compare decoded names, never re-encoded JSON: `encodeNames` uses an
            // unsorted `JSONEncoder`, so re-encoding identical names can reorder
            // keys and would spuriously stamp `dateModified` + dirty the row for
            // sync (also true for a historical row stored in a different key
            // order). Only assign when the names actually differ.
            let existingNames = (fieldKey == "editors") ? edited.parsedEditors : edited.parsedTranslators
            guard parsed != existingNames else { return }
            let encoded = Reference.encodeNames(parsed)
            if fieldKey == "editors" { edited.editors = encoded } else { edited.translators = encoded }

        case "accessedDate":
            let raw = try requireNonEmptyString(value, key: key)
            guard Self.calendarDate(fromYMD: raw) != nil else {
                throw ReferenceEditError.invalidValue(key: key, message: "Accessed Date must be a valid YYYY-MM-DD date")
            }
            edited.accessedDate = raw

        default:
            throw ReferenceEditError.readOnlyBuiltin(key)
        }
    }

    // MARK: Custom property entries (§4.4 type validation)

    private func convertCustomEntry(
        key: String,
        definition: PropertyDefinition,
        entry: PropertyEntry,
        referenceId: Int64,
        db: Database
    ) throws -> String? {
        switch definition.type {
        case .string:
            return try convertScalarCustom(key: key, entry: entry) { value in
                try self.requireNonEmptyString(value, key: key)
            }

        case .url:
            return try convertScalarCustom(key: key, entry: entry) { value in
                let s = try self.requireNonEmptyString(value, key: key)
                guard let parsed = URL(string: s),
                      let scheme = parsed.scheme?.lowercased(),
                      scheme == "http" || scheme == "https" else {
                    throw ReferenceEditError.invalidValue(key: key, message: "URL must be an absolute http/https URL")
                }
                return s
            }

        case .number:
            return try convertScalarCustom(key: key, entry: entry) { value in
                guard case .integer(let n) = value else {
                    throw ReferenceEditError.invalidValue(key: key, message: "must be a JSON integer")
                }
                return String(n)
            }

        case .date:
            return try convertScalarCustom(key: key, entry: entry) { value in
                let raw = try self.requireNonEmptyString(value, key: key)
                guard let date = Self.calendarDate(fromYMD: raw) else {
                    throw ReferenceEditError.invalidValue(key: key, message: "must be a valid YYYY-MM-DD date")
                }
                return Self.isoDateStorageFormatter.string(from: date)
            }

        case .checkbox:
            return try convertScalarCustom(key: key, entry: entry) { value in
                guard case .bool(let b) = value else {
                    throw ReferenceEditError.invalidValue(key: key, message: "must be a JSON boolean")
                }
                return b ? "true" : "false"
            }

        case .singleSelect:
            return try convertScalarCustom(key: key, entry: entry) { value in
                let option = try self.requireNonEmptyString(value, key: key)
                guard definition.options.contains(where: { $0.value == option }) else {
                    throw ReferenceEditError.invalidValue(key: key, message: "'\(option)' is not an existing option")
                }
                return option
            }

        case .multiSelect:
            return try convertCustomMultiSelect(
                key: key,
                definition: definition,
                entry: entry,
                referenceId: referenceId,
                db: db
            )
        }
    }

    /// Scalar (non-multiSelect) custom types: `clear` → delete row (nil),
    /// `replace` → validate/convert, `addRemove` → rejected.
    private func convertScalarCustom(
        key: String,
        entry: PropertyEntry,
        convert: (PayloadValue) throws -> String
    ) throws -> String? {
        switch entry {
        case .clear:
            return nil
        case .replace(let value):
            return try convert(value)
        case .addRemove:
            throw ReferenceEditError.invalidValue(key: key, message: "add/remove applies only to multiSelect properties")
        }
    }

    private func convertCustomMultiSelect(
        key: String,
        definition: PropertyDefinition,
        entry: PropertyEntry,
        referenceId: Int64,
        db: Database
    ) throws -> String? {
        let optionValues = Set(definition.options.map(\.value))
        func validate(_ elements: [String]) throws {
            for element in elements where !optionValues.contains(element) {
                throw ReferenceEditError.invalidValue(key: key, message: "'\(element)' is not an existing option")
            }
        }
        switch entry {
        case .clear:
            return nil
        case .replace(let value):
            let incoming = try requireStringSet(value, key: key)
            try validate(incoming)
            let canonical = dedupePreservingOrder(incoming)
            return canonical.isEmpty ? nil : PropertyValue.encodeMultiSelect(canonical)
        case .addRemove(let addValues, let removeValues):
            let add = try addValues.map { try requireStringElement($0, key: key) }
            let remove = try removeValues.map { try requireStringElement($0, key: key) }
            // Every supplied option must exist (§4.4) — add and remove alike; this
            // also rejects an empty-string element (never an existing option).
            try validate(add)
            try validate(remove)
            let current = try currentMultiSelectArray(referenceId: referenceId, propertyId: definition.id!, db: db)
            let drop = Set(remove)
            // Canonicalize the whole result: dedupe first-occurrence-wins across
            // the existing array + adds (a legacy stored array may carry dups),
            // dropping removed values.
            var seen = Set<String>()
            var next: [String] = []
            for value in current + add where !drop.contains(value) && seen.insert(value).inserted {
                next.append(value)
            }
            return next.isEmpty ? nil : PropertyValue.encodeMultiSelect(next)
        }
    }

    private func currentMultiSelectArray(referenceId: Int64, propertyId: Int64, db: Database) throws -> [String] {
        guard let row = try PropertyValue
            .filter(PropertyValue.Columns.referenceId == referenceId)
            .filter(PropertyValue.Columns.propertyId == propertyId)
            .fetchOne(db),
            let raw = row.value else {
            return []
        }
        return PropertyValue.decodeMultiSelect(raw)
    }

    // MARK: Tags pivot

    private func resolveTagsFinalSet(
        key: String,
        entry: PropertyEntry,
        referenceId: Int64,
        db: Database
    ) throws -> Set<Int64> {
        func parseTagId(_ element: PayloadValue) throws -> Int64 {
            let s = try requireStringElement(element, key: key)
            guard let id = Int64(s) else {
                throw ReferenceEditError.invalidValue(key: key, message: "Tags values must be stringified tag ids; '\(s)' is not")
            }
            return id
        }
        func ensureExist(_ ids: Set<Int64>) throws {
            guard !ids.isEmpty else { return }
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let existing = Set(try Int64.fetchAll(
                db,
                sql: "SELECT id FROM tag WHERE id IN (\(placeholders))",
                arguments: StatementArguments(Array(ids))
            ))
            for id in ids where !existing.contains(id) {
                throw ReferenceEditError.invalidValue(key: key, message: "Unknown tag id '\(id)'")
            }
        }
        switch entry {
        case .clear:
            return []
        case .replace(let value):
            let strings = try requireStringSet(value, key: key)
            var ids: [Int64] = []
            for s in strings {
                guard let id = Int64(s) else {
                    throw ReferenceEditError.invalidValue(key: key, message: "Tags values must be stringified tag ids; '\(s)' is not")
                }
                ids.append(id)
            }
            let set = Set(ids)
            try ensureExist(set)
            return set
        case .addRemove(let addValues, let removeValues):
            let addIds = Set(try addValues.map(parseTagId))
            let removeIds = Set(try removeValues.map(parseTagId))
            // Both add and remove tag ids must exist (§4.4). `parseTagId` already
            // rejects empty / non-numeric elements.
            try ensureExist(addIds)
            try ensureExist(removeIds)
            let current = try currentTagIds(referenceId: referenceId, db: db)
            return current.union(addIds).subtracting(removeIds)
        }
    }

    private func currentTagIds(referenceId: Int64, db: Database) throws -> Set<Int64> {
        Set(try Int64.fetchAll(
            db,
            sql: "SELECT tagId FROM referenceTag WHERE referenceId = ?",
            arguments: [referenceId]
        ))
    }

    /// Diff the desired final tag set against the current pivots: insert added,
    /// delete removed, leave unchanged pivots (and their timestamps) untouched.
    /// An unchanged set touches no rows.
    /// Returns `true` iff the pivot set actually changed (a row was inserted or
    /// deleted) — an unchanged set touches nothing (no timestamp churn).
    @discardableResult
    private func applyTagsPivotDiff(_ db: Database, referenceId: Int64, finalSet: Set<Int64>, now: Date) throws -> Bool {
        let current = try currentTagIds(referenceId: referenceId, db: db)
        let toInsert = finalSet.subtracting(current)
        let toDelete = current.subtracting(finalSet)
        for tagId in toInsert {
            try db.execute(
                sql: "INSERT OR IGNORE INTO referenceTag(referenceId, tagId, dateModified) VALUES (?, ?, ?)",
                arguments: [referenceId, tagId, now]
            )
        }
        if !toDelete.isEmpty {
            let placeholders = toDelete.map { _ in "?" }.joined(separator: ",")
            var args: [DatabaseValueConvertible] = [referenceId]
            args.append(contentsOf: toDelete.map { $0 as DatabaseValueConvertible })
            try db.execute(
                sql: "DELETE FROM referenceTag WHERE referenceId = ? AND tagId IN (\(placeholders))",
                arguments: StatementArguments(args)
            )
        }
        return !toInsert.isEmpty || !toDelete.isEmpty
    }

    // MARK: PropertyValue upsert (custom)

    /// Upsert or delete a `propertyValue` row with per-row no-op detection.
    /// Stamps `now` on any insert/update (fixing today's missed stamp on value
    /// updates); an unchanged value writes nothing. Returns `true` iff a row was
    /// actually inserted, updated, or deleted.
    @discardableResult
    private func upsertPropertyValueRow(
        _ db: Database,
        referenceId: Int64,
        propertyId: Int64,
        value: String?,
        now: Date
    ) throws -> Bool {
        let existing = try PropertyValue
            .filter(PropertyValue.Columns.referenceId == referenceId)
            .filter(PropertyValue.Columns.propertyId == propertyId)
            .fetchOne(db)
        if let value {
            if let existing {
                if existing.value == value { return false }  // no-op
                var updated = existing
                updated.value = value
                updated.dateModified = now
                try updated.update(db)
                return true
            } else {
                var pv = PropertyValue(referenceId: referenceId, propertyId: propertyId, value: value, dateModified: now)
                try pv.insert(db)
                return true
            }
        } else if let existing {
            _ = try existing.delete(db)
            return true
        }
        // nil over an absent row → no-op.
        return false
    }

    // MARK: Shared value helpers

    private func requireNonEmptyString(_ value: PayloadValue, key: String) throws -> String {
        guard case .string(let s) = value else {
            throw ReferenceEditError.invalidValue(key: key, message: "must be a JSON string")
        }
        guard !s.isEmpty else {
            throw ReferenceEditError.invalidValue(key: key, message: "empty string is not allowed (use null to clear)")
        }
        return s
    }

    /// A multiSelect/Tags replace accepts an array of strings or a single string
    /// (coerced to a one-element set). Non-string elements are rejected.
    private func requireStringSet(_ value: PayloadValue, key: String) throws -> [String] {
        switch value {
        case .string(let s):
            return [s]
        case .array(let elements):
            return try elements.map { try requireStringElement($0, key: key) }
        default:
            throw ReferenceEditError.invalidValue(key: key, message: "must be an array of strings or a single string")
        }
    }

    private func requireStringElement(_ value: PayloadValue, key: String) throws -> String {
        guard case .string(let s) = value else {
            throw ReferenceEditError.invalidValue(key: key, message: "elements must be strings")
        }
        return s
    }

    private func dedupePreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for value in values where seen.insert(value).inserted {
            result.append(value)
        }
        return result
    }

    private func liveStatusOptions(_ db: Database) throws -> [String] {
        if let def = try PropertyDefinition
            .filter(PropertyDefinition.Columns.defaultFieldKey == PropertyDefinition.readingStatusFieldKey)
            .fetchOne(db) {
            return def.options.map(\.value)
        }
        return ReadingStatus.builtIn
    }

    // MARK: Date + digit helpers

    /// Parse a strict `YYYY-MM-DD` calendar date at UTC midnight (rejects
    /// `2026-13-40` and non-4/2/2 shapes). Shared by accessedDate and custom
    /// `date` properties.
    static func calendarDate(fromYMD raw: String) -> Date? {
        // Enforce the exact YYYY-MM-DD shape before parsing so the formatter's
        // leniency around single digits can't slip through.
        guard raw.count == 10 else { return nil }
        let parts = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3,
              parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
              parts.allSatisfy({ $0.allSatisfy(\.isNumber) }) else {
            return nil
        }
        return ymdFormatter.date(from: raw)
    }

    private static let ymdFormatter: DateFormatter = {
        // `en_US_POSIX` already pins the Gregorian calendar; the UTC time zone is
        // set last so the parsed date lands at UTC midnight.
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// The app's existing custom-`date` storage form — ISO-8601 with internet
    /// date-time (UTC), matching `ReferenceTableCells`'s `cachedISO8601DateFormatter`.
    private static let isoDateStorageFormatter = ISO8601DateFormatter()
}

/// True when `s` is non-empty and every character is an ASCII digit 0–9 — the
/// "digit-only key is an id" test (§4.2) and the all-digit-name guard (§4.2).
func isAllASCIIDigits(_ s: String) -> Bool {
    guard !s.isEmpty else { return false }
    return s.allSatisfy { ("0"..."9").contains($0) }
}

// MARK: - Combined property / option mutations (atomic)

extension AppDatabase {
    /// Create a custom PropertyDefinition, rejecting all-digit names so they can
    /// never shadow an id selector in the cell payload (§4.2). One transaction.
    @discardableResult
    public func createPropertyDefinition(
        name: String,
        type: PropertyType,
        options: [SelectOption] = [],
        now: Date = Date()
    ) throws -> PropertyDefinition {
        try guardNotAllDigits(name)
        return try dbWriter.write { db in
            let maxOrder = try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sortOrder), 0) FROM propertyDefinition") ?? 0
            var prop = PropertyDefinition(
                name: name,
                type: type,
                options: options,
                sortOrder: maxOrder + 1,
                isDefault: false,
                isVisible: true,
                dateModified: now
            )
            prop.normalizeOptions()
            try prop.insert(db)
            return prop
        }
    }

    /// Combined name + visibility mutation in one transaction (spec §6). At
    /// least one of `name`/`visible`. Built-in names stay immutable; all-digit
    /// names are rejected. `dateModified` is stamped in Swift only when a field
    /// actually changes.
    @discardableResult
    public func updatePropertyDefinition(
        id: Int64,
        name: String? = nil,
        visible: Bool? = nil,
        now: Date = Date()
    ) throws -> PropertyDefinition {
        try updatePropertyDefinitionReportingChange(id: id, name: name, visible: visible, now: now).definition
    }

    /// `updatePropertyDefinition` variant that also reports whether a row was
    /// written, so the CLI can suppress `notifyLibraryChanged` on a no-op update
    /// (name/visible already equal — spec §4.5 no-op rule). The plain method
    /// delegates here and drops the flag.
    public func updatePropertyDefinitionReportingChange(
        id: Int64,
        name: String? = nil,
        visible: Bool? = nil,
        now: Date = Date()
    ) throws -> (definition: PropertyDefinition, didChange: Bool) {
        guard name != nil || visible != nil else {
            throw PropertyMutationError.nothingToUpdate
        }
        if let name { try guardNotAllDigits(name) }
        return try dbWriter.write { db in
            guard var prop = try PropertyDefinition.fetchOne(db, id: id) else {
                throw PropertyMutationError.propertyNotFound
            }
            var changed = false
            if let name, name != prop.name {
                if prop.isDefault {
                    throw PropertyMutationError.builtInRenameForbidden(prop.name)
                }
                prop.name = name
                changed = true
            }
            if let visible, visible != prop.isVisible {
                prop.isVisible = visible
                changed = true
            }
            if changed {
                prop.dateModified = now
                try prop.update(db)
            }
            return (prop, changed)
        }
    }

    /// Combined option rename + recolor in one transaction (spec §6), addressed
    /// by the option's original identity (for Tags: the stringified tag id).
    /// At least one of `newName`/`color`. Type's options stay fully immutable
    /// (recolor included). Tags recolor updates the `Tag` row; other selects
    /// update `optionsJSON`; a rename bulk-updates affected references.
    @discardableResult
    public func updatePropertyOption(
        propertyId: Int64,
        option: String,
        newName: String? = nil,
        color: String? = nil,
        now: Date = Date()
    ) throws -> PropertyDefinition {
        try updatePropertyOptionReportingChange(
            propertyId: propertyId, option: option, newName: newName, color: color, now: now
        ).definition
    }

    /// `updatePropertyOption` variant that also reports whether a row was
    /// written, so the CLI can suppress `notifyLibraryChanged` on a no-op update
    /// (name/color already equal — spec §4.5 no-op rule). The plain method
    /// delegates here and drops the flag.
    public func updatePropertyOptionReportingChange(
        propertyId: Int64,
        option: String,
        newName: String? = nil,
        color: String? = nil,
        now: Date = Date()
    ) throws -> (definition: PropertyDefinition, didChange: Bool) {
        guard newName != nil || color != nil else {
            throw PropertyMutationError.nothingToUpdate
        }
        if let color, !Self.isHexColor(color) {
            throw PropertyMutationError.invalidColor(color)
        }
        return try dbWriter.write { db in
            guard var prop = try PropertyDefinition.fetchOne(db, id: propertyId) else {
                throw PropertyOptionError.propertyNotFound
            }
            // Type-gate: only Status + Tags have user-mutable built-in options.
            if prop.isDefault,
               prop.defaultFieldKey != PropertyDefinition.readingStatusFieldKey,
               !prop.isTags {
                throw PropertyMutationError.immutableBuiltInOptions(prop.name)
            }

            // Tags routing: `option` = tag id; rename/recolor the Tag row.
            if prop.isTags {
                guard let tagId = Int64(option), var tag = try Tag.fetchOne(db, id: tagId) else {
                    throw PropertyOptionError.optionNotFound
                }
                var changed = false
                if let newName, newName != tag.name {
                    if try Tag.filter(Tag.Columns.name == newName).filter(Tag.Columns.id != tagId).fetchOne(db) != nil {
                        throw PropertyOptionError.duplicateValue(newName)
                    }
                    tag.name = newName
                    changed = true
                }
                if let color, color != tag.color {
                    tag.color = color
                    changed = true
                }
                if changed {
                    tag.dateModified = now
                    try tag.update(db)
                }
                return (prop, changed)
            }

            guard prop.type == .singleSelect || prop.type == .multiSelect else {
                throw PropertyOptionError.unsupportedPropertyType
            }
            var options = prop.options
            guard let idx = options.firstIndex(where: { $0.value == option }) else {
                throw PropertyOptionError.optionNotFound
            }
            let effectiveNewName: String? = (newName != nil && newName != option) ? newName : nil
            if let effectiveNewName, options.contains(where: { $0.value == effectiveNewName }) {
                throw PropertyOptionError.duplicateValue(effectiveNewName)
            }
            var changed = false
            let finalValue = effectiveNewName ?? options[idx].value
            let finalColor = color ?? options[idx].color
            if options[idx].value != finalValue || options[idx].color != finalColor {
                options[idx] = SelectOption(value: finalValue, color: finalColor)
                prop.options = options
                changed = true
            }
            if changed {
                prop.dateModified = now
                try prop.update(db)
            }

            // Bulk-update affected references for a rename (same routing as the
            // existing rename-option path).
            if let effectiveNewName {
                if prop.type == .singleSelect {
                    if let fieldKey = prop.defaultFieldKey,
                       fieldKey == PropertyDefinition.readingStatusFieldKey {
                        try db.execute(
                            sql: "UPDATE reference SET \(fieldKey) = ? WHERE \(fieldKey) = ?",
                            arguments: [effectiveNewName, option]
                        )
                    } else {
                        try db.execute(
                            sql: "UPDATE propertyValue SET value = ? WHERE propertyId = ? AND value = ?",
                            arguments: [effectiveNewName, propertyId, option]
                        )
                    }
                } else {
                    let rows = try PropertyValue
                        .filter(PropertyValue.Columns.propertyId == propertyId)
                        .fetchAll(db)
                    for var row in rows {
                        guard let raw = row.value else { continue }
                        let arr = PropertyValue.decodeMultiSelect(raw)
                        guard arr.contains(option) else { continue }
                        let next = arr.map { $0 == option ? effectiveNewName : $0 }
                        row.value = PropertyValue.encodeMultiSelect(next)
                        try row.update(db)
                    }
                }
            }
            let refreshed = try PropertyDefinition.fetchOne(db, id: propertyId) ?? prop
            return (refreshed, changed)
        }
    }

    private func guardNotAllDigits(_ name: String) throws {
        if isAllASCIIDigits(name) {
            throw PropertyMutationError.allDigitName(name)
        }
    }

    /// `#RRGGBB` only (6 hex digits) — the option-recolor contract (§6).
    static func isHexColor(_ s: String) -> Bool {
        guard s.count == 7, s.hasPrefix("#") else { return false }
        return s.dropFirst().allSatisfy { $0.isHexDigit }
    }
}
