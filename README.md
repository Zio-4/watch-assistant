# Watch Assistant

A watchOS app for turn-based voice conversations with an OpenAI audio model through Vercel AI Gateway. The watch stores a personal credential in Keychain, requests a short-lived session token from a Vercel Function, and streams microphone audio over an authenticated WebSocket. **Talk** starts a turn; **Done** commits it.

Permanent provider keys stay on the server. The watch never embeds `AI_GATEWAY_API_KEY`.

## Requirements

- Xcode 26 with the watchOS 26 SDK
- XcodeGen (`brew install xcodegen`) when changing `project.yml`
- Node.js 22 or newer
- A Vercel project with AI Gateway enabled
- A physical Apple Watch running watchOS 26 for a real microphone and speaker check

## Backend setup

From `backend/`:

```sh
nvm use
npm install
npm run typecheck
npm test
```

Copy the names from `.env.example` into the Vercel project settings:

- `AI_GATEWAY_API_KEY`: a server-only AI Gateway API key. Vercel OIDC can replace this on supported deployments.
- `WATCH_APP_CREDENTIAL`: a long random value used only by this personal watch app.
- `REALTIME_MODEL`: defaults to `openai/gpt-realtime-mini`.

Deploy `backend/` as the Vercel **Root Directory**, or deploy the Git repo root (this repository includes a real `/api` route). The watch must call:

`https://YOUR-APP.vercel.app/api/realtime/session`

Paste the deployment origin alone if you want — the app appends `/api/realtime/session`. In a browser, that URL should return JSON `{ "ok": true, ... }`. If you get a Vercel login page, turn off Deployment Protection for Production (Project Settings → Deployment Protection). Function logs only appear after this URL hits the serverless function.

The endpoint accepts `Authorization: Bearer <WATCH_APP_CREDENTIAL>` on POST, creates a 60-second client token, and returns the WebSocket URL, expiration, model, audio format, and application session ID. It applies a best-effort limit of five session creations per minute per client IP. For more than one serverless instance, configure a Vercel WAF rate-limit rule or replace the in-memory limiter with a shared store.

Set a budget on the AI Gateway API key in the Vercel dashboard. Budget controls are account configuration and are not stored in this repository.

## Watch app setup

1. Run `xcodegen generate` after changing `project.yml`.
2. Open `WatchAssistant.xcodeproj`.
3. Select the `WatchAssistant` target and choose your Apple developer team.
4. Build and install the app on the paired Apple Watch.
5. Open **Settings** (or the gear) in the app.
6. Enter the deployed HTTPS endpoint, including `/api/realtime/session`.
7. Enter the same personal credential as `WATCH_APP_CREDENTIAL` and tap **Save and connect**.

The credential is stored as a Keychain generic password with `AfterFirstUnlockThisDeviceOnly` accessibility.

Grant microphone access the first time you tap **Talk**. The watch converts microphone audio to 24 kHz mono PCM16 and streams it to the model.

The repository verifies the parts that do not require external credentials with:

```sh
npm --prefix backend run typecheck
npm --prefix backend test
xcodebuild -project WatchAssistant.xcodeproj \
  -scheme WatchAssistant \
  -destination 'generic/platform=watchOS' \
  -derivedDataPath /tmp/WatchAssistantDerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

Simulator and debug launch arguments are documented in [`docs/debugging.md`](docs/debugging.md).

## Project layout

```text
WatchAssistant/
  App/
  UI/
  Conversation/
  Audio/
  Networking/
  Diagnostics/

backend/
  api/realtime/session.ts
  lib/auth.ts
  lib/gateway.ts
  lib/rate-limit.ts
  lib/session-handler.ts
```
