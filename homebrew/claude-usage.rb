cask "claude-usage" do
  version "0.3.1"
  sha256 "023b1c62463c0d675468c5c3b36a51c9e96fb55c4e59793fd27035ac5dbd448c"

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
