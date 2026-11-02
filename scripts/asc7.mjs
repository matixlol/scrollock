import { api } from "./asc3lib.mjs";
const [, apps] = await api("apps?filter[bundleId]=ar.com.poronga.Scrollock");
const id = apps.data[0].id;
const [, b] = await api(`builds?filter[app]=${id}&filter[version]=20261102004609&fields[builds]=version,processingState`);
console.log("builds:", JSON.stringify(b.data?.map(x=>x.attributes) ?? b.errors));
const [s, u] = await api(`apps/${id}/buildUploads?limit=3`);
console.log("uploads:", s, JSON.stringify(u.data?.map(x=>({v:x.attributes.cfBundleVersion,state:x.attributes.state})) ?? u.errors?.[0]?.detail));
