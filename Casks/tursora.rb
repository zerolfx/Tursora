cask "tursora" do
  version "0.4.2"
  sha256 "d788cc029b275ad78f6f802152a0a418ed2204d1b121a2ec5b2b268d2c34a6d6"

  url "https://github.com/zerolfx/Tursora/releases/download/v#{version}/Tursora-#{version}-macOS-arm64.dmg"
  name "Tursora"
  desc "Native macOS file manager with split panes and editable paths"
  homepage "https://github.com/zerolfx/Tursora"

  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Tursora.app"

  caveats <<~EOS
    Tursora is ad-hoc signed and is not notarized by Apple.
    If macOS blocks the first launch, follow the trusted-download steps at:
      https://github.com/zerolfx/Tursora#first-launch
  EOS
end
