cask "puremac" do
  version "3.4.0"
  sha256 "d013cbaedf601c9aeb666b9685f4672410a023a2b2c89e1ed5def9d19b68ecff"

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
