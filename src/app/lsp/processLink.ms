import { Link } from "../../lsp/session";
import { ServerProcess, ended, send, start, stop, take } from "./serverProcess";
import { onServerOutput } from "./wake";

export function processLink(command: string, cwd: string): Link | null {
	const started = ServerProcess.start(command, cwd);
	if (started === null) { return null; }
	const p = started as ServerProcess;
	return {
		send: (bytes: string): boolean => p.send(bytes),
		take: (): string => p.take(),
		ended: (): boolean => p.ended(),
		stop: (): void => { p.stop(); },
		listen: (ready: () => void): void => { onServerOutput(ready); },
	};
}
