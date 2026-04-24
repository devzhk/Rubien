import Foundation
import SwiftUI

enum RubienPreferences {
    /// 剪藏 YouTube 网页时，是否在后台拉取字幕并追加到 `notes`（默认关闭，避免额外请求与隐私顾虑）。
    static let appendYouTubeTranscriptOnClipKey = "Rubien.appendYouTubeTranscriptOnClip"

    static var appendYouTubeTranscriptOnClip: Bool {
        get { UserDefaults.standard.bool(forKey: appendYouTubeTranscriptOnClipKey) }
        set { UserDefaults.standard.set(newValue, forKey: appendYouTubeTranscriptOnClipKey) }
    }

    /// 用于 CrossRef / OpenAlex API polite pool 的联系邮箱。
    /// CrossRef 要求提供真实 mailto 才能进入 polite pool（更快速率限制）。
    static let apiContactEmailKey = "Rubien.apiContactEmail"

    static var apiContactEmail: String {
        get { UserDefaults.standard.string(forKey: apiContactEmailKey) ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: apiContactEmailKey) }
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
