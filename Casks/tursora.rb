cask "tursora" do
  version "0.3.0"
  sha256 "9706add96eab66828b86700125c657537cedff5c92680108d79e96283ef99557"

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
