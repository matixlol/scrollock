import test from "node:test";
import assert from "node:assert/strict";
import { execFileSync, spawnSync } from "node:child_process";
import { cp, mkdtemp, readFile, rm } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

test("CI build numbers identify both browser packages without changing the source or Chrome identity", async (t) => {
  const dir = await mkdtemp(join(tmpdir(), "scrollock-build-"));
  t.after(() => rm(dir, { recursive: true, force: true }));
  await cp(new URL("../extension/", import.meta.url), join(dir, "extension"), {
    recursive: true,
  });
  const source = JSON.parse(
    await readFile(join(dir, "extension/manifest.json")),
  );
  const script = fileURLToPath(
    new URL("../scripts/build.mjs", import.meta.url),
  );
  const env = { ...process.env, API_ORIGIN: "https://api.example" };
  delete env.EXTENSION_BUILD_NUMBER;
  for (const number of [undefined, "42", "43", "65535"]) {
    const buildEnv = { ...env };
    if (number !== undefined) buildEnv.EXTENSION_BUILD_NUMBER = number;
    execFileSync(process.execPath, [script], { cwd: dir, env: buildEnv });
    const expectedVersion = number
      ? `${source.version}.${number}`
      : source.version;
    for (const target of ["chrome", "safari"]) {
      const manifest = JSON.parse(
        await readFile(join(dir, `dist/${target}/manifest.json`)),
      );
      assert.equal(manifest.version, expectedVersion);
      assert.deepEqual(manifest.host_permissions, ["https://api.example/*"]);
      if (target === "chrome")
        assert.equal(
          manifest.key,
          (
            await readFile(join(dir, "extension/chrome-key.txt"), "utf8")
          ).trim(),
        );
      else assert.ok(manifest.permissions.includes("nativeMessaging"));
    }
  }
  assert.deepEqual(
    JSON.parse(await readFile(join(dir, "extension/manifest.json"))),
    source,
  );
  for (const number of ["", "0", "-1", "01", "1.2", "65536"]) {
    const result = spawnSync(process.execPath, [script], {
      cwd: dir,
      env: { ...env, EXTENSION_BUILD_NUMBER: number },
      encoding: "utf8",
    });
    assert.notEqual(result.status, 0, `reject invalid build number ${number}`);
    assert.match(result.stderr, /EXTENSION_BUILD_NUMBER/);
  }
});
