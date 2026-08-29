# Signing and notarizing the macOS build

`package.sh` signs the bundle ad-hoc when `DEVELOPER_ID` is unset, which is
what the release pipeline does today. Set the variables below and the same
script produces a Developer ID signature, submits the DMG for notarization and
staples the ticket. Both halves are needed: a signed but un-notarized DMG is
refused the same way an unsigned one is.

## What the script reads

| Variable | Effect |
|---|---|
| `DEVELOPER_ID` | signs with this identity — hardened runtime, secure timestamp, `entitlements.plist` on the bundle. Unset: ad-hoc. |
| `NOTARY_PROFILE` | notarizes with a profile stored by `xcrun notarytool store-credentials` |
| `NOTARY_KEY`, `NOTARY_KEY_ID`, `NOTARY_ISSUER` | notarizes with an App Store Connect API key; `NOTARY_KEY` is the path to the `.p8` |

With `DEVELOPER_ID` and no notary credentials the script signs and warns that
the result is still not distributable.

`notarytool` and `stapler` come with Xcode or the Command Line Tools
(`xcode-select --install`).

## Getting the identity

Membership in the Apple Developer Program, then:

1. **Keychain Access → Certificate Assistant → Request a Certificate From a
   Certificate Authority**, saved to disk. The private key stays on the Mac;
   Apple only sees the request.
2. `developer.apple.com/account` → **Certificates, Identifiers & Profiles** →
   **+** → **Developer ID Application**. Not *Mac Development*, not *Mac App
   Distribution* — those are for other kinds of distribution. Only the Account
   Holder can create one.
3. Download the `.cer`, double-click to install, then:

   ```sh
   security find-identity -v -p codesigning
   ```

   The whole string it prints — `Developer ID Application: Name (TEAMID)`,
   parentheses included — is `DEVELOPER_ID`.

Registering the bundle identifier under *Identifiers* is not required:
Developer ID distribution uses neither capabilities nor provisioning profiles.

The notarization key comes from `appstoreconnect.apple.com` → *Users and
Access* → *Integrations* → *App Store Connect API*. **The `.p8` downloads
exactly once**; a lost key has to be revoked and replaced.

## Building a signed DMG

```sh
cmake --build build
export DEVELOPER_ID="Developer ID Application: Name (TEAMID)"
export NOTARY_PROFILE=qub
bash packaging/macos/package.sh
```

## In CI

`release.yml` reads six repository secrets and skips its signing steps when
they are absent.

| Secret | Holds |
|---|---|
| `MACOS_CERT_P12` | the exported `.p12` (certificate + private key), base64 |
| `MACOS_CERT_PASSWORD` | the password set during that export |
| `MACOS_DEVELOPER_ID` | `Developer ID Application: Name (TEAMID)` |
| `MACOS_NOTARY_KEY` | the App Store Connect `.p8`, base64 |
| `MACOS_NOTARY_KEY_ID` | the key's ID |
| `MACOS_NOTARY_ISSUER` | the issuer ID |

Export the `.p12` from Keychain Access → **My Certificates** — only that
category lists certificates with the private key attached. Then:

```sh
base64 -i cert.p12 | pbcopy
base64 -i AuthKey_XXXXXXXX.p8 | pbcopy
```

Keep the `.p12`, its password and the `.p8` in a password manager. A GitHub
secret cannot be read back, so it is not a backup.

## Checking the result

```sh
codesign -dv --verbose=4 build/qub.app
codesign --verify --deep --strict build/qub.app
spctl -a -vvv -t install build/qub.app
xcrun stapler validate dist/qub-*.dmg
```

`spctl` should report *accepted* and *source=Notarized Developer ID*. The
machine that signed a build always trusts it, so anything less means the DMG
will be refused elsewhere — check on a Mac that has not seen the source.

## entitlements.plist

Deliberately almost empty. The hardened runtime denies everything not asked
for, and the only exception qub needs is `com.apple.security.cs.allow-jit`,
for the QML engine's `MAP_JIT` allocation. If a signed build dies shortly
after launch, that file is the first place to look.
