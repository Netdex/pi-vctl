// Stops the interactive TUI from freezing under vctl.
//
// vctl's guest agent copies terminal output through a log writer that splits on newlines
// and fails once it has buffered 64 KB without one. That error silently ends the copy, so
// nothing reads the terminal again and the next writes block forever. The TUI moves the
// cursor with escape codes, so it can go past 64 KB without writing a newline.
//
// This adds a newline often enough, inside an escape sequence that terminals ignore.
// The launcher's agent patch removes the cause. This covers pi until that patch lands,
// or if it cannot be applied.

const INSERT_AFTER = 16 * 1024;
const FORCE_AFTER = 48 * 1024;
const MARK = Buffer.from("\x1b]999;\n\x1b\\", "latin1");
const LF = 0x0a;
const ESC = 0x1b;
const CSI = 0x5b;

// Shared, because stdout and stderr end up on the same terminal.
let sinceNewline = 0;

function isContinuationByte(byte) {
	return (byte & 0xc0) === 0x80;
}

function addMarks(bytes) {
	const pieces = [];
	let start = 0;
	// A write normally ends on a complete sequence, so its start is a safe place.
	if (sinceNewline >= INSERT_AFTER) {
		pieces.push(MARK);
		sinceNewline = 0;
	}
	for (let i = 0; i < bytes.length; i++) {
		sinceNewline = bytes[i] === LF ? 0 : sinceNewline + 1;
		const next = i + 1;
		if (next >= bytes.length) break;
		const beforeSequence = bytes[next] === ESC && bytes[next + 1] === CSI;
		const safe = (sinceNewline >= INSERT_AFTER && beforeSequence) || (sinceNewline >= FORCE_AFTER && !isContinuationByte(bytes[next]));
		if (safe) {
			pieces.push(bytes.subarray(start, next), MARK);
			start = next;
			sinceNewline = 0;
		}
	}
	if (pieces.length === 0) return bytes;
	pieces.push(bytes.subarray(start));
	return Buffer.concat(pieces);
}

function patch(stream) {
	if (!stream.isTTY) return;
	const write = stream.write.bind(stream);
	stream.write = (data, encoding, callback) => {
		if (typeof encoding === "function") {
			callback = encoding;
			encoding = undefined;
		}
		const bytes = typeof data === "string" ? Buffer.from(data, encoding || "utf8") : Buffer.from(data);
		return write(addMarks(bytes), callback);
	};
}

patch(process.stdout);
patch(process.stderr);
