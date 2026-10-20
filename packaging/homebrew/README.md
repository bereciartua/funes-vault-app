# Homebrew cask

Funes Vault installs with

```sh
brew install --cask bereciartua/tap/funes-vault
```

from the same tap as EK Bridge, [`bereciartua/homebrew-tap`](https://github.com/bereciartua/homebrew-tap). The cask lives in the tap, not here: `tap.patch` was applied there in `9089cdd` ("Add the funes-vault cask (0.1.2)"), and the tap's `update.yml` keeps `Casks/funes-vault.rb` at the latest release. This folder keeps, for reference:

- **`funes-vault.rb`**: the cask as reviewed, the file `tap.patch` adds as `Casks/funes-vault.rb`. The tap's copy has the current version and its SHA-256 filled in.
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

## Updating it

After a release is published, run the tap's update workflow (it also runs every six hours):

```sh
gh workflow run update.yml --repo bereciartua/homebrew-tap -f cask=funes-vault
```

`scripts/update-cask.sh` bumps `Casks/funes-vault.rb` only when:

1. **The DMG's build attestation** shows `.github/workflows/release.yml` in `bereciartua/funes-vault-app` built it from the `vX.Y.Z` tag. If the workflow is renamed, change `workflow=` in the tap's `scripts/update-cask.sh` (it's shared with EK Bridge, whose workflow is also `release.yml`).
2. **The checksum** matches: the release has `FunesVault-X.Y.Z.dmg` and a `SHA256SUMS` listing it with the same SHA-256.

The tap's check then runs livecheck, which needs `appcast.xml` at `releases/latest/download/appcast.xml` with `sparkle:shortVersionString` `X.Y.Z`; fetches `homepage` (`https://funesvault.com/`, `brew audit --online`) and runs `funes-mcp --help` through the link. Running the tap's `scripts/check.sh` on your own Mac untaps and re-taps `bereciartua/tap` from your checkout, and `--install` installs into `/Applications`, so don't run `--install` on a Mac where Funes Vault or EK Bridge is installed.
