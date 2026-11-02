import { api } from "./asc3lib.mjs";
const [, apps] = await api("apps?filter[bundleId]=ar.com.poronga.Scrollock");
const [, builds] = await api(`builds?filter[app]=${apps.data[0].id}&sort=-uploadedDate&limit=1&fields[builds]=version,processingState,uploadedDate`);
for (const b of builds.data) console.log(b.attributes.version, b.attributes.processingState, b.attributes.uploadedDate);
