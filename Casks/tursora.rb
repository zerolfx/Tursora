cask "tursora" do
  version "0.2.1"
  sha256 "3458aa15670b75e8469398e4d0928ed73e6f038567c9ae7dba049e509333460b"

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
