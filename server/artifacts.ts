import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const projectRoot = join(dirname(fileURLToPath(import.meta.url)), "..");

export type Artifact = {
  abi: unknown[];
  bytecode: `0x${string}`;
};

/**
 * Load a Foundry build artifact (run `forge build` first).
 * Looks under contracts/out/<Name>.sol/<Name>.json.
 */
export function loadArtifact(name: string): Artifact {
  const path = join(projectRoot, "contracts", "out", `${name}.sol`, `${name}.json`);
  const json = JSON.parse(readFileSync(path, "utf8"));
  const bytecode = typeof json.bytecode === "string" ? json.bytecode : json.bytecode?.object;

  if (!bytecode) {
    throw new Error(`No bytecode in artifact for ${name}; run \`forge build\` first.`);
  }

  return { abi: json.abi as unknown[], bytecode: bytecode as `0x${string}` };
}
