#if os(macOS) && DEBUG
import AppKit

/// Drives the real composer through a dictation session and writes a report,
/// so the feature can be checked end to end without a person at the keyboard.
///
/// Launch a debug build with `RUBIEN_DICTATION_SELFTEST` set to a directory.
/// With `RUBIEN_DICTATION_AUDIO_FILE` also set, audio comes from that recording
/// and no permission is involved; without it, the microphone is used and macOS
/// asks for access. The driver opens the Assistant Sidebar Harness and clicks
/// the dictation button with real mouse events at the position the button
/// reports, so hit-testing and everything below it is the production path.
/// (SwiftUI does not build its accessibility tree for an in-process query, so
/// the button cannot be found or pressed that way.)
@MainActor
enum DictationSelfTest {
    /// Where each composer's dictation button is, measured from the top-left of
    /// its window (title bar included), keyed by that composer's bridge.
    static var buttonFrames: [ObjectIdentifier: CGRect] = [:]

    static func runIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard let directory = environment["RUBIEN_DICTATION_SELFTEST"], !directory.isEmpty else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try? FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let expected = (environment["RUBIEN_DICTATION_SELFTEST_EXPECT"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
        let usesMicrophone = (environment["RUBIEN_DICTATION_AUDIO_FILE"] ?? "").isEmpty
        Task {
            var run = Run(output: output, expected: expected, usesMicrophone: usesMicrophone)
            await run.execute()
            run.writeReport()
            NSApp.terminate(nil)
        }
    }

    private struct Check: Encodable {
        let name: String
        let passed: Bool
        let detail: String
    }

    private struct Report: Encodable {
        let passed: Bool
        let usesMicrophone: Bool
        let checks: [Check]
        let log: [String]
    }

    private struct Failed: Error {
        let reason: String
    }

    @MainActor
    private struct Run {
        let output: URL
        let expected: [String]
        let usesMicrophone: Bool
        var checks: [Check] = []
        var log: [String] = []
        private let started = ContinuousClock.now

        private var controller: DictationController { .shared }

        mutating func note(_ message: String) {
            let elapsed = ContinuousClock.now - started
            log.append("[\(elapsed.formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 2))))] \(message)")
        }

        mutating func check(_ name: String, _ passed: Bool, _ detail: String = "") {
            checks.append(Check(name: name, passed: passed, detail: detail))
            note("\(passed ? "PASS" : "FAIL") \(name)\(detail.isEmpty ? "" : " — \(detail)")")
        }

        func writeReport() {
            let report = Report(
                passed: !checks.isEmpty && checks.allSatisfy(\.passed),
                usesMicrophone: usesMicrophone, checks: checks, log: log)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try? encoder.encode(report).write(to: output.appendingPathComponent("report.json"))
        }

        // MARK: Scenarios

        mutating func execute() async {
            do {
                AssistantSidebarHarnessWindowController.shared.show()
                let window = try await waitFor("harness window") {
                    NSApp.windows.first { $0.title == "Assistant Sidebar Harness" }
                }
                let editor = try await waitFor("composer editor") { Self.editor(in: window) }
                // The first frames are reported before the window has its final
                // size; wait for one inside the window that has stopped moving.
                var frame = try await waitFor("dictation button") { Self.buttonFrame(for: editor) }
                for _ in 0..<40 {
                    try await Task.sleep(for: .milliseconds(250))
                    let latest = Self.buttonFrame(for: editor) ?? .zero
                    if latest == frame { break }
                    frame = latest
                }
                check("button is present", true, "frame \(frame) in window \(window.frame.size)")
                snapshot(window, "1-idle")

                try await dictateAndStop(window: window, editor: editor)
                try await typingFreezes(window: window, editor: editor)
                try await sendFreezes(window: window, editor: editor)
            } catch let failure as Failed {
                check("self-test completed", false, failure.reason)
            } catch {
                check("self-test completed", false, "\(error)")
            }
            controller.freezeAll()
        }

        /// Dictate, let the text stream in, press Stop, and keep the result.
        private mutating func dictateAndStop(window: NSWindow, editor: ComposerNSTextView) async throws {
            clear(editor)
            try click(window, editor)
            note("clicked the button to start; state \(controller.state)")
            // The first run may wait on a permission prompt or a model download.
            try await waitUntil("listening", timeout: usesMicrophone ? 120 : 60) {
                controller.state == .listening
            }
            check("reaches listening", true)
            snapshot(window, "2-listening")

            if usesMicrophone {
                // Nobody may be speaking; hearing nothing is not a failure here.
                try await Task.sleep(for: .seconds(6))
                note("microphone text after 6 s: \"\(editor.string)\"")
            } else {
                try await waitUntil("streamed text", timeout: 30) { !editor.string.isEmpty }
                let partial = editor.string
                check("text streams while listening", controller.state == .listening, "\"\(partial)\"")
                // A recording stops supplying audio at its end, so the recognizer
                // holds the last words until Stop; a microphone keeps supplying
                // silence. Let the recording play out, then stop.
                try await Task.sleep(for: .seconds(5))
                note("text before Stop: \"\(editor.string)\"")
            }
            snapshot(window, "3-listening-with-text")

            try click(window, editor)
            note("clicked the button to stop; state \(controller.state)")
            try await waitUntil("idle after Stop", timeout: 10) { controller.state == .idle }
            let text = editor.string
            check("stop returns to idle with no failure", controller.failure == nil, "\(String(describing: controller.failure))")
            if !usesMicrophone {
                check("final text has the spoken words", Self.contains(text, expected), "\"\(text)\"")
            }
            check("editor keeps the dictated text", !usesMicrophone ? !text.isEmpty : true, "\"\(text)\"")
            snapshot(window, "4-after-stop")

            if !text.isEmpty {
                editor.undoManager?.undo()
                check("one undo removes the dictation", editor.string.isEmpty, "\"\(editor.string)\"")
                editor.undoManager?.redo()
                check("redo restores it", editor.string == text, "\"\(editor.string)\"")
            }
        }

        /// Typing while listening ends dictation at once and the typed text wins.
        private mutating func typingFreezes(window: NSWindow, editor: ComposerNSTextView) async throws {
            guard !usesMicrophone else { return }
            clear(editor)
            try click(window, editor)
            try await waitUntil("listening again", timeout: 60) { controller.state == .listening }
            try await waitUntil("some text", timeout: 30) { !editor.string.isEmpty }

            editor.insertText("!", replacementRange: editor.selectedRange())
            let frozen = editor.string
            check("typing ends dictation immediately", controller.state == .idle, "state \(controller.state)")
            check("typed text is kept", frozen.hasSuffix("!"), "\"\(frozen)\"")
            try await Task.sleep(for: .seconds(2))
            check("no dictated text arrives after typing", editor.string == frozen, "\"\(editor.string)\"")
        }

        /// ⌘↩ while listening sends what is visible and leaves nothing running.
        private mutating func sendFreezes(window: NSWindow, editor: ComposerNSTextView) async throws {
            guard !usesMicrophone else { return }
            clear(editor)
            try click(window, editor)
            try await waitUntil("listening a third time", timeout: 60) { controller.state == .listening }
            try await waitUntil("some text", timeout: 30) { !editor.string.isEmpty }
            let visible = editor.string

            editor.onCommandReturn()
            check("send ends dictation immediately", controller.state == .idle, "state \(controller.state)")
            try await waitUntil("draft cleared by send", timeout: 5) { editor.string.isEmpty }
            check("send cleared the draft", true, "sent \"\(visible)\"")
            try await Task.sleep(for: .seconds(2))
            check("nothing is dictated into the empty draft afterwards", editor.string.isEmpty, "\"\(editor.string)\"")
            snapshot(window, "5-after-send")
        }

        // MARK: Driving the UI

        private func clear(_ editor: ComposerNSTextView) {
            editor.window?.makeFirstResponder(editor)
            let whole = NSRange(location: 0, length: (editor.string as NSString).length)
            if whole.length > 0 { editor.insertText("", replacementRange: whole) }
        }

        /// A real click: mouse down and up through the window's own event
        /// dispatch, at the centre of the button.
        private func click(_ window: NSWindow, _ editor: ComposerNSTextView) throws {
            guard let frame = Self.buttonFrame(for: editor) else {
                throw Failed(reason: "dictation button not found")
            }
            let point = NSPoint(x: frame.midX, y: window.frame.height - frame.midY)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 0,
                    clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)
                else { throw Failed(reason: "could not create a mouse event") }
                window.sendEvent(event)
            }
        }

        private func snapshot(_ window: NSWindow, _ name: String) {
            guard let view = window.contentView,
                  let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)
            else { return }
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: output.appendingPathComponent("\(name).png"))
        }

        private func waitUntil(
            _ what: String,
            timeout: Double,
            _ condition: @MainActor () -> Bool
        ) async throws {
            let deadline = ContinuousClock.now + .seconds(timeout)
            while !condition() {
                guard ContinuousClock.now < deadline else {
                    throw Failed(reason: "timed out waiting for \(what); state \(controller.state), failure \(String(describing: controller.failure))")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }

        private func waitFor<T>(_ what: String, _ find: @MainActor () -> T?) async throws -> T {
            let deadline = ContinuousClock.now + .seconds(20)
            while true {
                if let found = find() { return found }
                guard ContinuousClock.now < deadline else { throw Failed(reason: "\(what) did not appear") }
                try await Task.sleep(for: .milliseconds(100))
            }
        }

        private static func contains(_ text: String, _ words: [String]) -> Bool {
            let lowered = text.lowercased()
            return !words.isEmpty && words.allSatisfy { lowered.contains($0) }
        }

        private static func editor(in window: NSWindow) -> ComposerNSTextView? {
            func search(_ view: NSView) -> ComposerNSTextView? {
                if let editor = view as? ComposerNSTextView { return editor }
                for subview in view.subviews {
                    if let found = search(subview) { return found }
                }
                return nil
            }
            return window.contentView.flatMap(search)
        }

        private static func buttonFrame(for editor: ComposerNSTextView) -> CGRect? {
            guard let bridge = editor.dictationBridge,
                  let frame = DictationSelfTest.buttonFrames[ObjectIdentifier(bridge)],
                  let size = editor.window?.frame.size,
                  frame.width > 0, CGRect(origin: .zero, size: size).contains(frame)
            else { return nil }
            return frame
        }
    }
}
#endif
