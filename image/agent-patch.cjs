// Turns off the terminal log in this container's guest agent, so that output without
// newlines cannot freeze the terminal. See README, Known quirks.
//
// agent-patch.sh runs this in the container's root filesystem, with descriptors it
// opened in the VM: fd 3 is /proc/<agent>/mem and fd 4 is the agent's executable.
//   verify  checks that the agent is the exact build this patch was written for
//   patch   makes pkg/logfile.(*DatedLog).Write return success without logging
// Prints one result: verified, patched, already-patched, or error <detail>.
const fs = require("fs");
const crypto = require("crypto");

// spherelet-spagent from Workstation 17.5.2's vkd\spherelet-initrd.
const AGENT_SHA256 = "aab8217fc3262357e5af579bfed3ce3cd7163080b0de8116f0017189b63bd802";
const ADDRESS = 0x138bc30;
// The function's original stack-check prologue.
const ORIGINAL = Buffer.from("64488b0c25a8ffffff488d842458ffffff483b41100f86", "hex");
// mov rax,[rsp+18h]; mov [rsp+28h],rax; xor eax,eax; mov [rsp+30h],rax; mov [rsp+38h],rax; ret
// That is: return n = len(p), err = nil.
const PATCH = Buffer.from("488b442418" + "4889442428" + "31c0" + "4889442430" + "4889442438" + "c3", "hex");

function verify() {
	const hash = crypto.createHash("sha256");
	const chunk = Buffer.alloc(1 << 20);
	let n;
	while ((n = fs.readSync(4, chunk, 0, chunk.length, null)) > 0) hash.update(chunk.subarray(0, n));
	const digest = hash.digest("hex");
	return digest === AGENT_SHA256 ? "verified" : `error unknown-agent-build ${digest}`;
}

function patch() {
	const current = Buffer.alloc(PATCH.length);
	fs.readSync(3, current, 0, current.length, ADDRESS);
	if (current.equals(PATCH)) return "already-patched";
	if (!current.equals(ORIGINAL)) return `error bytes-differ ${current.toString("hex")}`;
	fs.writeSync(3, PATCH, 0, PATCH.length, ADDRESS);
	fs.readSync(3, current, 0, current.length, ADDRESS);
	return current.equals(PATCH) ? "patched" : `error readback ${current.toString("hex")}`;
}

try {
	const mode = process.argv[2];
	if (mode === "verify") console.log(verify());
	else if (mode === "patch") console.log(patch());
	else throw new Error(`unknown mode ${mode}`);
} catch (e) {
	console.log(`error ${String(e.message).replace(/\s+/g, " ")}`);
}
