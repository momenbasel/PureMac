cask "puremac" do
  version "2.9.0"
  sha256 "dd028c88a479b5009377ca7be55d7b2ea3d9f5286b647de83047977a4738c659"

  url "https://github.com/momenbasel/PureMac/releases/download/v#{version}/PureMac-#{version}.zip"
  name "PureMac"
  desc "Free, open-source macOS app manager and system cleaner"
  homepage "https://github.com/momenbasel/PureMac"

  depends_on macos: :ventura

  app "PureMac.app"

  # Refresh LaunchServices so the Dock/Launchpad icon updates immediately on
  # (re)install instead of showing a stale cached icon (issue #111).
  postflight do
    system_command "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/Versions/A/Support/lsregister",
                   args: ["-f", "#{appdir}/PureMac.app"]
  end

  zap trash: [
    "~/Library/Preferences/com.puremac.app.plist",
    "~/Library/Caches/com.puremac.app",
    "~/Library/LaunchAgents/com.puremac.scheduler.plist",
  ]
end
