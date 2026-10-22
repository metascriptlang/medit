import { Project, Target, plistBoolean } from "../ion/tooling/generator/description";

const FONT_ASSETS: Vec<string> = ["assets/JetBrainsMonoNL-Regular.ttf", "assets/JetBrainsMono-OFL.txt"];

export const project: Project = {
	name: "Medic",
	targets: [{
		...Target.iosApp("Medic", "src/app/medicIos.ms"),
		bundleId: "studio.metacraft.Medic",
		assets: FONT_ASSETS,
		developmentTeam: "4R7EAZY462",
		infoPlist: [plistBoolean("UIFileSharingEnabled", true), plistBoolean("LSSupportsOpeningDocumentsInPlace", true)],
	}, {
		...Target.androidApp("MedicAndroid", "src/app/medicAndroid.ms"),
		bundleId: "studio.metacraft.Medic",
		assets: FONT_ASSETS,
	}],
	plugins: [],
};
