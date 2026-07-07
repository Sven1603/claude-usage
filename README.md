# Claude Usage (macOS menu bar)

Shows your live Claude **5-hour session usage** — a mini progress bar plus
percent and a live countdown to reset — right in the macOS menu bar.

```
▇▇▇▇▇▇▁▁  92% · 1h29m
```

> Unofficial: reads the same claude.ai usage endpoint the Settings → Usage page
> uses, via your own `sessionKey`. Not affiliated with Anthropic.

## Install

1. Download `ClaudeUsage-x.y.z.zip` from the
   [Releases](https://github.com/Sven1603/claude-usage/releases) page.
2. Unzip it and move **Claude Usage.app** to `/Applications`.
3. It's an unsigned hobby build, so on first launch macOS Gatekeeper will block
   it. Either:
   - Right-click the app in `/Applications` → **Open** → **Open**, or
   - Clear the quarantine flag once:

         xattr -dr com.apple.quarantine "/Applications/Claude Usage.app"

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

## Uninstall

Quit the app (menu bar → **Quit**) and drag **Claude Usage.app** from
`/Applications` to the Trash.

The session key lives in the macOS Keychain (service `com.sven.claude-usage`)
and is **not** removed when the app is uninstalled. To remove it manually:

    security delete-generic-password -s com.sven.claude-usage

Alternatively, blank the session key (and org UUID) in **Settings → Save**
before uninstalling.

## Build from source

Requires Xcode 15+ and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

    brew install xcodegen
    cd ClaudeUsage && xcodegen generate && open ClaudeUsage.xcodeproj

Run the logic tests (no app build needed):

    cd ClaudeUsageCore && swift test

## Releasing (maintainer)

1. Archive the app: Xcode → Product → Archive → Distribute App →
   **Copy App** (no signing needed for the hobby build).
2. Zip it: `ditto -c -k --keepParent "Claude Usage.app" ClaudeUsage-x.y.z.zip`.
3. Create a GitHub release `vx.y.z` and attach the zip (`gh release create`).
4. (Optional, if you later set up a Homebrew tap) compute
   `shasum -a 256 ClaudeUsage-x.y.z.zip` and update `homebrew/claude-usage.rb`
   (`version`, `sha256`).
