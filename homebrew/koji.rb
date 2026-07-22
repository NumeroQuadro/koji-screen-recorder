cask "koji" do
  version "1.0.0"
  sha256 "<sha256-of-dmg>"

  url "https://github.com/NumeroQuadro/koji-screen-recorder/releases/download/v#{version}/Koji-#{version}.dmg"
  name "Kōji"
  desc "Menu bar screen and audio recorder using ScreenCaptureKit"
  homepage "https://numeroquadro.github.io/koji-screen-recorder"

  depends_on macos: ">= :sonoma"

  auto_updates true

  app "Koji.app"

  zap trash: [
    "~/Library/Preferences/com.koji.screenrecorder.plist",
    "~/Library/Caches/com.koji.screenrecorder",
    "~/Library/Application Support/com.koji.screenrecorder",
    "~/Library/Logs/com.koji.screenrecorder",
    "~/Library/HTTPStorages/com.koji.screenrecorder",
    "~/Library/Saved Application State/com.koji.screenrecorder.savedState",
    "~/Movies/Koji",
  ]
end
