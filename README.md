# Limits

A macOS menu bar app that shows how much quota you have left across your AI
coding accounts — Claude, Codex, Cursor, Grok and Antigravity — including
multiple accounts per provider.

## Build and run

```sh
script/build_and_run.sh          # build, sign, install to dist/ and launch
script/build_and_run.sh build    # build only
```

Useful while developing:

```sh
dist/Limits.app/Contents/MacOS/Limits --diagnose        # print every provider's live numbers
dist/Limits.app/Contents/MacOS/Limits --open-dashboard  # open the window without clicking the menu bar
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

## Visibility

Each account has two independent switches:

- **Menu Bar** — include this account's remaining percentage in the menu bar title.
- **Track** — fetch it at all and show it on the Limits screen and dropdown.

## Attribution

Provider credential-discovery and quota-parsing logic is derived from the
[TokenRemain](https://github.com/) project (Apache-2.0). See `NOTICE`.
