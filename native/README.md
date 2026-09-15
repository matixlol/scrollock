# Native Screen Time integration

`npm run safari:package` generates the Xcode wrapper, then
`scripts/configure-native.py` installs these tracked sources and adds the
Device Activity monitor plus shield configuration and shield action extensions.
Do not edit the generated `safari/` tree. All five targets require iOS 17 or newer.

The containing app requests individual Family Controls authorization and stores
per-site opaque application tokens in `group.ar.com.poronga.Scrollock`. Saving a
selection immediately shields it. A token can belong to only one site, preventing
another site's shield from silently defeating an unlock. Categories and web
domains are not shielded. Tokens never leave the device.

After Telegram is connected in Safari, the Safari extension passes its API origin
and opaque, seven-day session token into the shared App Group. The containing app
uses that session to offer the same duration-and-reason unblock flow without making
the user return to Safari. The custom iOS shield has **Unblock for 5 minutes** and
**Not now** actions. The primary action reports the fixed reason “Opened from the
iOS block screen.”, schedules relocking, and only then removes Scrollock's shield.
If reporting or scheduling fails, the app remains blocked and the shield redraws
with the error. No Telegram bot credential is present on the device.
See the [iOS block-screen preview](../docs/ios-block-screen-preview.svg); iOS owns
the final layout and applies the device's current appearance.

Safari calls `browser.runtime.sendNativeMessage('ar.com.poronga.Scrollock', body)`:

- Native messages also carry the configured API origin and current browser session
  token so native unblock controls remain authenticated.
- `{type:'status'}` returns `{ok:true, authorized, selections:{x,instagram,youtube}}`
  with selected-app counts and reconciles expired leases.
- `{type:'unlock', site, expiresAt}` uses Unix milliseconds and returns
  `{ok:true, selectedApps}` after scheduling relock and removing that site's shield.
- `{type:'lock', site}` reapplies that site's shield and returns `{ok:true}`.
- Errors return `{ok:false, error}`. A website grant is independent; the caller must
  not claim native apps were unblocked when this bridge fails.

The native code stores the opaque expiring user session in the App Group shared only
by Scrollock's app and extensions. It transmits a selected site, duration, and reason
to Scrollock's API only when the user requests an unblock. App tokens, browsing URLs,
category history, and usage events are never transmitted. The Device Activity
extension uses only calendar callbacks, not usage thresholds or reports. It stores
deadlines in the App Group, so relocking does not depend on the containing app remaining alive.
Intervals shorter than 16 minutes use a 16-minute interval and an end-warning
callback at the requested deadline; its interval end is a fallback. iOS controls
callback delivery and can delay relocking. Opening Scrollock or requesting native
status reconciles expired deadlines. Other apps' and parental Screen Time limits
cannot be removed.

## Verification

```sh
xcrun swiftc native/UnlockSchedule.swift native/tests/UnlockScheduleTests.swift -o /tmp/scrollock-native-tests
/tmp/scrollock-native-tests
rm /tmp/scrollock-native-tests
xcodebuild -project safari/Scrollock/Scrollock.xcodeproj -scheme Scrollock \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

The schedule test covers 1, 15, 16 and 60 minutes, subsecond calendar rounding and
network delay. Simulator builds and light/dark rendering were verified. A signed
Debug build on the iOS 26.5 simulator can complete Family Controls authorization
without a passcode by enabling **Features → Face ID → Enrolled**, choosing
**Allow with Face ID**, and sending **Features → Face ID → Matching Face**.

The simulator currently exposes category rows but no individual app tokens in the
Family Activity picker. It also accepts and persists Managed Settings shields while
SpringBoard does not enforce them or invoke the shield extensions. Debug simulator
builds therefore include **Simulator QA → Preview block screen**. That full-screen
host renders the production shield design and exercises the same authenticated
native unlock client, reporting API, lease, and relock schedule. It is compiled out
of Release and every device build. Real token selection, OS-owned shield rendering,
suspended/rebooted-device relocking, and extension dispatch still require a physical
device; do not describe the Simulator preview as OS shield-extension proof.

## Distribution requirements

The Account Holder must obtain Apple's [Family Controls distribution approval](https://developer.apple.com/documentation/familycontrols/requesting-the-family-controls-entitlement)
for `ar.com.poronga.Scrollock`, `ar.com.poronga.Scrollock.Extension`,
`ar.com.poronga.Scrollock.Monitor`, `ar.com.poronga.Scrollock.ShieldConfiguration`,
and `ar.com.poronga.Scrollock.ShieldAction`. All five use Family Controls APIs and share
the App Group. Register the group and enable it on the identifiers, then refresh
provisioning profiles. The locally cached app and Safari-extension profiles
inspected during implementation contained neither Family Controls nor App Groups;
that is not proof of the current developer-portal approval state.

TestFlight distribution cannot be claimed until an entitled archive has actually
uploaded and Apple has processed it. Do not strip the entitlement to make an
upload pass: that would ship a nonfunctional Screen Time feature.
