# Watch Assistant

Phase one of the watch assistant MVP. The watchOS app stores a personal credential in Keychain, requests a short-lived AI Gateway token from a Vercel Function, opens an authenticated realtime WebSocket, and closes it when the app leaves the active state.

Voice recording and playback are intentionally not active yet. The **Talk** button shows the planned phase-two action but stays disabled in this phase.

## Requirements

- Xcode 26 with the watchOS 26 SDK
- XcodeGen (`brew install xcodegen`) when changing `project.yml`
- Node.js 22 or newer
- A Vercel project with AI Gateway enabled
- A physical Apple Watch running watchOS 26 for the final connection check

## Backend setup

From `backend/`:

```sh
nvm use
npm install
npm run build
npm test
```

Copy the names from `.env.example` into the Vercel project settings:

- `AI_GATEWAY_API_KEY`: a server-only AI Gateway API key. Vercel OIDC can replace this on supported deployments.
- `WATCH_APP_CREDENTIAL`: a long random value used only by this personal watch app.
- `REALTIME_MODEL`: defaults to `openai/gpt-realtime-mini`.

Deploy `backend/` as the Vercel project root. The function is exposed as `POST /api/realtime/session`.

The endpoint accepts `Authorization: Bearer <WATCH_APP_CREDENTIAL>`, creates a 60-second client token, and returns the WebSocket URL, expiration, model, audio format, and application session ID. It applies a best-effort limit of five session creations per minute per client IP. For more than one serverless instance, configure a Vercel WAF rate-limit rule or replace the in-memory limiter with a shared store.

Set a budget on the AI Gateway API key in the Vercel dashboard. Budget controls are account configuration and are not stored in this repository.

## Watch app setup

1. Run `xcodegen generate` after changing `project.yml`.
2. Open `WatchAssistant.xcodeproj`.
3. Select the `WatchAssistant` target and choose your Apple developer team.
4. Build and install the app on the paired Apple Watch.
5. Open the gear button in the app.
6. Enter the deployed HTTPS endpoint, including `/api/realtime/session`.
7. Enter the same personal credential as `WATCH_APP_CREDENTIAL` and tap **Save and connect**.

The credential is stored as a Keychain generic password with `AfterFirstUnlockThisDeviceOnly` accessibility. The AI Gateway API key is never sent to or embedded in the watch app.

## Phase-one device check

The phase is complete on a physical device when:

1. Launching the app changes **Connecting** to **Ready**.
2. Vercel logs show the application session ID without either secret value.
3. Backgrounding the app closes the WebSocket; foregrounding it creates a new short-lived session.
4. Searching the built app and source confirms that the real `AI_GATEWAY_API_KEY` value is absent.

The repository verifies the parts that do not require external credentials with:

```sh
npm --prefix backend run build
npm --prefix backend test
xcodebuild -project WatchAssistant.xcodeproj \
  -scheme WatchAssistant \
  -destination 'generic/platform=watchOS' \
  -derivedDataPath /tmp/WatchAssistantDerivedData \
  CODE_SIGNING_ALLOWED=NO build
```

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

