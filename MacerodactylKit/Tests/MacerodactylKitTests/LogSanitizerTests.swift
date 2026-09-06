import Foundation
import Testing

@testable import MacerodactylKit

@Suite struct LogSanitizerTests {

    /// The case this was written for. Every line Paper emits through a TTY is a
    /// prompt, a carriage return, an erase-line, then the message.
    @Test func paperConsolePromptIsRemoved() {
        let raw = ">....\u{0D}\u{1B}[K[00:15:05 INFO]: [Essentials] CommandBlock at -16,-46,227"
        #expect(LogSanitizer.clean(raw) == "[00:15:05 INFO]: [Essentials] CommandBlock at -16,-46,227")
    }

    /// A prompt redraw with nothing after it cleans to nothing, which is what
    /// lets the stream drop it instead of printing a bare `>....`.
    @Test func promptOnlyLineCleansToEmpty() {
        #expect(LogSanitizer.clean(">....\u{0D}\u{1B}[K").isEmpty)
    }

    /// `docker logs --timestamps` puts its stamp before the container's output,
    /// so it must survive the carriage-return rule — the history path sorts on it.
    @Test func dockerTimestampPrefixSurvives() {
        let raw = "2026-09-06T00:15:05.123456789Z >....\u{0D}\u{1B}[K[00:15:05 INFO]: done"
        #expect(LogSanitizer.clean(raw) == "2026-09-06T00:15:05.123456789Z [00:15:05 INFO]: done")
    }

    /// A trailing CR is a CRLF remnant, not an overwrite. Treating it as one
    /// would blank every line on a CRLF-emitting container.
    @Test func trailingCarriageReturnDoesNotBlankTheLine() {
        #expect(LogSanitizer.clean("plain line\u{0D}") == "plain line")
    }

    /// Terminal overwrite semantics: only what survived the last CR was ever
    /// visible. A progress bar should collapse to its final state.
    @Test func onlyTextAfterFinalCarriageReturnIsKept() {
        #expect(LogSanitizer.clean("10%\u{0D}55%\u{0D}100%") == "100%")
    }

    @Test func ansiColourCodesAreStripped() {
        let raw = "\u{1B}[32mINFO\u{1B}[0m ready"
        #expect(LogSanitizer.clean(raw) == "INFO ready")
    }

    /// Tabs are layout a reader depends on; every other C0 control is terminal
    /// machinery.
    @Test func tabsSurviveButOtherControlsDoNot() {
        #expect(LogSanitizer.clean("a\tb\u{07}c") == "a\tbc")
    }

    @Test func ordinaryLinesAreUntouched() {
        let raw = "2026-09-06 00:15:05 INFO  starting up [worker=3] 100% ok"
        #expect(LogSanitizer.clean(raw) == raw)
    }

    @Test func emptyLineStaysEmpty() {
        #expect(LogSanitizer.clean("").isEmpty)
    }

    /// A bracketed word must not be mistaken for an escape sequence — only a
    /// real ESC introduces one.
    @Test func bracketsWithoutEscapeAreNotStripped() {
        #expect(LogSanitizer.clean("[INFO] [Essentials] loaded") == "[INFO] [Essentials] loaded")
    }
}
