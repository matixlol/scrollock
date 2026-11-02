import { api } from "./asc3lib.mjs";
import { writeFileSync } from "node:fs";
const [, certs] = await api("certificates?filter[certificateType]=DISTRIBUTION,IOS_DISTRIBUTION&limit=20");
const cert = certs.data[0];
console.log("cert", cert?.attributes.name, cert?.attributes.expirationDate);
const [s, p] = await api("profiles", { data: { type: "profiles", attributes: { name: "Scrollock ShieldAction probe", profileType: "IOS_APP_STORE" }, relationships: { bundleId: { data: { type: "bundleIds", id: "5W6AK7WP64" } }, certificates: { data: [{ type: "certificates", id: cert.id }] } } } });
console.log(s, p.errors?.[0]?.detail ?? p.data.id);
if (p.data) { writeFileSync("probe.mobileprovision", Buffer.from(p.data.attributes.profileContent, "base64")); await api(`profiles/${p.data.id}`, undefined, "DELETE"); }
