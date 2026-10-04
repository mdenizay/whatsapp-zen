# Homebrew cask. Lives in the tap repository (mdenizay/homebrew-tap) as
# Casks/whatsapp-zen.rb; tools/release.sh fills in version and sha256.
cask "whatsapp-zen" do
  version "VERSION"
  sha256 "SHA256"

  url "https://github.com/mdenizay/whatsapp-zen/releases/download/v#{version}/WhatsApp-Zen-#{version}.zip"
  name "WhatsApp Zen"
  desc "Unofficial lightweight native WhatsApp client"
  homepage "https://github.com/mdenizay/whatsapp-zen"

  depends_on macos: ">= :tahoe"
  depends_on arch: :arm64

  app "WhatsApp Zen.app"

  zap trash: "~/Library/Application Support/WhatsAppZen"

  caveats <<~EOS
    The app is not notarized. If macOS refuses to open it, run:
      xattr -dr com.apple.quarantine "/Applications/WhatsApp Zen.app"
  EOS
end
