#if os(macOS)
import Foundation
import SwiftUI

enum RubienPreferences {
    /// 用于 CrossRef / OpenAlex API polite pool 的联系邮箱。
    /// CrossRef 要求提供真实 mailto 才能进入 polite pool（更快速率限制）。
    static let apiContactEmailKey = "Rubien.apiContactEmail"

    static var apiContactEmail: String {
        get { UserDefaults.standard.string(forKey: apiContactEmailKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: apiContactEmailKey) }
    }

    /// Gates the B8 PDF asset sync (CDReferencePDF push/pull). Default
    /// flipped from false → true in Phase E Task 35 once the schema
    /// invariant test + dateModified cleanup landed. Users can still
    /// opt out by setting the value to false explicitly. Setting at
    /// runtime stops the upload-queue drainer; existing
    /// pdfUploadQueue rows accumulate harmlessly until the flag flips
    /// back on.
    static let pdfAssetSyncEnabledKey = "Rubien.pdfAssetSyncEnabled"

    static var pdfAssetSyncEnabled: Bool {
        get {
            // Treat unset as true now that B8 has shipped. Users who
            // explicitly set the key to false (via prefs or CLI) keep
            // the asset sync disabled.
            let defaults = UserDefaults.standard
            if defaults.object(forKey: pdfAssetSyncEnabledKey) == nil { return true }
            return defaults.bool(forKey: pdfAssetSyncEnabledKey)
        }
        set { UserDefaults.standard.set(newValue, forKey: pdfAssetSyncEnabledKey) }
    }

    static let columnConfigsKey = "Rubien.columnConfigs"
    static let tableColumnCustomizationKey = "Rubien.tableColumnCustomization"

    static func loadTableColumnCustomization<R: Identifiable>() -> TableColumnCustomization<R> {
        guard let data = UserDefaults.standard.data(forKey: tableColumnCustomizationKey),
              let decoded = try? JSONDecoder().decode(TableColumnCustomization<R>.self, from: data) else {
            return TableColumnCustomization<R>()
        }
        return decoded
    }

    static func saveTableColumnCustomization<R: Identifiable>(_ value: TableColumnCustomization<R>) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        UserDefaults.standard.set(data, forKey: tableColumnCustomizationKey)
    }
}
#endif
