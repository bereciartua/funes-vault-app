# Homebrew cask (draft)

Funes Vault installs with

```sh
brew install --cask bereciartua/tap/funes-vault
```

from the same tap as EK Bridge, [`bereciartua/homebrew-tap`](https://github.com/bereciartua/homebrew-tap). The cask lives in the tap, not here. This folder holds:

- **`funes-vault.rb`**: the cask, for review. It's the same file `tap.patch` adds as `Casks/funes-vault.rb`.
- **`tap.patch`**: a `git diff` against the tap's `main` at `7149a2d` ("Merge pull request #1 from bereciartua/ci/homebrew-api-token"). It:
  - adds `Casks/funes-vault.rb`;
  - adds `scripts/casks.sh`, which lists each cask's repository, DMG name, app and command;
  - makes `scripts/update-cask.sh` take the cask's name (`sh scripts/update-cask.sh funes-vault [VERSION]`). It still downloads the DMG and `SHA256SUMS`, checks the build attestation (`--signer-workflow bereciartua/funes-vault-app/.github/workflows/release.yml`, `--source-ref refs/tags/vX.Y.Z`, `--deny-self-hosted-runners`) and the SHA-256 before it writes anything. It also fills in a cask whose `sha256` is still a placeholder, even at the same version;
  - makes `scripts/check.sh` check every cask, or the ones named (`sh scripts/check.sh --install funes-vault`), and test each app's own command (`funes-mcp --help`);
  - runs `update.yml` and `check.yml` once per cask (a matrix), one cask at a time for updates, with a `cask` input on the manual run;
  - adds Funes Vault to the tap's README.

## The cask

- **`url`**: `https://github.com/bereciartua/funes-vault-app/releases/download/v#{version}/FunesVault-#{version}.dmg`, the versioned DMG, not the stable `FunesVault.dmg`, so the checksum matches one file.
- **`sha256`**: a placeholder string, `"PLACEHOLDER: run sh scripts/update-cask.sh funes-vault 0.1.0"`. It isn't `:no_check`, and the tap's check fails while it's there. The update script replaces it with the SHA-256 of the attested DMG.
- **`livecheck`**: Sparkle's appcast at `releases/latest/download/appcast.xml`, short version.
- **`auto_updates true`**: the app updates itself with Sparkle, so `brew upgrade` skips it unless `--greedy`.
- **`depends_on macos: :sequoia`**: macOS 15 or later. In a cask, the symbol is a minimum, which is how EK Bridge's cask writes it (`:sonoma`). `brew style` accepts it and passes the file with no offenses.
- **`binary`**: links `FunesVault.app/Contents/MacOS/funes-mcp` into Homebrew's `bin`. Agent setups still use the full path in `/Applications`, so the link is a convenience (`funes-mcp check --agent <id>`).
- **`uninstall quit: "com.funesvault.mac"`**, and **`zap`** moves these to the Trash: `~/Library/Application Support/FunesVault`, `~/Library/Caches/com.funesvault.mac`, `~/Library/HTTPStorages/com.funesvault.mac` (and its `.binarycookies`), `~/Library/Preferences/com.funesvault.mac.plist`. API keys in the Keychain (`com.funesvault.provider`) aren't touched; the tap's README says so.

## Applying it

Do this once v0.1.0 is published and `bereciartua/funes-vault-app` is **public**. The tap's workflows use the tap's own `github.token`, which can't read a private repository's releases, attestations or appcast.

```sh
git -C homebrew-tap switch main
git -C homebrew-tap pull
git -C homebrew-tap switch -c funes-vault
git -C homebrew-tap apply --check ../funes-vault-app/packaging/homebrew/tap.patch
git -C homebrew-tap apply ../funes-vault-app/packaging/homebrew/tap.patch
cd homebrew-tap
sh scripts/update-cask.sh funes-vault 0.1.0   # fills in the attested SHA-256
sh scripts/check.sh funes-vault               # style, audit, livecheck (no install)
git add -A
git commit -m "Add funes-vault 0.1.0"
```

Then open a pull request: `check.yml` installs both casks on a macOS runner. If `main` has moved since `7149a2d` and the patch doesn't apply, apply it with `git apply --3way` and resolve, or copy `funes-vault.rb` and redo the script changes by hand.

## What to check before merging

1. **The release workflow's path.** The attestation check expects the DMG to be attested by `.github/workflows/release.yml` in `bereciartua/funes-vault-app`, built from the `v0.1.0` tag. If the workflow has another name, change `workflow=` in `scripts/update-cask.sh` (it's shared with EK Bridge, whose workflow is also `release.yml`).
2. **The asset names.** The release must have `FunesVault-0.1.0.dmg` and a `SHA256SUMS` listing it, and `appcast.xml` must be served at `releases/latest/download/appcast.xml` with `sparkle:shortVersionString` `0.1.0`, or livecheck fails.
3. **The website.** `brew audit --online` fetches `homepage` (`https://funesvault.com/`), so the site and its HTTPS certificate have to be up first (site/DNS.md).
4. **`funes-mcp --help` exits 0.** `check.sh --install` runs it through the link.
5. **`desc`**: "Personal memory vault that AI agents can use only as you allow". Homebrew's audit wants no article at the start, no app name and at most 80 characters.
6. **Running `check.sh` on your own Mac** untaps and re-taps `bereciartua/tap` from your checkout, and `--install` installs into `/Applications`. Don't run `--install` on a Mac where Funes Vault or EK Bridge is installed.
