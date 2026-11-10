// Runs inside the container. Reports which TCP targets are reachable.
const net = require("net");
const targets = JSON.parse(require("fs").readFileSync("/workspace/targets.json", "utf8"));

const probe = ({ label, host, port }) =>
	new Promise((resolve) => {
		const socket = net.connect({ host, port, timeout: 3000 });
		const done = (result) => {
			socket.destroy();
			console.log(`${result.padEnd(14)} ${label} (${host}:${port})`);
			resolve();
		};
		socket.on("connect", () => done("REACHABLE"));
		socket.on("timeout", () => done("timeout"));
		socket.on("error", (error) => done(error.code ?? "error"));
	});

(async () => {
	for (const target of targets) await probe(target);
})();
