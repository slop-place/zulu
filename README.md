# Zulu

A native Zulip client for iOS and macOS.

Zulu exists because the official clients make topics hard to live in. Here topics are
first-class: a channel that uses them renders as a list of threads, a channel that
doesn't renders as plain chat, and the app works out which is which. Channels group into
folders you make, topics can be promoted to sit beside channels, and anything can be
renamed or hidden for yourself alone — none of which the Zulip server ever learns about.

Minimum iOS 27, built on Liquid Glass. The Mac app is a real Mac app — sidebar and split view,
menu bar and shortcuts, ⌘K to jump anywhere, a composer that sends on Return, notifications
for mentions and direct messages while it is running.

## Status

Early but usable. Sign in against any Zulip server; read and send in channels, topics and
DMs; react and reply; attach files, photos and camera captures; vote in polls. A Go
notification service lives in `service/` and builds to a container, but is not deployed.

See [`.scratch/zulu-client/map.md`](.scratch/zulu-client/map.md) for the decisions already
locked and what is still open.

## Layout

| Path | What |
| --- | --- |
| `App` | The iOS app, and the Xcode project that builds both apps |
| `Mac` | The macOS app |
| `Shared` | SwiftUI shared by both apps: the model, messages, composer pieces |
| `Packages/ZuluKit` | `ZulipAPI`, `ZuluStore` (GRDB), `ZuluSync`, `ZuluMarkup`, `ZuluEmoji`, `ZuluCompose`, `ZuluPolls` |
| `service` | The Go notification service |
| `.scratch/zulu-client/` | The wayfinder map, its decision tickets, and research notes |

## Running it

```sh
cd App && xcodegen generate && open Zulu.xcodeproj
```

Pick the `Zulu` scheme for iOS or `ZuluMac` for the Mac. Then sign in with your Zulip organization's address. Password and SSO both work; SSO opens
a browser and comes back through the `zulip://` callback the server hardcodes.

GIFs use the server's KLIPY or GIPHY key, else Zulu's own KLIPY key. Release builds get
that from the `KLIPY_API_KEY` Actions secret. For local builds, put
`KLIPY_API_KEY = <key>` in `App/Secrets.xcconfig`, which git ignores.

release-please cuts releases for the app (to TestFlight) and the notification service
(to GHCR) separately. See [`docs/RELEASING.md`](docs/RELEASING.md) for how that works
and the one-time Apple setup it needs.
