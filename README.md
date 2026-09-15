# Limits

A macOS menu bar app that shows how much quota you have left across your AI
coding accounts — Claude, Codex, Cursor, Grok and Antigravity — including
multiple accounts per provider.

## Build and run

```sh
script/build_and_run.sh          # build, sign to dist/ and launch
script/build_and_run.sh build    # build only
script/build_and_run.sh install  # build, copy to /Applications and launch
```

Use `install` before turning on **Launch at Login**: macOS records the app's
path when it registers, so a bundle that later moves stops launching.

Useful while developing:

```sh
dist/Limits.app/Contents/MacOS/Limits --diagnose        # print every provider's live numbers
dist/Limits.app/Contents/MacOS/Limits --open-dashboard  # open the window without clicking the menu bar
dist/Limits.app/Contents/MacOS/Limits --open-dashboard --providers  # ...on the Providers screen
dist/Limits.app/Contents/MacOS/Limits --open-popover    # show the dropdown for inspection
dist/Limits.app/Contents/MacOS/Limits --open-settings   # show the settings window
dist/Limits.app/Contents/MacOS/Limits --dark            # force dark appearance
```

## How it reads your accounts

Limits is **read-only with respect to your credentials**. It never refreshes a
provider's token and never writes one back. Renewal stays with the provider's
own tool, so Limits can't race it over a refresh token or trip third-party
renewal throttling. When a session lapses, that surfaces as a fixable issue
rather than a silent re-auth.

| Provider | Where the credential comes from |
| --- | --- |
| Claude | The OAuth token Claude Code holds (Keychain, keyed by config dir) |
| Codex | `$CODEX_HOME/auth.json`, then Codex's own keyring item |
| Cursor | Cursor's `state.vscdb`, read-only, then Keychain |
| Grok | `~/.grok/auth.json` |
| Antigravity | The running app's loopback language server, then Keychain |

## Multiple accounts

Claude and Codex ship a real CLI login, so Limits runs **their** OAuth flow
inside an app-owned configuration directory. Each extra account gets its own
isolated profile under `~/Library/Application Support/com.josephclarke.limits/accounts/`,
which is what lets several accounts coexist without Limits ever touching your
real `~/.claude` or `~/.codex` session.

Cursor, Grok and Antigravity expose no CLI login to delegate to, so an extra
account there means storing one pasted token in the Keychain.

Your primary ("System") account is never signed in or out by Limits — for
those, the app tells you what to run instead.

## Settings

Reachable from **Settings** in the dropdown footer. Carries Launch at Login
(via `SMAppService`) and a plain statement of the refresh interval and the
read-only credential policy.

## Visibility

Each account has two independent switches:

- **Menu Bar** — include this account's remaining percentage in the menu bar title.
- **Track** — fetch it at all and show it on the Limits screen and dropdown.

## Design

The app icon is generated rather than checked in as binary art:

```sh
swift script/make_app_icon.swift /tmp && iconutil -c icns /tmp/Limits.iconset -o Resources/Limits.icns
```

The window is a narrow single column (512 pt) with a unified translucent
titlebar carrying a segmented screen switcher — no sidebar. Cards are glass
over a vibrant window background.

Meters are ring gauges tinted with each provider's brand color while healthy,
switching to amber under 25% and red under 10%. Percentages stay neutral
unless low, so a warning color anywhere in the UI always means something.

## Icons

Provider brand marks live in `Sources/Limits/Resources/ProviderIcons/` as
monochrome SVGs, tinted per provider at render time:

They come from the Claude Design project that specifies the UI, stored as
single-path `currentColor` templates so one asset serves both themes. The
~14 KB of provenance metadata each shipped with is stripped; the artwork
itself is ~0.5–1.5 KB.

Each provider has a light/dark tint pair, resolved dynamically:

| Provider | Light | Dark |
| --- | --- | --- |
| Claude | `#C25F30` | `#D9784A` |
| Codex | `#3A6BD6` | `#5C8CF0` |
| Cursor | `#7B4FD8` | `#9973EB` |
| Grok | `#A8871F` | `#E6C24A` |
| Antigravity | `#2E9B74` | `#5CC79E` |

Brand names, logos and trademarks remain the property of their respective
owners. They are used here only to identify each provider, which does not
imply endorsement.

## Attribution

Provider credential-discovery and quota-parsing logic is derived from
[TokenRemain](https://github.com/jclarke/token-remain) (Apache-2.0).
See `NOTICE`.
