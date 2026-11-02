import { readFileSync } from "node:fs";
import { createSign } from "node:crypto";
const c = JSON.parse(readFileSync(process.env.HOME + "/.config/caloric/apple.json"));
const b = (o) => Buffer.from(JSON.stringify(o)).toString("base64url");
const now = Math.floor(Date.now() / 1000);
const data = b({ alg: "ES256", kid: c.keyID, typ: "JWT" }) + "." + b({ iss: c.issuerID, iat: now, exp: now + 600, aud: "appstoreconnect-v1" });
const token = data + "." + createSign("SHA256").update(data).sign({ key: readFileSync(c.keyPath), dsaEncoding: "ieee-p1363" }).toString("base64url");
export const api = (path, body, method) => fetch("https://api.appstoreconnect.apple.com/v1/" + path, { method: method || (body ? "POST" : "GET"), headers: { Authorization: `Bearer ${token}`, "Content-Type": "application/json" }, body: body && JSON.stringify(body) }).then(async (r) => [r.status, r.status === 204 ? {} : await r.json()]);
const [, ids] = await api("bundleIds?filter[identifier]=ar.com.poronga.Scrollock&limit=50");
for (const d of ids.data) {
  const [, caps] = await api(`bundleIds/${d.id}/bundleIdCapabilities`);
  const [, profiles] = await api(`bundleIds/${d.id}/profiles?fields[profiles]=name,profileType,profileState`);
  console.log(d.attributes.identifier, d.id, caps.data.map((x) => x.attributes.capabilityType).join(","), "|", profiles.data.map((p) => `${p.attributes.profileType}:${p.attributes.profileState}`).join(","));
}
