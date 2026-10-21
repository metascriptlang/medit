import { Project, Target } from "../../../../ion/tooling/generator/description";
import { bundlePrefix } from "../../../../ion/tooling/generator/plugins";

export const project: Project = {
	name: "Medic",
	targets: [Target.iosApp("Medic", "../medicIos.ms")],
	plugins: [bundlePrefix("studio.metacraft")],
};
