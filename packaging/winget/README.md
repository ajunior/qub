# WinGet

`winget install Ajunior.Qub` installs the same Inno Setup installer the release
page serves. Nothing is rebuilt for WinGet; the manifest points at the release
asset and pins its SHA-256.

## The three files here

They are the manifests of the *first* submission (0.44.10), kept as a record of
what the package looks like and as the template for anything a later version
needs to change. WinGet's own copy lives in `microsoft/winget-pkgs` under
`manifests/a/Ajunior/Qub/<version>/`, and after the first submission it is
`.github/workflows/winget.yml` that keeps it current — these files are not read
by anything at build time.

Every field traces back to `packaging/windows/installer.iss`:

| Manifest field | Comes from |
| --- | --- |
| `InstallerType: inno` | the installer is built by Inno Setup 6 |
| `Scope: user` | `PrivilegesRequired=lowest` |
| `Architecture: x64` | `ArchitecturesAllowed=x64compatible` |
| `ProductCode: '{…}_is1'` | `AppId` plus the `_is1` suffix Inno appends in the uninstall registry |
| `Publisher: ajunior` | `AppPublisher` |

`ProductCode` is what lets WinGet recognise an existing manual installation and
upgrade it in place rather than installing a second copy.

## First submission (done once, by hand)

`winget-releaser` refuses to run for a package that does not yet exist — a new
package gets a human review, and only updates are automated. So version 0.44.10
was submitted manually:

1. Fork `microsoft/winget-pkgs`.
2. Copy these three files to
   `manifests/a/Ajunior/Qub/0.44.10/` in the fork.
3. Open a PR. The bot validates the manifests, installs the package in a
   sandbox VM and reports back; a moderator merges.

## Every release after that (automatic)

`.github/workflows/winget.yml` runs when a release is **published**, not when
the tag is pushed — `release.yml` creates a draft, and the assets a manifest
hashes are not downloadable until someone publishes it. A release left in draft
never reaches WinGet.

It needs one repository secret:

- `WINGET_TOKEN` — a **classic** PAT with the `public_repo` scope. A
  fine-grained token cannot push to the winget-pkgs fork the way `komac`
  needs. The account must have a fork of `microsoft/winget-pkgs`.

## Checking a manifest before submitting

The schemas are public, so a manifest can be validated without Windows:

```sh
curl -sO https://aka.ms/winget-manifest.installer.1.6.0.schema.json
python3 -c "
import json, yaml, jsonschema
jsonschema.validate(yaml.safe_load(open('Ajunior.Qub.installer.yaml')),
                    json.load(open('winget-manifest.installer.1.6.0.schema.json')))
print('ok')"
```

One trap: PyYAML parses an unquoted `ReleaseDate: 2026-09-04` into a `date`
object and the schema then rejects it as "not of type string". Quote it.
