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

Membership in the Apple Developer Program, then, on a Mac — for the same thing
from Linux, skip to the next section:

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

## Getting the identity without a Mac

Every step above except `security find-identity` is a browser form or an
`openssl` call, so the certificate can be created from Linux. Only the
*signing* needs macOS, and in this project that happens on the CI runner.

1. **Private key and CSR.** The key never leaves this machine; Apple only sees
   the request.

   ```sh
   openssl req -new -newkey rsa:2048 -nodes \
       -keyout devid.key -out devid.csr \
       -subj "/emailAddress=you@example.com/CN=Your Name/C=BR"
   ```

   Apple takes the identity from the account rather than from the subject, so
   these fields only have to be well-formed.

2. **Upload `devid.csr`** at `developer.apple.com/account` → *Certificates,
   Identifiers & Profiles* → **+** → **Developer ID Application**, and download
   the `developerID_application.cer` it returns. That file is DER, and it holds
   only the certificate — the private key is still the one from step 1.

3. **The intermediate.** A `.p12` that carries only the leaf leaves the runner
   unable to build a chain to the Apple root, and `codesign` refuses it.

   ```sh
   curl -O https://www.apple.com/certificateauthority/DeveloperIDG2CA.cer
   ```

4. **Convert both to PEM and assemble the `.p12`.**

   ```sh
   openssl x509 -inform DER -in developerID_application.cer -out cert.pem
   openssl x509 -inform DER -in DeveloperIDG2CA.cer         -out interm.pem

   openssl pkcs12 -export -legacy \
       -inkey devid.key -in cert.pem -certfile interm.pem \
       -name "Developer ID Application" -out cert.p12
   ```

   **`-legacy` is not optional.** OpenSSL 3 defaults to PBES2/PBKDF2 with
   AES-256-CBC, which macOS `security import` cannot read: the CI step fails
   at import, before anything is signed. With `-legacy` the file comes out as
   `pbeWithSHA1And40BitRC2-CBC`, which is what macOS expects. `openssl pkcs12
   -info -nokeys` prints which one you got — and needs `-legacy` itself to read
   a legacy file back, so an error about `RC2-40-CBC : 0` being unsupported
   means the export worked, not that it failed.

5. **Read the identity string.** This is `DEVELOPER_ID`, and
   `MACOS_DEVELOPER_ID` in CI — the common name, parentheses included, without
   the `CN=`.

   ```sh
   openssl x509 -in cert.pem -noout -subject -nameopt multiline | grep commonName
   ```

The notarization key needs no Mac either: the `.p8` downloads from
`appstoreconnect.apple.com` in any browser.

What genuinely cannot be done here is verifying the result — `codesign`,
`spctl` and `stapler` are macOS tools. The first signed build is therefore the
first proof that the certificate is usable, which is a reason to cut a release
candidate for it rather than finding out on the release itself.

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

On a Mac, export the `.p12` from Keychain Access → **My Certificates** — only
that category lists certificates with the private key attached. Built from
Linux by the section above, it is already a file. Either way the secrets hold
base64, on one line:

```sh
base64 -w0 cert.p12                 # Linux
base64 -w0 AuthKey_XXXXXXXX.p8

base64 -i cert.p12 | pbcopy         # macOS
base64 -i AuthKey_XXXXXXXX.p8 | pbcopy
```

Paste them through the repository's *Settings → Secrets* page rather than
`gh secret set` with the value on a command line, where it lands in shell
history.

Keep the `.p12`, its password and the `.p8` in a password manager. A GitHub
secret cannot be read back, so it is not a backup.

## When notarization is interrupted

Apple's queue has taken close to an hour here, and the submission outlives
whatever was waiting on it: a dropped connection, a cancelled job, a closed
laptop. The upload does not have to be repeated — the submission ID printed by
`notarytool submit` is enough to pick the verdict back up, and `stapler` only
needs a DMG that is byte-identical to the one that was submitted.

```sh
xcrun notarytool info <submission-id> --key … --key-id … --issuer …
xcrun notarytool log  <submission-id> --key … --key-id … --issuer …
```

`package.sh` splits the upload from the wait for this reason, and treats a
status it cannot read as "ask again" rather than as a rejection.

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
