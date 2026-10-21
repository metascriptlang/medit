import { Link } from "../../lsp/session";
import { closeSocket, openSocket, sendSocket, socketBytes, socketClosed } from "./socketWeb";

const POLL_MS: float64 = 16;

export function socketLink(url: string): Link | null {
	if (!openSocket(url)) { return null; }
	return {
		send: sendSocket,
		take: socketBytes,
		ended: socketClosed,
		stop: closeSocket,
		listen: (ready: () => void): void => {
			function poll(): void {
				ready();
				if (!socketClosed()) { const _t = setTimeout(poll, POLL_MS); }
			}
			poll();
		},
	};
}
