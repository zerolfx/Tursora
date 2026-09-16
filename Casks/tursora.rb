cask "tursora" do
  version "0.4.1"
  sha256 "6578f6f3eae180ced7107d6506e2fece2451fa084f6ed3ee76923f7b41e268fa"

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
