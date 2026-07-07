cask "claude-usage" do
  version "0.1.0"
  sha256 "6c58985a6991841243cc706cbb2bbfa3397e334c0164b4e8a48a40f74e97abd5"

  url "https://github.com/Sven1603/claude-usage/releases/download/v#{version}/ClaudeUsage-#{version}.zip"
  name "Claude Usage"
  desc "Menu bar display of Claude 5-hour session usage"
  homepage "https://github.com/Sven1603/claude-usage"

  app "Claude Usage.app"

  # Unsigned hobby build: clear quarantine so it launches without the Gatekeeper prompt.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/Claude Usage.app"]
  end

  # The app stores its session key in the macOS Keychain (service: com.sven.claude-usage).
  # Keychain items are NOT removed by uninstall. To clean up manually run:
  #   security delete-generic-password -s com.sven.claude-usage
  # (or blank the fields in Settings → Save before uninstalling).
end
