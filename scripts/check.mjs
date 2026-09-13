import { readdir, readFile } from "node:fs/promises";
import { execFileSync } from "node:child_process";
const manifest = JSON.parse(await readFile("extension/manifest.json", "utf8"));
if (
  typeof manifest.description !== "string" ||
  !manifest.description ||
  manifest.description.length > 112
)
  throw new Error("Safari requires a manifest description of 1–112 characters");
for (const dir of ["extension", "scripts", "server", "tests"]) {
  for (const file of await readdir(dir))
    if (/\.(m?js)$/.test(file))
      execFileSync(process.execPath, ["--check", `${dir}/${file}`], {
        stdio: "inherit",
      });
}
console.log("All JavaScript syntax checks passed");
