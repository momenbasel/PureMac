class PuremacCli < Formula
  desc "Clean developer caches, project artifacts, and disk clutter from the terminal"
  homepage "https://github.com/momenbasel/PureMac"
  version "1.0.0"
  url "https://github.com/momenbasel/PureMac/releases/download/cli-v#{version}/puremac-cli-#{version}.tar.gz"
  sha256 "34bdc414c63fdde15593760144ef995313c5fb5df0f6ef5e0e00cbc7052fbbeb"
  license "MIT"

  depends_on macos: :big_sur
  depends_on :macos

  def install
    bin.install "puremac"
  end

  test do
    assert_match version.to_s, shell_output("#{bin}/puremac --version")
  end
end
