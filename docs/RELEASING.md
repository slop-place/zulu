# Releasing Zulu

Releases are cut by release-please. Every push to `main` updates one release PR per
component, built from conventional commits:

| Component | Paths | Tag | Merging its release PR runs |
| --- | --- | --- | --- |
| `zulu` | everything but `service/` | `zulu-v1.2.3` | `release.yml`: tests ZuluKit, uploads to TestFlight, attaches a notarized Mac DMG, publishes the Sparkle appcast |
| `notifyd` | `service/` | `notifyd-v0.1.0` | `notifyd-release.yml`: pushes `ghcr.io/bwees/zulu-notifyd:v0.1.0` |

`release.yml` can also be run by hand from the Actions tab. Nothing below happens
automatically — this is the one-time setup a human has to do first, in this order.

Team: **Brandon Wees, `65AMD2STXG`** (not FUTO Holdings). Bundle id: `com.bwees.zulu`.

## 1. Register the App ID

<https://developer.apple.com/account/resources/identifiers>

- Identifiers → **+** → App IDs → App.
- Description: `Zulu`. Bundle ID: **Explicit**, `com.bwees.zulu`.
- Enable **iCloud** (key-value storage). The Mac and iOS apps share groups and
  channel settings through it, and the Developer ID profile for the Mac DMG must
  carry it.

`xcodebuild -allowProvisioningUpdates` creates the provisioning profile itself on
every run, so there is no profile to make or store by hand. The App ID is the one
thing it cannot invent for you correctly, because the bundle id has to be explicit
rather than wildcard for App Store submission.

## 2. Create the app record in App Store Connect

<https://appstoreconnect.apple.com/apps>

- **+** → New App. Platform iOS, bundle ID `com.bwees.zulu`, SKU `zulu-ios`.
- Primary language, name, user access: your call.

Uploads are rejected until this record exists. You do not need to fill in any store
metadata to use TestFlight internal testing.

## 3. Export the signing certificates

The workflow needs **three** identities in one `.p12`. `xcodebuild archive` with
automatic signing signs the archive for development, and `-exportArchive` re-signs
it for distribution: Apple Distribution for TestFlight, Developer ID Application for
the Mac DMG. A runner holding only the distribution certificates fails at the
archive step.

In **Keychain Access**, login keychain, My Certificates:

- Select `Apple Development: Brandon Wees`, `Apple Distribution: Brandon Wees` and
  `Developer ID Application: Brandon Wees (65AMD2STXG)` (cmd-click) — the rows with
  a disclosure triangle hiding a private key. A row without one is useless here.
- Right click → Export 3 items… → Personal Information Exchange (.p12).
- Set a password. You need it again in step 6.

Then base64 it for the secret:

```sh
base64 -i Certificates.p12 | pbcopy
```

If you ever need to make a distribution certificate from scratch:
<https://developer.apple.com/account/resources/certificates> → **+** → Apple
Distribution (or Developer ID Application), upload a CSR from Keychain Access →
Certificate Assistant → Request a Certificate From a Certificate Authority, then
double-click the download to install it. Only the Account Holder can create a
Developer ID certificate.

## 4. Create the App Store Connect API key

<https://appstoreconnect.apple.com/access/integrations/api> → Team Keys.

- **+**, name it `GitHub Actions`, access **App Manager**. Developer is not enough:
  the key creates provisioning profiles, uploads builds and notarizes the Mac DMG.
- Download the `.p8`. **Apple lets you download it once.** Store it in a password
  manager.
- The page shows the three values you need:
  - **Key ID** — the column next to the key name, e.g. `ABC123DEF4`.
  - **Issuer ID** — a UUID above the key table, shared by every key in the team.
  - The `.p8` file itself.

Base64 the key:

```sh
base64 -i AuthKey_ABC123DEF4.p8 | pbcopy
```

## 5. Make the Developer ID profile

The API key cannot create a Developer ID profile, so Xcode makes it once with your
Apple ID. Archive `ZuluMac` locally, then export it:

```sh
xcodebuild -exportArchive -archivePath ZuluMac.xcarchive -exportPath out \
  -exportOptionsPlist App/ExportOptionsMac.plist -allowProvisioningUpdates
```

That writes `Mac Team Direct Provisioning Profile: com.bwees.zulu` into
`~/Library/Developer/Xcode/UserData/Provisioning Profiles`. It is valid until the
Developer ID certificate expires. Find it and base64 it:

```sh
cd ~/Library/Developer/Xcode/UserData/Provisioning\ Profiles
grep -l "Mac Team Direct Provisioning Profile: com.bwees.zulu" *.provisionprofile
base64 -i <that file> | pbcopy
```

## 6. Export the Sparkle key

The Mac app updates itself with [Sparkle](https://sparkle-project.org). Each appcast is
signed with an EdDSA key whose public half is `SUPublicEDKey` in `App/project.yml`. The
private half lives in the login keychain of whoever ran `generate_keys`, under the
account `com.bwees.zulu`. Export it with the tools from the Sparkle release that matches
`SPARKLE_VERSION` in `release.yml`:

```sh
./bin/generate_keys --account com.bwees.zulu -x sparkle-private-key
pbcopy < sparkle-private-key && rm sparkle-private-key
```

Losing this key strands every installed copy: they reject any appcast signed with a
new one. Keep a copy in a password manager.

## 7. Set the GitHub secrets

Repo → Settings → Secrets and variables → Actions → New repository secret. All seven
are required, spelled exactly as below.

| Secret | Value |
| --- | --- |
| `APPLE_SIGNING_CERTIFICATES_P12` | base64 of the three-identity `.p12` from step 3 |
| `APPLE_SIGNING_CERTIFICATES_PASSWORD` | the password you set when exporting that `.p12` |
| `APPLE_MAC_DEVELOPER_ID_PROFILE` | base64 of the profile from step 5 |
| `APP_STORE_CONNECT_KEY_ID` | Key ID from step 4, plain text, e.g. `ABC123DEF4` |
| `APP_STORE_CONNECT_ISSUER_ID` | Issuer ID from step 4, plain text UUID |
| `APP_STORE_CONNECT_PRIVATE_KEY` | base64 of the `.p8` from step 4 |
| `SPARKLE_PRIVATE_KEY` | the exported key from step 6, as is |

The team ID is not a secret and lives in `env.APPLE_TEAM_ID` in the workflow and in
`App/ExportOptions.plist`.

## 8. Enable GitHub Pages

Repo → Settings → Pages → Source: **GitHub Actions**. `release.yml` deploys
`appcast.xml` there, and the Mac app reads it from
`https://slop-place.github.io/zulu/appcast.xml`. The appcast holds the latest release
only, with its GitHub release notes and a link to the DMG on the release.

## 9. Add yourself as an internal tester

App Store Connect → Zulu → TestFlight → Internal Testing → create a group, add your
Apple ID. Internal testing needs no Beta App Review, so a build is installable within
minutes of the upload finishing processing.

## Versioning

| | Where | Who changes it |
| --- | --- | --- |
| `CFBundleShortVersionString` | `MARKETING_VERSION` in `App/project.yml` | release-please, in the release PR |
| `CFBundleVersion` | `git rev-list --count HEAD` | the workflow, per run |

Marketing version follows the commits: `fix:` bumps the patch, `feat:` the minor, and
`!` or `BREAKING CHANGE:` the major. release-please finds the line by its
`x-release-please-version` comment, so keep that comment on it.

Build number has one hard requirement: App Store Connect rejects a build whose
`CFBundleVersion` it has already seen for the same marketing version. Commit count
satisfies that without storing any state, without a commit back to `main`, and
without asking App Store Connect what the last number was. It is also reversible —
given build `41` you can find the exact commit with `git rev-list --count HEAD`
against candidates, or just check out `main~n`. The alternatives are worse:
`github.run_number` is opaque and unreproducible from a checkout, and a
tag-derived number means no build until someone tags.

The one way commit count stops being monotonic is a force-push to `main` that drops
commits. Don't do that; if it happens, bump `MARKETING_VERSION` and the collision
goes away.

`App/ExportOptions.plist` sets `manageAppVersionAndBuildNumber: false` so that
`-exportArchive` leaves the number alone instead of substituting its own.

## Export compliance

`App/project.yml` declares `ITSAppUsesNonExemptEncryption: false` in the app's
`Info.plist`. Zulu only uses HTTPS to reach a Zulip server, which is an exempt use of
encryption. Without the key, every upload lands in TestFlight as **Missing
Compliance** and cannot be distributed to testers until somebody answers the
questionnaire in the web UI by hand — which defeats the point of an automatic
pipeline. If Zulu ever adds its own cryptography, this declaration has to be revisited
and may require a CCATS/exemption filing.

## Why no fastlane

Everything here is two `xcodebuild` invocations and one `xcrun altool` invocation.
fastlane would add a Ruby toolchain, a `Gemfile.lock` to keep current, and a plugin
surface, in exchange for wrapping commands we are already calling directly. `match`
is the part worth wanting, but it needs a second private repository to hold the
certificates, which is more moving parts than one `.p12` in a GitHub secret. Revisit
if a second app or a second signing platform shows up.

`notarytool` only applies to the Mac DMG, which ships outside the App Store. iOS
builds are signed and uploaded, never notarized.

## Mac DMG signing

The DMG app is signed with Developer ID by the same team and with the same
entitlements as a local build, so the two share state. Each store is keyed by the
signature:

| Store | Keyed by |
| --- | --- |
| API key (`SecretStore`) | keychain access group, from `application-identifier` (`65AMD2STXG.com.bwees.zulu`) |
| Account, settings (`UserDefaults`) | sandbox container, from the bundle id and team |
| Database (`zulu.sqlite`) | sandbox container, under Application Support |
| Groups, channel settings | iCloud key-value store, from `ubiquity-kvstore-identifier` |

Ad-hoc signing breaks all four. With no entitlements the app is not sandboxed, so
defaults and the database land in `~/Library` instead of the container, the API key
falls back to a file there, and iCloud is off.

Releases up to 1.20.0 were ad-hoc signed. Their data is in
`~/Library/Preferences/com.bwees.zulu.plist` and `~/Library/Application Support/Zulu`.
A signed build does not read it, so those users sign in once more. Both paths can be
deleted afterwards.

Do not add `CODE_SIGN_IDENTITY` to the archive commands. Automatic signing refuses a
manually chosen identity and fails the archive with "conflicting provisioning settings".

## When something goes wrong

- **Archive fails on provisioning.** The App ID (step 1) is missing, or the API key
  has Developer access instead of App Manager.
- **Upload rejected as a duplicate build.** Two runs produced the same commit count;
  bump `MARKETING_VERSION`.
- **Build stuck on Processing for hours.** Normal for the first upload of a new app.
  Past that, check the email Apple sends — it names the actual rejection.
- **codesign hangs.** The keychain partition list did not get set; the run will time
  out rather than prompt.
- **Mac export fails with no Developer ID identity.** The `.p12` from step 3 lacks
  the Developer ID Application certificate.
- **The Mac app never offers an update.** Debug builds do not check. Otherwise open
  the appcast URL: Sparkle compares `sparkle:version` (the build number) to the
  installed `CFBundleVersion`, and drops an item whose signature does not match
  `SUPublicEDKey`.
- **Notarization returns Invalid.** Run `xcrun notarytool log <submission id>` with
  the same key; it lists each rejected binary.
