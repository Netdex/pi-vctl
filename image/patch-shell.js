// The mounted settings.json is shared with pi on Windows, so its shellPath can be a
// Windows path. Make Linux pi ignore such a path and use its normal /bin/bash lookup.
// pi ships this code twice, unbundled and in a minified bundle whose name is hashed, so
// patch every file holding the error message. Fails the build rather than miss a copy.
const { readdirSync, readFileSync, writeFileSync } = require("fs");
const { join } = require("path");

const dist = join(process.argv[2], "dist");
const marker = "Custom shell path not found";
const guard = /if\s*\(customShellPath\)\s*\{/g;
const replacement = "if (customShellPath && !/^[A-Za-z]:[\\\\/]/.test(customShellPath)) {";

let patched = 0;
for (const entry of readdirSync(dist, { recursive: true, withFileTypes: true })) {
	if (!entry.isFile() || !entry.name.endsWith(".js")) continue;
	const file = join(entry.parentPath, entry.name);
	const source = readFileSync(file, "utf8");
	if (!source.includes(marker)) continue;
	const matches = source.match(guard) ?? [];
	if (matches.length !== 1) {
		console.error(`Expected one customShellPath check in ${file}, found ${matches.length}`);
		process.exit(1);
	}
	writeFileSync(file, source.replace(guard, () => replacement));
	console.log(`Patched ${file}`);
	patched++;
}
if (patched === 0) {
	console.error(`No file in ${dist} contains "${marker}"`);
	process.exit(1);
}
