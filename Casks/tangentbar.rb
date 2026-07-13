# Homebrew cask, served straight from this repo (no separate homebrew-* tap):
#
#   brew tap joshuatanderson/tangentbar https://github.com/Joshuatanderson/tangentbar
#   brew install --cask tangentbar --no-quarantine
#
# --no-quarantine matters: the app is ad-hoc signed (not notarized), and brew
# deliberately re-applies the quarantine attribute without it.
# version + sha256 are bumped automatically by .github/workflows/release.yml.
cask "tangentbar" do
  version "0.2.0"
  sha256 "7d20a84f3f281f04bff28da6e10b7be17855becf811b96cc42c2e629da039b62"

  url "https://github.com/Joshuatanderson/tangentbar/releases/download/v#{version}/TangentBar-#{version}.zip"
  name "TangentBar"
  desc "Double-click any word for an instant, context-aware definition from a local model"
  homepage "https://github.com/Joshuatanderson/tangentbar"

  app "TangentBar.app"

  caveats <<~EOS
    TangentBar is not notarized. If you installed without --no-quarantine,
    clear the flag before first launch:
      xattr -dr com.apple.quarantine "#{appdir}/TangentBar.app"

    First launch asks for the Accessibility permission — it's how TangentBar
    reads the text around your click. Nothing leaves your machine.
  EOS

  zap trash: [
    "~/Library/Application Support/TangentBar",
  ]
end
