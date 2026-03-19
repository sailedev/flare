cask "flare" do
  version "1.0.0"
  sha256 "REPLACE_AFTER_FIRST_RELEASE"

  url "https://github.com/sailedev/flare/releases/download/v#{version}/Flare-#{version}.dmg"
  name "Flare"
  desc "Screenshot tool that lives in the menu bar"
  homepage "https://github.com/sailedev/flare"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :sonoma"

  app "Flare.app"

  zap trash: [
    "~/Library/Application Support/com.saile.flare",
    "~/Library/Caches/com.saile.flare",
    "~/Library/Preferences/com.saile.flare.plist",
  ]
end
