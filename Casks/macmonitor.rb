# Homebrew cask for the direct-download edition.
# Publish it from a tap repository (e.g. github.com/expertosa/homebrew-tap, file Casks/macmonitor.rb)
# so users can run:  brew install --cask expertosa/tap/macmonitor
# After each release, update `version` and `sha256` (printed by the release workflow in SHA256SUMS.txt).
cask "macmonitor" do
  version "1.1.0"
  sha256 :no_check # replace with the DMG's sha256 from the GitHub release

  url "https://github.com/expertosa/MacMonitor/releases/download/v#{version}/MacMonitor-#{version}.dmg"
  name "MacMonitor"
  desc "Menu bar, desktop panel and widgets for Mac and Linux server resource monitoring"
  homepage "https://github.com/expertosa/MacMonitor"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: ">= :ventura"

  app "MacMonitor.app"

  uninstall quit: "com.tweetso.macmonitor"

  zap trash: [
    "~/Library/Preferences/com.tweetso.macmonitor.plist",
    "~/Library/Group Containers/NWPTRYJ9FL.com.tweetso.macmonitor",
    "~/Library/Containers/com.tweetso.macmonitor.widget",
  ]
end
