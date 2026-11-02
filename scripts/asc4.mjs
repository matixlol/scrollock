import { api } from "./asc3lib.mjs";
for (const id of ["5W6AK7WP64", "69XBC9FP4R"])
  for (const cap of ["FAMILY_CONTROLS", "FAMILY_CONTROLS_DISTRIBUTION", "APP_GROUPS"]) {
    const [s, j] = await api("bundleIdCapabilities", { data: { type: "bundleIdCapabilities", attributes: { capabilityType: cap }, relationships: { bundleId: { data: { type: "bundleIds", id } } } } });
    console.log(id, cap, s, s >= 300 ? JSON.stringify(j.errors?.[0]?.detail) : "");
  }
