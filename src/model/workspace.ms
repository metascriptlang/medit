export interface PaneHandle {
	focus: () => void;
	head: () => int32;
	jumpTo: (offset: int32) => void;
	tell: (message: string) => void;
}

export interface Workspace {
	quickOpen: () => void;
	openAt: (uri: string, line: int32, character: int32) => string | null;
	closeTab: () => void;
	activateTab: (index: int32) => void;
	stepTab: (forward: boolean) => void;
	switchTabs: (last: boolean) => void;
	keyUp: (ctrl: boolean) => void;
	reopenClosed: () => void;
	navigate: (back: boolean) => void;
	changed: () => void;
	measured: (cellWidth: float64, rowHeight: float64) => void;
}

export function noWorkspace(): Workspace {
	return {
		quickOpen: (): void => {},
		openAt: (uri: string, line: int32, character: int32): string | null => `${uri} is not open`,
		closeTab: (): void => {},
		activateTab: (index: int32): void => {},
		stepTab: (forward: boolean): void => {},
		switchTabs: (last: boolean): void => {},
		keyUp: (ctrl: boolean): void => {},
		reopenClosed: (): void => {},
		navigate: (back: boolean): void => {},
		changed: (): void => {},
		measured: (cellWidth: float64, rowHeight: float64): void => {},
	};
}
