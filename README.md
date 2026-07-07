# Claude Usage

Shows your live Claude **5-hour session usage** — a mini progress bar plus
percent and a live countdown to reset. This repository contains two platform
implementations: a macOS menu-bar app and a Windows tray app.

![Claude Usage in the menu bar](docs/screenshot.png)

> Unofficial: reads the same claude.ai usage endpoint the Settings → Usage page
> uses, via your own `sessionKey`. Not affiliated with Anthropic.

## Platform support

- **macOS**: native menu-bar app (macOS 13+).
- **Windows**: tray application built with WPF (.NET 8).
- **Linux**: not officially supported.

## Install

Choose the section for your platform.

### macOS (menu bar app)

Requires macOS 13+ and [Homebrew](https://brew.sh). Then run:

  brew tap sven1603/claude-usage
  brew trust --tap sven1603/claude-usage
  brew install claude-usage

The `brew trust` line is needed because this is a third-party tap; upgrade
later with `brew upgrade claude-usage`.

After installing, open **Claude Usage** from your Applications folder — it will
prompt you to sign in.

### Windows (tray app)

You can download prebuilt Windows artifacts from the repository Actions run or
build locally. See the **Windows build and download** section below for
download and local build steps.

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

## Windows build and download

This repository also contains a Windows app in `ClaudeUsage.Windows/ClaudeUsage.Windows`.

### Download from GitHub

The GitHub Actions workflow named **Build Windows App** publishes build artifacts.

1. Open the repository on GitHub.
2. Click the `Actions` tab.
3. Select the **Build Windows App** workflow.
4. Choose a completed run on the `windows-version` branch or a release tag.
5. Download the artifact named `windows-builds`.
6. Unzip the downloaded file and run `ClaudeUsage.exe`.

The workflow produces:

- `ClaudeUsage-Windows-x64.zip`
- `ClaudeUsage-Windows-ARM64.zip`

If the run is for a tag, the same zip files are also attached to the GitHub Release.

### Build locally on Windows

1. Install the .NET 8 SDK.
2. Open a terminal and run:

    cd ClaudeUsage.Windows/ClaudeUsage.Windows
    dotnet restore
    dotnet publish -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true -o ./publish-x64

3. Run the executable at `publish-x64/ClaudeUsage.exe`.

> Tip: `dotnet publish` produces a self-contained Windows executable, so users do not need a separate .NET runtime.

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
