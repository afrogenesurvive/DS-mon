cask "ds-mon" do
  version "1.6"
  sha256 :no_check

  url "https://github.com/Cherno76/DS-mon/releases/download/v#{version}/DS-mon-v#{version}.zip"
  name "DS-mon"
  desc "macOS menu bar DeepSeek API balance monitor"
  homepage "https://github.com/Cherno76/DS-mon"

  depends_on macos: ">= :sequoia"
  depends_on arch: :arm64

  app "DS-mon.app"

  zap trash: [
    "~/Library/Preferences/com.cherno.DS-mon.plist",
  ]
end
