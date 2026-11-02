// Creates App Store provisioning profiles for every iOS target with the local
// Apple Distribution certificate, installs them, and writes the export options
// that scripts/deploy-safari.sh uses for local signing. Rerun whenever a bundle
// ID's capabilities change, because Apple invalidates its profiles.
import { createHash, createSign } from "node:crypto";
import { execFileSync } from "node:child_process";
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const TEAM = process.env.APPLE_TEAM_ID || "BQ7842UUHJ";
const BUNDLE_IDS = [
  "ar.com.poronga.Scrollock",
  "ar.com.poronga.Scrollock.Extension",
  "ar.com.poronga.Scrollock.Monitor",
  "ar.com.poronga.Scrollock.ShieldConfiguration",
  "ar.com.poronga.Scrollock.ShieldAction",
];
const credentials = JSON.parse(
  readFileSync(
    process.env.APPLE_API_CREDENTIALS ||
      join(homedir(), ".config/caloric/apple.json"),
  ),
);
const configDir = join(homedir(), ".config/scrollock");
const installDir = join(
  homedir(),
  "Library/Developer/Xcode/UserData/Provisioning Profiles",
);

const base64url = (value) =>
  Buffer.from(JSON.stringify(value)).toString("base64url");
const now = Math.floor(Date.now() / 1000);
const unsigned = `${base64url({ alg: "ES256", kid: credentials.keyID, typ: "JWT" })}.${base64url({ iss: credentials.issuerID, iat: now, exp: now + 1200, aud: "appstoreconnect-v1" })}`;
const token = `${unsigned}.${createSign("SHA256")
  .update(unsigned)
  .sign({ key: readFileSync(credentials.keyPath), dsaEncoding: "ieee-p1363" })
  .toString("base64url")}`;

async function api(path, body) {
  const response = await fetch(
    `https://api.appstoreconnect.apple.com/v1/${path}`,
    {
      method: body ? "POST" : "GET",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: body && JSON.stringify(body),
    },
  );
  const result = await response.json();
  if (!response.ok)
    throw new Error(
      `${path}: ${result.errors?.[0]?.detail || response.statusText}`,
    );
  return result;
}

// Use the distribution certificate whose private key is in the local Keychain.
const identities = execFileSync(
  "security",
  ["find-identity", "-v", "-p", "codesigning"],
  { encoding: "utf8" },
);
const certificates = await api(
  "certificates?filter[certificateType]=DISTRIBUTION,IOS_DISTRIBUTION&limit=200",
);
const certificate = certificates.data.find((item) =>
  identities.includes(
    createHash("sha1")
      .update(Buffer.from(item.attributes.certificateContent, "base64"))
      .digest("hex")
      .toUpperCase(),
  ),
);
if (!certificate)
  throw new Error("No Apple Distribution certificate in the local Keychain");
const sha1 = createHash("sha1")
  .update(Buffer.from(certificate.attributes.certificateContent, "base64"))
  .digest("hex")
  .toUpperCase();

mkdirSync(configDir, { recursive: true });
mkdirSync(installDir, { recursive: true });
const index = {};
const stamp = new Date().toISOString().slice(0, 10);
for (const identifier of BUNDLE_IDS) {
  const bundle = (
    await api(
      `bundleIds?filter[identifier]=${identifier}&filter[platform]=IOS&limit=10`,
    )
  ).data.find((item) => item.attributes.identifier === identifier);
  if (!bundle) throw new Error(`Bundle ID ${identifier} is not registered`);
  const { data: profile } = await api("profiles", {
    data: {
      type: "profiles",
      attributes: {
        name: `${identifier} App Store ${stamp} ${Date.now().toString(36)}`,
        profileType: "IOS_APP_STORE",
      },
      relationships: {
        bundleId: { data: { type: "bundleIds", id: bundle.id } },
        certificates: {
          data: [{ type: "certificates", id: certificate.id }],
        },
      },
    },
  });
  const path = join(configDir, `${profile.id}.mobileprovision`);
  writeFileSync(path, Buffer.from(profile.attributes.profileContent, "base64"));
  copyFileSync(
    path,
    join(installDir, `${profile.attributes.uuid}.mobileprovision`),
  );
  index[identifier] = {
    path,
    profileID: profile.id,
    uuid: profile.attributes.uuid,
    app: `${TEAM}.${identifier}`,
    team: TEAM,
    expires: profile.attributes.expirationDate,
    certificates: [sha1],
    development: false,
    devices: [],
  };
  console.log(`${identifier}: ${profile.attributes.uuid}`);
}
writeFileSync(
  join(configDir, "profiles.json"),
  JSON.stringify(index, null, 2) + "\n",
);
const profiles = Object.entries(index)
  .map(
    ([identifier, { uuid }]) =>
      `\t\t<key>${identifier}</key>\n\t\t<string>${uuid}</string>`,
  )
  .join("\n");
writeFileSync(
  join(configDir, "ExportOptions.plist"),
  `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
\t<key>destination</key>
\t<string>upload</string>
\t<key>manageAppVersionAndBuildNumber</key>
\t<false/>
\t<key>method</key>
\t<string>app-store-connect</string>
\t<key>provisioningProfiles</key>
\t<dict>
${profiles}
\t</dict>
\t<key>signingCertificate</key>
\t<string>${sha1}</string>
\t<key>signingStyle</key>
\t<string>manual</string>
\t<key>teamID</key>
\t<string>${TEAM}</string>
</dict>
</plist>
`,
);
console.log(`Wrote ${join(configDir, "ExportOptions.plist")}`);
