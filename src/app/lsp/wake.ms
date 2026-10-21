@include("./wake.h");
@compile("./wake.c");

import { onWake } from "../../../../ion/src/index";

extern function serverWireWake(): void;

export function onServerOutput(handler: () => void): void {
	serverWireWake();
	onWake(handler);
}
