#if os(macOS)
import SwiftUI

/// The composer's dictation-language switch, beside the microphone: a short
/// code for the language the next dictation starts in ("EN", "中"), opening a
/// menu of the system language, a quick list, and every supported language.
/// Absent below macOS 26, like the microphone.
struct ComposerDictationLanguageMenu: View {
    @ObservedObject var controller: DictationController
    let owner: DictationController.Owner
    /// Loaded once by the surface; empty until then, when the menu still lists
    /// "System Language" and the current choice.
    let languages: DictationLanguageLists
    /// Off in the control row's most compact layouts.
    var showsChevron = true
    let fontSize: CGFloat

    /// The same storage as `RubienPreferences.assistantDictationLocaleIdentifier`
    /// (empty or unset ⇒ the system language), observed so the label follows a
    /// choice made in another window or in Settings.
    @AppStorage(RubienPreferences.assistantDictationLocaleIdentifierKey)
    private var storedIdentifier = ""
    @State private var hovered = false

    var body: some View {
        if DictationEngines.isSupported {
            menu
        }
    }

    private var current: String? { storedIdentifier.isEmpty ? nil : storedIdentifier }

    private var menu: some View {
        Menu {
            Toggle(isOn: chosen(nil)) {
                Text("System Language (\(DictationLanguage.languageName(of: .current)))")
            }
            ForEach(quickIdentifiers, id: \.self) { identifier in
                Toggle(isOn: chosen(identifier)) {
                    Text(verbatim: DictationLanguage.displayName(for: identifier))
                }
            }
            Divider()
            Menu("All Languages") {
                ForEach(DictationLanguage.options(
                    supported: languages.supported,
                    storedIdentifier: current
                )) { option in
                    Toggle(isOn: chosen(option.id)) {
                        Text(verbatim: option.name)
                    }
                }
            }
        } label: {
            // ONE concatenated Text, like the other composer pickers: an HStack
            // of Texts does not render reliably in a borderless Menu label.
            labelText
                .padding(.horizontal, 6)
                .frame(height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        // The language applies to the next start, so it cannot change mid-session.
        .disabled(controller.state(for: owner) != .idle)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(hovered ? Color.primary.opacity(0.06) : Color.clear)
        )
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .help("Dictation language: \(fullName)")
        .accessibilityLabel("Dictation language")
        .accessibilityValue(fullName)
        .accessibilityIdentifier("composer-dictation-language")
    }

    private var quickIdentifiers: [String] {
        DictationLanguage.quickIdentifiers(
            preferred: languages.preferred,
            recents: RubienPreferences.assistantDictationRecentLocaleIdentifiers,
            current: current)
    }

    /// The language dictation would start in now.
    private var startLocale: Locale {
        DictationLanguage.startLocale(storedIdentifier: current)
    }

    private var fullName: String {
        guard let current else {
            return "System Language (\(DictationLanguage.languageName(of: .current)))"
        }
        return DictationLanguage.displayName(for: current)
    }

    private var labelText: Text {
        var text = Text(verbatim: DictationLanguage.shortCode(for: startLocale.identifier(.bcp47)))
            .foregroundStyle(Color.primary.opacity(0.80))
        if showsChevron {
            text = text
                + Text(" ")
                + Text(Image(systemName: "chevron.down"))
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
        }
        return text.font(.system(size: fontSize))
    }

    /// A menu row's checkmark: on for the current choice. Choosing the row that
    /// is already checked changes nothing.
    private func chosen(_ identifier: String?) -> Binding<Bool> {
        Binding(
            get: { current == identifier },
            set: { isOn in
                guard isOn else { return }
                DictationLanguage.choose(identifier)
            })
    }
}
#endif
