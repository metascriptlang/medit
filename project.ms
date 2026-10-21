import { Project, Target, plistBoolean } from "../ion/tooling/generator/description";
import { bundlePrefix } from "../ion/tooling/generator/plugins";

export const project: Project = {
	name: "Medic",
	targets: [{
		...Target.iosApp("Medic", "src/app/medicIos.ms"),
		assets: ["assets/JetBrainsMonoNL-Regular.ttf", "assets/JetBrainsMono-OFL.txt"],
		developmentTeam: "4R7EAZY462",
		infoPlist: [plistBoolean("UIFileSharingEnabled", true), plistBoolean("LSSupportsOpeningDocumentsInPlace", true)],
	}],
	plugins: [bundlePrefix("studio.metacraft")],
};
