# CLAUDE.md

Guidance for Claude Code (and other coding agents) helping someone set up or change ScamShield.
README.md is the user-facing guide; this file covers what an agent needs to know to do it safely.

## Setting it up for someone

Do these in order and confirm each before moving on. Every step is safe to re-run.

1. **Check prerequisites.**
   - Apple Silicon (`uname -m` is `arm64`) and macOS 15 or later.
   - Xcode, with the command-line tools selected.
   - `brew install uv xcodegen`.
   - About 11 GB of RAM free for the models.
2. **Check that call history reaches the Mac.** `~/Library/Application Support/CallHistoryDB/CallHistory.storedata` must exist.
   - If it doesn't, the user turns on **Calls on Other Devices** on the iPhone.
   - Reading it needs Full Disk Access for the terminal (setup only) and for the installed app.
3. **Run `./scripts/install.sh`.** The user will see three things, and you can't click them for them:
   - **A keychain prompt.** They should choose "Always Allow".
   - **The Contacts and Calendar dialogs.**
   - **Full Disk Access.** They add `~/Applications/ScamShield.app` themselves in System Settings.

   The model download is several GB. Let it finish.
4. **Verify the Mac side.** Run `curl -s localhost:8787/api/status`.
   - Both `decider` and `writer` should be `ok`. Kev takes a minute or two to load after install.
   - If not, check `~/Library/Logs/ScamShield/`.
5. **Install the iPhone app:** `./scripts/ios-install.sh`, then `./scripts/ios-install.sh --schedule`.
   - Before this, the user signs in to Xcode with their Apple ID and connects the iPhone by USB.
   - The script finds the free "Personal Team" itself.
   - On the iPhone, the user then trusts the developer: **Settings → General → VPN & Device Management**.
6. **Confirm sync.** The app should show "Synced just now" in Settings after the user opens it and allows Local Network access.

## Rules

These rules protect the user's data, money and phone.

- **Never write to Apple's databases.** The call history and voicemail stores are read from snapshot copies only. Writing to them can corrupt the user's real call log.
- **No paid Apple Developer account is assumed.** Don't add CallKit, push notifications, App Groups with iCloud containers or anything else that needs one. Free-team installs expire after 7 days; `--schedule` handles that.
- **Don't relaunch the iPhone app remotely in a loop**, for example with `devicectl ... process launch`. The user sees their phone open the app over and over. Read app state with `devicectl device copy from --domain-type appDataContainer` instead, and read logs with `uvx pymobiledevice3 syslog live`.
- **Don't re-sign the Mac app needlessly.** Every re-sign is a keychain prompt. `install.sh` re-signs only when the Swift source changes; keep it that way.
- **Don't `tccutil reset`** without asking. It wipes the user's privacy grants.
- **Ask before sending anything off the machine.** The only outbound lookup is RoboKiller, for unknown callers who left no voicemail (config `useRoboKiller`). Don't add others without the user agreeing.
- **Never commit personal data.** That includes call data, transcripts, contact names, real phone numbers, `lan.token`, `config.json` and the SQLite database (`~/Library/Application Support/ScamShield/`).
  - Fixtures use fictional 555-01xx numbers (`ios/scripts/make_fixtures.py`).
- **Don't delete calls or voicemails automatically.** Any cleanup is manual, or needs the user's explicit OK.

## Layout

| Path | What |
|---|---|
| `mac/Sources/ScamShieldCore/` | The agent. Key files: `AppleSources.swift` (reads Apple's stores), `Classifier.swift` (the policy: start here for routing changes), `Engine.swift` (pipeline), `Brain.swift` (model clients), `CloudDriveBridge.swift` and `HTTPServer.swift` (sync) |
| `mac/Sources/ScamShieldAgent/main.swift` | Entry point, LaunchAgent wiring, the Wi-Fi server for the iPhone |
| `mac/Tests/` | `swift test`; keep it green |
| `brain/` | Model service definitions. `prompts/questions.json` holds the decision questions; changing it re-classifies everything once |
| `ios/` | SwiftUI app (XcodeGen: edit `project.yml`, not the `.xcodeproj`). `Sync/MacLink.swift` is the Wi-Fi client |
| `web/` | The Mac's loopback web UI |
| `scripts/` | `install.sh`, `ios-install.sh`, `uninstall.sh` |
| `docs/` | `SYNC.md` (Mac ↔ iPhone contract), `API.md` |
| `design/` | App icon source and the README animation |

## Changing classification

- Routing is `Classifier.decide(...)`: explicit thresholds over Kev's probabilities plus context (contacts, calendar, reputation, the user's corrections).
- Change the policy there and add a test in `CoreTests.swift`.
- Bump `policyVersion` in `Engine.swift` so stored items are re-decided.
- Kev is not fine-tuned locally. User corrections steer the policy through number and organization rules and transcript similarity, not by training the model.

## Checks before you say it's done

- `cd mac && swift test` passes.
- After an install, `/api/status` reports both models `ok`.
- For iOS changes: `cd ios && xcodegen generate && xcodebuild -scheme ScamShield -destination 'generic/platform=iOS Simulator' build`.
