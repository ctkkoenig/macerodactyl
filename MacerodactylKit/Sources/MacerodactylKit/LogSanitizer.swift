import Foundation

/// Makes terminal output safe to display outside a terminal.
///
/// A container started with `tty: true` (compose) or `-t` writes to a PTY, so
/// its "log lines" are not text — they are a terminal *session*, complete with
/// cursor control. Paper's Minecraft console is the worst case in practice:
/// every single line docker hands back looks like
///
///     >....\r\u{1B}[K[00:15:05 INFO]: [Essentials] CommandBlock at ...
///
/// A terminal renders that as just the message: the `\r` returns the cursor to
/// column zero and `\u{1B}[K` erases the prompt that was sitting there. Nothing
/// downstream of docker does either of those things, so the prompt survives and
/// the log fills with `>....`.
///
/// The carriage return is worse than cosmetic over the web panel. Server-Sent
/// Events terminate a field on CR, LF, *or* CRLF, so a `\r` inside a `data:`
/// payload splits one log line into two events — the first containing only the
/// prompt. That is why the panel showed a column of bare `>....` rather than
/// prompt-then-message.
///
/// Applied at `LogStreamService`, which is the single point every consumer goes
/// through: the SwiftUI log view, both panel container services, and KitCheck.
public enum LogSanitizer {

	/// Cleans one line of container output.
	///
	/// Order matters. Carriage returns are resolved *first*, because that is
	/// what a terminal does first — everything before the last `\r` was
	/// overwritten and never seen by a human, so stripping escapes from it
	/// would only preserve text that was already discarded.
	public static func clean(_ line: String) -> String {
		guard !line.isEmpty else { return line }

		// `docker logs --timestamps` prepends an RFC3339 stamp that the history
		// path parses back out to merge stdout and stderr chronologically. It
		// sits BEFORE the container's own output, so it would be destroyed by
		// the carriage-return rule below. Split it off and put it back after.
		var prefix = ""
		var body = Substring(line)
		if let space = line.firstIndex(of: " ") {
			let head = line[line.startIndex..<space]
			if looksLikeTimestamp(head) {
				prefix = String(head) + " "
				body = line[line.index(after: space)...]
			}
		}

		body = resolveCarriageReturns(body)
		let stripped = stripControlSequences(body)
		return prefix + stripped
	}

	/// True for the shape docker emits with `--timestamps`
	/// (`2026-09-06T00:15:05.123456789Z`). Deliberately a shape check, not a
	/// full parse: this runs per line on a stream that can carry thousands a
	/// second, and a false negative only costs a preserved timestamp, never
	/// corruption.
	private static func looksLikeTimestamp(_ s: Substring) -> Bool {
		guard s.count >= 20, s.contains("T") else { return false }
		guard let last = s.last, last == "Z" || s.contains("+") else { return false }
		return s.prefix(4).allSatisfy(\.isNumber)
	}

	/// Applies terminal overwrite semantics: everything before the final `\r`
	/// was drawn over and is not what the user would have seen.
	///
	/// A trailing `\r` is dropped first. It carries no overwrite meaning — it is
	/// the remnant of a CRLF whose LF became the line split — and taking "after
	/// the last CR" without handling it would turn every CRLF line into an empty
	/// one.
	private static func resolveCarriageReturns(_ s: Substring) -> Substring {
		var body = s
		while body.hasSuffix("\r") { body = body.dropLast() }
		guard let lastCR = body.lastIndex(of: "\r") else { return body }
		return body[body.index(after: lastCR)...]
	}

	/// Removes ANSI escape sequences and stray C0 control characters.
	///
	/// Hand-written rather than a regex: this is on the hot path for every log
	/// line, and `NSRegularExpression` would mean bridging each line to NSString
	/// on a stream that can carry thousands a second.
	private static func stripControlSequences(_ s: Substring) -> String {
		var out = ""
		out.reserveCapacity(s.count)
		var i = s.startIndex

		while i < s.endIndex {
			let c = s[i]

			if c == "\u{1B}" {
				i = s.index(after: i)
				guard i < s.endIndex else { break }

				if s[i] == "[" {
					// CSI: parameters, then one final byte in @ through ~.
					// This covers the colour codes Paper emits and the `[K`
					// erase-line that follows the prompt.
					i = s.index(after: i)
					while i < s.endIndex, !isCSIFinalByte(s[i]) { i = s.index(after: i) }
					if i < s.endIndex { i = s.index(after: i) }
				} else if s[i] == "]" {
					// OSC (window title and friends): runs until BEL or ST.
					i = s.index(after: i)
					while i < s.endIndex, s[i] != "\u{07}", s[i] != "\u{1B}" { i = s.index(after: i) }
					if i < s.endIndex { i = s.index(after: i) }
				} else {
					// Two-character escape; drop both.
					i = s.index(after: i)
				}
				continue
			}

			// Tab is real layout and is kept. Every other C0 control and DEL is
			// terminal machinery that means nothing in a log view.
			if c == "\t" || !isControl(c) { out.append(c) }
			i = s.index(after: i)
		}
		return out
	}

	private static func isCSIFinalByte(_ c: Character) -> Bool {
		guard let a = c.asciiValue else { return false }
		return a >= 0x40 && a <= 0x7E
	}

	private static func isControl(_ c: Character) -> Bool {
		guard let a = c.asciiValue else { return false }
		return a < 0x20 || a == 0x7F
	}
}
