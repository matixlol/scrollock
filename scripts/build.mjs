import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises";
const origin = new URL(process.env.API_ORIGIN || "http://localhost:8787");
if (
  origin.protocol !== "https:" &&
  !(
    origin.protocol === "http:" &&
    ["localhost", "127.0.0.1"].includes(origin.hostname)
  )
)
  throw new Error("API_ORIGIN must be HTTPS (or localhost for development)");
for (const target of ["chrome", "safari"]) {
  const dir = `dist/${target}`;
  await mkdir(dir, { recursive: true });
  await cp("extension", dir, { recursive: true });
  const manifest = JSON.parse(await readFile("extension/manifest.json"));
  manifest.host_permissions = [origin.origin + "/*"];
  if (target === "chrome") {
    manifest.key = (await readFile("extension/chrome-key.txt", "utf8")).trim();
  } else {
    manifest.permissions.push("nativeMessaging");
    await rm(dir + "/chrome-key.txt");
  }
  await writeFile(
    dir + "/manifest.json",
    JSON.stringify(manifest, null, 2) + "\n",
  );
  await writeFile(
    dir + "/config.js",
    `globalThis.SCROLLOCK_API = ${JSON.stringify(origin.origin)};\n`,
  );
}
console.log("Built dist/chrome and dist/safari");
