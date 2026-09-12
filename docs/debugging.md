# Debugging

Debug-only launch arguments and Simulator shortcuts. These are compiled out of Release builds (`#if DEBUG`). Do not use them for a physical-watch check.

## Watch Simulator launch arguments

Pass these after the bundle identifier with `simctl launch`, or in the Xcode scheme’s **Arguments Passed On Launch**.

| Argument | What it does |
| --- | --- |
| `-preview-ready` | Skip the Vercel session and Gateway WebSocket. Puts the conversation screen in **Ready** with a fake session so **Talk** is tappable without credentials. |
| `-auto-talk` | Requires `-preview-ready`. After a short delay, invokes the same Talk then Done actions as the primary button. Used to screenshot Listening and Thinking. |

Example:

```sh
xcrun simctl launch booted com.philipziolkowski.WatchAssistant -preview-ready
xcrun simctl launch booted com.philipziolkowski.WatchAssistant -preview-ready -auto-talk
```

Grant the simulated microphone if Talk should get past the permission prompt:

```sh
xcrun simctl privacy booted grant microphone com.philipziolkowski.WatchAssistant
```

## Where the code lives

- `WatchAssistant/UI/ConversationView.swift` — reads the launch arguments in `.task`.
- `WatchAssistant/Conversation/ConversationController.swift` — `preparePreviewReady()` and `isLocalPreview` skip Gateway send/commit.
- `WatchAssistant/Audio/AudioController.swift` — if the Simulator reports a 0 Hz mic format, capture falls back to silent PCM so Talk/Done still complete a turn. A physical watch uses the real microphone tap.

## What not to do

- Do not treat a `-preview-ready` run as proof that audio reached AI Gateway.
- Do not ship these arguments in a Release scheme.
