# Homebrew cask for Macerodactyl — PREPARED, NOT PUBLISHED.
#
# This installs the macOS app from a GitHub release artifact. It is a template:
# fill `version` and `sha256` (and confirm the release asset name below) when you
# cut a release, then either submit it to a tap you own or `brew install --cask`
# from this file directly.
#
# Important: the project is source-only and NOT notarized (no paid Apple Developer
# account; macOS 15 removed the Control-click Gatekeeper bypass). A cask that
# ships an un-notarized app will be blocked by Gatekeeper on install. Ship a
# notarized build here if you have an account; otherwise prefer building from
# source (see the README) and treat this cask as scaffolding.
cask "macerodactyl" do
  version "0.1.0"
  sha256 :no_check # replace with the real artifact sha256 when you publish

  url "https://github.com/ctkkoenig/macerodactyl/releases/download/v#{version}/Macerodactyl-#{version}.zip"
  name "Macerodactyl"
  desc "Native macOS control panel for local Docker containers"
  homepage "https://github.com/ctkkoenig/macerodactyl"

  depends_on macos: ">= :sequoia" # macOS 15+

  app "Macerodactyl.app"

  caveats <<~EOS
    Macerodactyl is not notarized. If macOS blocks it, prefer building from source
    (see the project README) with your own Apple ID team. The App Sandbox is
    intentionally OFF so the app can talk to the docker CLI and read your stacks.
  EOS
end
