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

Meters are tinted with each provider's brand color while healthy, and switch
to amber under 25% and red under 10%. Percentages stay neutral unless low, so
a warning color anywhere in the UI always means something.

## Icons

Provider brand marks live in `Sources/Limits/Resources/ProviderIcons/` as
monochrome SVGs, tinted per provider at render time:

| Mark | Source | License |
| --- | --- | --- |
| Claude, Codex (OpenAI) | [Font Awesome 7](https://fontawesome.com/) brands | CC BY 4.0 (free brand icons) |
| Cursor, Grok, Antigravity | [Lobe Icons](https://github.com/lobehub/lobe-icons) | MIT |

Font Awesome has no Cursor, Grok/xAI or Antigravity brand icon — not even in
Pro — which is why those three come from Lobe Icons.

Brand names, logos and trademarks remain the property of their respective
owners. They are used here only to identify each provider, which does not
imply endorsement.

## Attribution

Provider credential-discovery and quota-parsing logic is derived from
[TokenRemain](https://github.com/jclarke/token-remain) (Apache-2.0).
See `NOTICE`.
