cask "claude-usage" do
  version "0.3.0"
  sha256 "f1a06e3c03f93bc8727ed88d56de8215881b2452a7b5b64d127229a7220dae6b"

  url "https://github.com/Sven1603/claude-usage/releases/download/v#{version}/ClaudeUsage-#{version}.zip"
  name "Claude Usage"
  desc "Menu bar display of Claude 5-hour session usage"
  homepage "https://github.com/Sven1603/claude-usage"

  app "Claude Usage.app"

  # Signed with Developer ID and notarized by Apple — no quarantine workaround needed.

  # The app stores its session key in the macOS Keychain (service: com.sven.claude-usage).
  # Keychain items are NOT removed by uninstall. To clean up manually run:
  #   security delete-generic-password -s com.sven.claude-usage
  # (or blank the fields in Settings → Save before uninstalling).
end
