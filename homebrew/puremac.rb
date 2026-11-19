cask "puremac" do
  version "3.3.0"
  sha256 "37a5e421061a9d54291ea3cc1571b8ebf82685f4beb95c8da99b319ca7f30b2c"

  url "https://github.com/momenbasel/PureMac/releases/download/v#{version}/PureMac-#{version}.zip"
  name "PureMac"
  desc "Open-source application manager and system cleaner"
  homepage "https://github.com/momenbasel/PureMac"

  depends_on macos: :ventura

  app "PureMac.app"

  # Refresh LaunchServices so the Dock/Launchpad icon updates immediately on
  # (re)install instead of showing a stale cached icon (issue #111).
  postflight_steps do
    run "/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/" \
        "LaunchServices.framework/Versions/A/Support/lsregister",
        args: ["-f", "{{appdir}}/PureMac.app"]
  end

  zap trash: [
    "~/Library/Caches/com.puremac.app",
    "~/Library/LaunchAgents/com.puremac.scheduler.plist",
    "~/Library/Preferences/com.puremac.app.plist",
  ]
end
