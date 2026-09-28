# Zulu notification service

One Go process, one SQLite file. It holds each user's Zulip API key, runs a Zulip
event queue on their behalf, decides which messages would have notified them, and
sends those to their Apple devices over APNs.

It works against any Zulip server: public REST and events API only, no admin
cooperation, no server-side plugin.

## Why it exists

Zulip's own push notifications go through Zulip's push bouncer, which a
third-party client cannot use. So Zulu notifies its users itself. The hard part
is not the sending; it is the deciding. Zulip computes "would this notify?" for
every message and then strips the answer out of the event stream before clients
see it, so this service reimplements the decision from the settings it mirrors.

## Layout

| Path | What |
| --- | --- |
| `cmd/zulu-notifyd` | The binary. Nothing but `fx.New(app.Module).Run()`. |
| `internal/app` | The composition root: every provider, every lifecycle hook. |
| `internal/config` | Environment into a struct, with the validation that makes a bad deployment fail at boot. |
| `internal/domain` | The entities everything agrees on: users, devices, queue state. No behaviour. |
| `internal/notify` | The notification decision and the settings mirror it reads. Pure; no I/O. |
| `internal/zulip` | The Zulip client: register, long-poll, delete queue, and the event-to-mirror translation. |
| `internal/apns` | The APNs seam: `Sender`, the payload shape, and the `sideshow/apns2` implementation. |
| `internal/repository` | All the SQL, plus the sealing of API keys. |
| `internal/service` | Business logic: device registration, push fan-out. |
| `internal/controller` | HTTP transport only: decode, map errors to status codes. |
| `internal/httpapi` | Routes, and the OpenAPI description fuego generates from them. |
| `internal/worker` | One event queue worker per user, and the supervisor that keeps the set right. |
| `internal/database` | Opening SQLite and applying the embedded migrations. |

The layering is controllers → services → repositories, wired by uber/fx. Services
never call each other: the two that exist (`DeviceService`, `DispatchService`)
share repositories, not calls. The worker is not a service — it is the
application loop that drives one, which is why it may call `DispatchService`
while services may not call it.

`internal/notify` is deliberately free of everything else. The whole reason this
project exists is that one function, so it should be testable without a database,
a network, or a clock.

## Running it

To deploy it for real — APNs credentials, HTTPS, verifying a push, and what to
check when one does not arrive — follow [SETUP.md](SETUP.md). What is below is
the short version for running it locally.

```sh
export ZULU_KEY_ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)
export ZULU_APNS_DRY_RUN=true          # log pushes instead of sending them
go run ./cmd/zulu-notifyd
```

With Docker:

```sh
echo "ZULU_KEY_ENCRYPTION_KEY=$(head -c 32 /dev/urandom | base64)" > .env
docker compose up --build
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `ZULU_KEY_ENCRYPTION_KEY` | *required* | 32 random bytes, base64. Unwraps the stored Zulip API keys. Lose it and every user must register again. |
| `ZULU_DATABASE_PATH` | `zulu.db` | SQLite file. |
| `ZULU_HTTP_ADDR` | `:8080` | Listen address. |
| `ZULU_LOG_LEVEL` | `info` | `debug` logs every non-notifiable message and why. |
| `ZULU_OPENAPI_FILE` | *unset* | Where to write the generated spec on boot. Served at `/swagger/openapi.json` regardless. |
| `ZULU_RECONCILE_INTERVAL` | `60s` | How often the supervisor re-reads the user list. |
| `ZULU_DELIVERY_GRACE` | `15m` | How long every push to a user may keep failing before the service gives its queue back. |
| `ZULU_APNS_DRY_RUN` | `false` | Log pushes instead of sending them. |
| `ZULU_APNS_KEY_FILE` | | The `.p8` signing key. |
| `ZULU_APNS_KEY_ID` | | 10-character key id. |
| `ZULU_APNS_TEAM_ID` | | 10-character team id. |
| `ZULU_APNS_BUNDLE_ID` | | The app's bundle id, used as `apns-topic`. |

## The API

Generated OpenAPI at `/swagger/openapi.json`, browsable at `/swagger/index.html`.

| Route | Auth | What |
| --- | --- | --- |
| `POST /v1/devices` | none | Register. Body carries realm URL, email, API key, device token, platform, APNs environment. Returns a device id and a device secret. |
| `GET /v1/devices` | device secret | The account's registered devices. |
| `DELETE /v1/devices/{deviceId}` | device secret | Deregister. Removing the last device deletes the stored API key too. |
| `GET /v1/status` | device secret | Whether the queue is connected, when the last event arrived, and the last error. This is how the app knows notifications are degraded. |
| `GET /healthz` | none | Liveness. |

The device secret is a 256-bit random token, returned once and stored only as a
SHA-256 hash. The app sends it as a bearer token, so the Zulip API key never
travels again after registration.

## How the decision works

`notify.Decide` follows the Zulu apps, not Zulip's own server. Each channel and
topic has one of the three levels the apps show, All Messages, Mentions Only or
Muted, read from Zulip's settings:

- Topic: followed is All, unmuted is Mentions, muted is Muted, anything else
  uses the channel's level.
- Channel: muted is Muted, `push_notifications: true` is All, anything else is
  Mentions. Zulip's global channel push setting is ignored, because the apps
  cannot show it.

After the vetoes (own message, muted sender, already read), a mention by name
always notifies, a wildcard notifies unless the level is Muted, and anything
else notifies only at All. `enable_offline_push_notifications` switches direct
messages and mentions off together.

The cases live in `spec/notification-rules.json`, which the Swift tests read
too. Change a rule there first.

## Restart behaviour

Durable: the user, their sealed API key, their devices, and per user a row
holding the Zulip queue id, the last acknowledged event id, and the settings
mirror built from that queue's snapshot. A restart resumes the same queue rather
than registering a new one, which is why the mirror is stored with the cursor and
not rebuilt from scratch.

Rebuilt: the worker set, and everything about worker health.

`BAD_EVENT_QUEUE_ID` means the queue was collected. The worker forgets the cursor
and registers again immediately — no backoff, because the server treats it as
routine. Everything else backs off with full jitter (100 ms to 10 s; up to 60 s
for an error this build does not recognise), and a `Retry-After` header is obeyed.

## Open decisions

Two questions are the user's, not mine. Both tickets stay open.

### Holding an event queue silences Zulip's own notifications (ticket 19)

Zulip's `receiver_is_off_zulip()` counts any event queue that accepts `message`
events. The moment this service connects for a user, Zulip considers them present
and stops sending its own push **and email** notifications. There is no
register-time capability that exempts a queue; requesting fewer event types is not
an option, because `message` is the whole point.

**What I implemented.** The service takes over as sole push authority while it is
working, and deliberately gives the queue back when it is not:

- A worker exists only while the user has at least one device token. Deregister
  the last device and the queue is deleted, the key is dropped, and Zulip resumes
  within its ten-minute offline window.
- If every push for a user keeps failing for `ZULU_DELIVERY_GRACE` (15 minutes by
  default), the worker parks: it deletes its Zulip queue, waits out the grace
  period, and tries again. Zulip notifies the user in the meantime.
- If the stored key is rejected, the worker stops and deletes its queue, and
  `GET /v1/status` reports `accountStatus: auth_failed`.
- If the whole instance dies, no queue is held, so Zulip resumes on its own.
  That is the safe failure mode, and it is why the queue is deleted on clean
  shutdown rather than left to time out.

**What it costs.** While the service is healthy the user gets no Zulip
missed-message *emails*, which some people rely on and nobody asked to lose.
There is no way to keep the emails and suppress only the pushes. A user running
both Zulu and the official Zulip app gets one notification, from us — which is
the outcome I would want, but it is a choice, not a fact.

**What I would decide.** Keep it, and make the app say so during onboarding:
"Zulu handles your notifications for this account; Zulip will stop emailing you
about missed messages." Revisit only if the email loss turns out to matter, in
which case the honest fix is upstream — a `client_capabilities` flag that lets a
queue opt out of counting toward presence.

### One API key, two holders (ticket 20)

A Zulip account has exactly one API key. There is no scoping and no second
credential; regenerating it for one holder revokes it for every other, including
the official apps. A bot user has its own key but cannot see the owner's DMs, so
it cannot back this service.

**What I implemented.** The app signs in, gets the key, and hands it to
`POST /v1/devices`. The service verifies it with `GET /users/me` and stores it
sealed. It never signs in on its own.

**The consequences, which the app has to surface.**

- The service holds a credential with full account access. It can read every
  message the user can, and post as them. `SECURITY.md` states this plainly; the
  app should too, at the moment it hands the key over.
- Revocation is all-or-nothing. "Stop notifications" is
  `DELETE /v1/devices/{id}` for the last device, which deletes the stored key
  here — but it does not revoke anything at Zulip. Real revocation is
  regenerating the key, which also signs the user out of the official Zulip apps
  and out of Zulu itself.
- When the key is regenerated elsewhere, the worker's next poll gets a 401. It
  stops, marks the account `auth_failed`, and gives the queue back. The app
  learns from `GET /v1/status` and must prompt for a fresh sign-in; re-registering
  with the new key restores service.
- Each side works without the other. The app reads and sends with no service;
  the service notifies with no app running. Neither can repair the other's
  credential.

**What I would decide.** Ship it as built — there is no alternative that Zulip's
model allows — and put the "this service can act as you" sentence in the
onboarding flow rather than burying it in a settings screen.

## Dependency floors

`go.mod` pins four dependencies above what the libraries themselves require,
each past a known advisory: `golang-jwt/jwt/v5` (GO-2025-3553) and
`golang.org/x/net` (GO-2026-4918) over `sideshow/apns2`'s floors,
`golang-jwt/jwt/v4` (GO-2025-3553, GO-2024-3250), and `getkin/kin-openapi`
(GO-2026-6112, GO-2026-6095) over fuego's. `go mod tidy` drops the comments
explaining why when it re-sorts the file, which is what this section is for.
`govulncheck ./...` is clean apart from GO-2026-5932 in `golang.org/x/crypto`,
which has no fixed version yet and is not on any path this service calls.

## Tests

```sh
go test ./...
```

`internal/notify` carries the weight: a table covering the precedence order,
personal-mention-beats-mute, followed topics, both wildcard kinds, muted senders,
DMs, the tri-state inheritance, and case-insensitive topic lookup. Beyond it:
event-to-mirror translation, sealed-credential round trips (including a
ciphertext moved to another row), repository behaviour against a real SQLite
file, the push fan-out with a recording sender, and the worker loop against a
scripted fake Zulip — including `BAD_EVENT_QUEUE_ID` recovery and the 401 path.

## Not built

- Rate limiting per user beyond honouring `Retry-After`, and no budgeting across
  many users on one instance.
- Batching, so a busy topic produces one push per message.
- Removing a delivered notification when the message is read elsewhere. The
  collapse identifier is deterministic, which is what makes it possible; the
  background push that would trigger it is not implemented.
- Re-notifying on message edits. Zulip has its own rules there and this service
  ignores edits entirely.
