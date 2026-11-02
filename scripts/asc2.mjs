import { readFileSync } from "node:fs";
import { createSign } from "node:crypto";
const c = JSON.parse(readFileSync(process.env.HOME + "/.config/caloric/apple.json"));
const b = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const now = Math.floor(Date.now() / 1000);
const data = b({ alg: "ES256", kid: c.keyID, typ: "JWT" }) + "." + b({ iss: c.issuerID, iat: now, exp: now + 600, aud: "appstoreconnect-v1" });
const token = data + "." + createSign("SHA256").update(data).sign({ key: readFileSync(c.keyPath), dsaEncoding: "ieee-p1363" }).toString("base64url");
const api = (path, body) => fetch("https://api.appstoreconnect.apple.com/v1/" + path, { method: body ? "POST" : "GET", headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: body && JSON.stringify(body) }).then(async (r) => [r.status, await r.json()]);
for (const [suffix, name] of [["ShieldConfiguration", "Scrollock Block Screen"], ["ShieldAction", "Scrollock Block Screen Actions"]]) {
  const [s, j] = await api("bundleIds", { data: { type: "bundleIds", attributes: { identifier: `ar.com.poronga.Scrollock.${suffix}`, name, platform: "IOS" } } });
  console.log(suffix, s, JSON.stringify(j.errors ?? j.data.id));
}
