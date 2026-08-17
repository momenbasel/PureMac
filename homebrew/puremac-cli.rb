class PuremacCli < Formula
  desc "Clean developer caches, project artifacts, and disk clutter from the terminal"
  homepage "https://github.com/momenbasel/PureMac"
  version "1.0.0"
  url "https://github.com/momenbasel/PureMac/releases/download/cli-v#{version}/puremac-cli-#{version}.tar.gz"
  sha256 "58cd364dc9204e37742312eaec19184041cf92bfdb91c53f64ed01b9e6c48519"
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
