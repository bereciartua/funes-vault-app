cask "funes-vault" do
  version "0.1.0"
  # Placeholder until the release is out: scripts/update-cask.sh fills in the
  # SHA-256 of the attested DMG (and refuses to keep anything else).
  sha256 "PLACEHOLDER: run sh scripts/update-cask.sh funes-vault 0.1.0"

  url "https://github.com/bereciartua/funes-vault-app/releases/download/v#{version}/FunesVault-#{version}.dmg"
  name "Funes Vault"
  desc "Personal memory vault that AI agents can use only as you allow"
  homepage "https://funesvault.com/"

  livecheck do
    url "https://github.com/bereciartua/funes-vault-app/releases/latest/download/appcast.xml"
    strategy :sparkle, &:short_version
  end

  auto_updates true
  depends_on macos: :sequoia

  app "FunesVault.app"
  binary "#{appdir}/FunesVault.app/Contents/MacOS/funes-mcp"

  uninstall quit: "com.funesvault.mac"

  zap trash: [
    "~/Library/Application Support/FunesVault",
    "~/Library/Caches/com.funesvault.mac",
    "~/Library/HTTPStorages/com.funesvault.mac",
    "~/Library/HTTPStorages/com.funesvault.mac.binarycookies",
    "~/Library/Preferences/com.funesvault.mac.plist",
  ]
end
