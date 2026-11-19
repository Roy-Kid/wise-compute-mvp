import { join } from "node:path";
import { parseArgs } from "node:util";
import { loadStack, renderRecipe, stackRoot } from "./stack.ts";

const { values, positionals } = parseArgs({
  allowPositionals: true,
  options: {
    out: { type: "string", default: join(stackRoot, "build", "recipes") },
    "feature-registry": { type: "string" },
  },
});
const stack = loadStack();
const variants = positionals.length ? positionals : Object.keys(stack.variants);
for (const variant of variants) {
  console.log(renderRecipe(stack, { variant, outDir: values.out, featureRegistry: values["feature-registry"] }));
}
