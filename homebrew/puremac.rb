cask "puremac" do
  version "1.0.0"
  sha256 "b2d10d93dbc8faba810c572be57520f49eb9b3fb81e4cc86f9cec03a2c494196"

  url "https://github.com/momenbasel/PureMac/releases/download/v#{version}/PureMac-v#{version}.zip"
  name "PureMac"
  desc "Free, open-source macOS cleaning utility"
  homepage "https://github.com/momenbasel/PureMac"

  app "PureMac.app"

  zap trash: [
    "~/Library/Preferences/com.puremac.app.plist",
    "~/Library/Caches/com.puremac.app",
    "~/Library/LaunchAgents/com.puremac.scheduler.plist",
  ]
end
