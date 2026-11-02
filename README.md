# Claude Usage (macOS menu bar)

Shows your live Claude **5-hour session usage** — a mini progress bar plus
percent and a live countdown to reset — right in the macOS menu bar.

![Claude Usage in the menu bar](docs/screenshot.png)

> Unofficial: reads the same claude.ai usage endpoint the Settings → Usage page
> uses, via your own `sessionKey`. Not affiliated with Anthropic.

## Install

Requires macOS 13+ and [Homebrew](https://brew.sh) (install Homebrew first if you
don't have it). Then run:

    brew tap sven1603/claude-usage
    brew trust --tap sven1603/claude-usage
    brew install claude-usage

The `brew trust` line is needed because this is a third-party tap (Homebrew
requires trusting non-official taps before installing their casks). Upgrade
later with `brew upgrade claude-usage`.

After installing, open **Claude Usage** from your Applications folder — it will
prompt you to sign in.

## Getting your `sessionKey`

The app reads the same usage data the claude.ai **Settings → Usage** page shows.
It needs your browser's `sessionKey` cookie:

1. Open <https://claude.ai> and log in.
2. Open DevTools (⌥⌘I) → **Application** tab → **Storage → Cookies →
   `https://claude.ai`**.
3. Copy the **Value** of the `sessionKey` cookie.
4. In the app: menu bar item → **Settings…** → paste it → **Save**.

> **This key is a credential.** Treat it like a password — it grants access to
> your claude.ai account. The app stores it **only in your macOS Keychain** and
> sends it **only to claude.ai**. It is never written to disk in plaintext or
> logged. To revoke, log out of claude.ai (rotates the cookie) or clear the key
> in Settings.

## Make sure you're tracking the right account

- **Auto-detect (default):** leave the Org UUID blank. The app checks each org
  your account can see and tracks the one with an **active** 5-hour session.
- **Confirm it:** the dropdown shows **Org: `<name>`** — check this matches the
  account you expect.
- **Team / multiple orgs:** if auto-detect picks the wrong one, set the **Org
  UUID** in Settings. Find it in the claude.ai URL or via
  `GET https://claude.ai/api/organizations`.

## Display states

- `NN% · XhYYm` — usage percent + live countdown (ticks every second).
- Bar color: green `<75%`, orange `75–90%`, red `>90%`.
- `⚠︎ Auth` — session key expired/invalid → re-copy it in Settings.
- Dimmed bar — data is stale (no successful fetch in >3 min); check your network.
- `Resetting…` — the session window just rolled over.

## Keep awake with lid closed

Closing the lid normally ends any running Claude Code session. The dropdown has a
**Keep awake with lid closed** toggle that suspends that behaviour while you need it.

The first time you turn it on, macOS asks you to approve a background helper. This
is required: changing the system sleep setting needs administrator rights. You can
revoke it later in **System Settings → General → Login Items & Extensions**, or via
**Settings → Sleep → Remove helper**.

Sleep is restored automatically when:

- nothing has held the Mac awake for 2 minutes,
- the time limit is reached (4 hours by default, configurable in **Settings → Sleep**),
- the battery drops below 20% on battery power,
- the system clock jumps backwards,
- or Claude Usage quits, crashes, or you log out.

That last one is not a cleanup routine that might be skipped. The app holds a
90-second lease that it renews every 15 seconds, so if it stops running for any
reason the helper restores sleep on its own.

A moon icon appears in the menu bar whenever the feature is active.

> **A Mac left awake with the lid shut keeps drawing power and getting warm.**
> Under a heavy workload the 20% battery floor will trigger before the time limit
> does. On a 64 Wh MacBook Air, a light session costs roughly a quarter of the
> battery over 4 hours; a sustained compile loop will hit the floor in about 2.5.

## Uninstall

Quit the app (menu bar → **Quit**) and drag **Claude Usage.app** from
`/Applications` to the Trash.

The session key lives in the macOS Keychain (service `com.sven.claude-usage`)
and is **not** removed when the app is uninstalled. To remove it manually:

    security delete-generic-password -s com.sven.claude-usage

Alternatively, blank the session key (and org UUID) in **Settings → Save**
before uninstalling.

If you used **Keep awake with lid closed**, remove the helper first via
**Settings → Sleep → Remove helper** — this restores normal sleep and unregisters
the background daemon. To clean up its state directory manually:

    sudo rm -rf "/Library/Application Support/com.sven.claude-usage"

## Build from source

Requires Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

    brew install xcodegen
    cd ClaudeUsage && xcodegen generate && open ClaudeUsage.xcodeproj

Run the logic tests (no app build needed):

    cd ClaudeUsageCore && swift test

## Releasing (maintainer)

Prereqs (one-time): a **Developer ID Application** certificate and notarization
credentials stored as the `claude-usage` keychain profile
(`xcrun notarytool store-credentials`).

    cd ClaudeUsage
    xcodegen generate

    # 1. Archive + export a Developer ID build (strips get-task-allow; hardened runtime)
    xcodebuild -project ClaudeUsage.xcodeproj -scheme ClaudeUsage \
      -configuration Release -destination 'generic/platform=macOS' \
      archive -archivePath build/ClaudeUsage.xcarchive
    xcodebuild -exportArchive -archivePath build/ClaudeUsage.xcarchive \
      -exportPath build/export -exportOptionsPlist ExportOptions.plist

    # 2. Notarize + staple
    ditto -c -k --keepParent "build/export/Claude Usage.app" submit.zip
    xcrun notarytool submit submit.zip --keychain-profile claude-usage --wait
    xcrun stapler staple "build/export/Claude Usage.app"

    # 3. Package the stapled app + publish
    ditto -c -k --keepParent "build/export/Claude Usage.app" ClaudeUsage-x.y.z.zip
    shasum -a 256 ClaudeUsage-x.y.z.zip      # update version+sha256 in the cask(s)
    gh release create vx.y.z ClaudeUsage-x.y.z.zip

Then bump `version`/`sha256` in `homebrew/claude-usage.rb` and the
`homebrew-claude-usage` tap.
