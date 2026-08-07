cask "claude-usage" do
  version "0.7.3"
  sha256 "16b490676951d2fcb80bab186132fa7657bf5fbeb3b20a2854b6ea8c90228584"

  url "https://github.com/Sven1603/claude-usage/releases/download/v#{version}/ClaudeUsage-#{version}.zip"
  name "Claude Usage"
  desc "Menu bar display of Claude 5-hour session usage"
  homepage "https://github.com/Sven1603/claude-usage"

  app "Claude Usage.app"

  # The keep-awake feature registers a LaunchDaemon (com.sven.claude-usage.sleeperd)
  # via SMAppService. macOS disables a bundle-registered daemon once the app bundle
  # is deleted, but boot it out explicitly so uninstall does not leave it loaded in
  # the current session. Harmless when the user never enabled the feature.
  #
  # The bootout is a SIGTERM, which the daemon handles by restoring `disablesleep`
  # to 0 before it exits — otherwise uninstalling while the feature is on would
  # leave a Mac that can never sleep again and no longer has the helper that could
  # undo it. Quitting the app stops it re-asserting a lease over that. Homebrew
  # fixes the order (ORDERED_DIRECTIVES puts :launchctl before :quit) rather than
  # honouring the order written here, but once the Mach service is gone the app's
  # XPC calls simply fail, so the remaining window is harmless.
  uninstall quit:     "com.sven.claude-usage",
            launchctl: "com.sven.claude-usage.sleeperd"

  # The daemon's state directory is root-owned, so a user-level uninstall cannot
  # remove it. It only exists if the feature was used, and the daemon deletes the
  # marker inside it whenever it restores sleep:
  #   sudo rm -rf "/Library/Application Support/com.sven.claude-usage"

  # Signed with Developer ID and notarized by Apple — no quarantine workaround needed.

  # The app stores its session key in the macOS Keychain (service: com.sven.claude-usage).
  # Keychain items are NOT removed by uninstall. To clean up manually run:
  #   security delete-generic-password -s com.sven.claude-usage
  # (or blank the fields in Settings → Save before uninstalling).
end
