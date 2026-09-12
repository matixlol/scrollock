# Native Screen Time integration

`npm run safari:package` generates the Xcode wrapper, then
`scripts/configure-native.py` installs these tracked sources and adds the
`Scrollock Monitor` extension. Do not edit the generated `safari/` tree.
All three targets require iOS 17 or newer.

The containing app requests individual Family Controls authorization and stores
per-site opaque application tokens in `group.ar.com.poronga.Scrollock`. Saving a
selection immediately shields it. A token can belong to only one site, preventing
another site's shield from silently defeating an unlock. Categories and web
domains are not shielded. Tokens never leave the device.

Safari calls `browser.runtime.sendNativeMessage('ar.com.poronga.Scrollock', body)`:

- `{type:'status'}` returns `{ok:true, authorized, selections:{x,instagram,youtube}}`
  with selected-app counts and reconciles expired leases.
- `{type:'unlock', site, expiresAt}` uses Unix milliseconds and returns
  `{ok:true, selectedApps}` after scheduling relock and removing that site's shield.
- `{type:'lock', site}` reapplies that site's shield and returns `{ok:true}`.
- Errors return `{ok:false, error}`. A website grant is independent; the caller must
  not claim native apps were unblocked when this bridge fails.

No account/session token, reason, browsing URL, category history, or usage event is
stored or transmitted by the native code. The Device Activity extension uses only
calendar callbacks, not usage thresholds or reports. It stores deadlines in the
App Group, so relocking does not depend on the containing app remaining alive.
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
network delay. Simulator builds and light/dark rendering were verified. On the
iOS 26.3 simulator, requesting authorization returns “Couldn’t communicate with a
helper application.” Real app selection, shields, suspended/rebooted-device
relocking and Safari-to-native messaging with selected tokens need a physical
device. Do not describe simulator compilation as Screen Time end-to-end proof.

## Distribution requirements

The Account Holder must obtain Apple's [Family Controls distribution approval](https://developer.apple.com/documentation/familycontrols/requesting-the-family-controls-entitlement)
for `ar.com.poronga.Scrollock`, `ar.com.poronga.Scrollock.Extension`, and
`ar.com.poronga.Scrollock.Monitor`. All three use Family Controls APIs and share
the App Group. Register the group and enable it on the identifiers, then refresh
provisioning profiles. The locally cached app and Safari-extension profiles
inspected during implementation contained neither Family Controls nor App Groups;
that is not proof of the current developer-portal approval state.

TestFlight distribution cannot be claimed until an entitled archive has actually
uploaded and Apple has processed it. Do not strip the entitlement to make an
upload pass: that would ship a nonfunctional Screen Time feature.
