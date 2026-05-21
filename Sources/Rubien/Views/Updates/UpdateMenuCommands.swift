#if canImport(Sparkle)
import SwiftUI

/// Adds a "Restart to Install Update" menu item to the Rubien app menu,
/// just before the standard `Quit Rubien` entry. The item is bound to
/// ⇧⌘R and stays disabled until `UpdateController.updateReadyToInstall`
/// flips to true.
///
/// The controller is plumbed through `FocusedValues` rather than read
/// directly from the environment so the Commands block can reach the
/// same `UpdateController` instance owned by `RubienApp`. SwiftUI's
/// `.commands { }` modifier attaches to a Scene, where the SwiftUI
/// environment chain isn't directly readable, but focused-scene values
/// published from the scene's root view are.
struct UpdateMenuCommands: Commands {
    @FocusedValue(\.updateController) private var updateController

    var body: some Commands {
        CommandGroup(before: .appTermination) {
            Button("Restart to Install Update") {
                updateController?.installAndRelaunch()
            }
            .disabled(updateController?.updateReadyToInstall != true)
            .keyboardShortcut(.init("R"), modifiers: [.command, .shift])
        }
    }
}

private struct UpdateControllerFocusedValueKey: FocusedValueKey {
    typealias Value = UpdateController
}

extension FocusedValues {
    var updateController: UpdateController? {
        get { self[UpdateControllerFocusedValueKey.self] }
        set { self[UpdateControllerFocusedValueKey.self] = newValue }
    }
}
#endif
