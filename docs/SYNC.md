# ScamShield sync contract (v1)

Two paths, tried in this order on every refresh:

1. **Direct Wi-Fi (primary).** The Mac agent advertises Bonjour `_scamshield._tcp` (port 8790) and
   serves `GET /inbox` (the exact inbox.json body below) and `GET /audio/<voicemailId>`. Every
   request must carry `Authorization: Bearer <token>`; the token lives in
   `~/Library/Application Support/ScamShield/lan.token` and is built into the iPhone app's
   Info.plist (`ScamShieldLANToken`) by scripts/ios-install.sh. iOS asks once for Local Network access.
2. **iCloud Drive (fallback when not on the Mac's network)**, described below.

Corrections from the iPhone always travel through the iCloud Drive folder.

## iCloud Drive folder

The Mac agent and the iPhone app exchange files through one folder in the user's iCloud Drive:

```
iCloud Drive/ScamShield/                 (Mac: ~/Library/Mobile Documents/com~apple~CloudDocs/ScamShield/)
├── inbox.json                           written by the Mac (atomic replace)
├── audio/<voicemailId>.mov              written by the Mac (AAC in QuickTime; AVPlayer plays it)
├── corrections/<uuid>.json              written by the iPhone, consumed + deleted by the Mac
└── README.txt                           human note: "managed by ScamShield, don't edit"
```

The iPhone app gets access once: the user picks the `ScamShield` folder in the Files picker; the app
keeps a security-scoped bookmark. All reads/writes use `NSFileCoordinator` (this also makes iOS
download the latest iCloud version).

## inbox.json

```json
{
  "version": 1,
  "generatedAt": "2026-11-17T17:40:00Z",
  "mac": { "lastCallSeen": "...", "lastIngest": "...", "models": "ok" },
  "items": [ Item, ... ]            // newest first; open items of all ages + done items from the last 30 days
}
```

`Item` is exactly the `Item` JSON in docs/API.md (ISO-8601 dates; keys whose value is null are
omitted; `number` may be a FaceTime email handle). Additional field:

- `voicemail.audioFile`: relative path like `"audio/4D92688B-....mov"` when the audio has been copied
  (recent voicemails only); absent otherwise.

## corrections/<uuid>.json

One file per user action, written atomically by the app (write to a temp name, then move):

```json
{ "id": "<uuid>", "itemId": "call:...", "action": "label", "bucket": "scam", "category": "telemarketing", "applyToNumber": true, "at": "2026-11-17T17:41:00Z" }
{ "id": "<uuid>", "itemId": "call:...", "action": "done", "done": true, "at": "..." }
{ "id": "<uuid>", "itemId": "call:...", "action": "block", "number": "+15550100001", "block": true, "at": "..." }
```

The Mac applies each file once (ids remembered), deletes it, and rewrites `inbox.json`. Until the
new inbox arrives, the app shows its own optimistic state (it overlays its pending corrections).

## Notifications

No push (free Apple ID). The app registers a `BGAppRefreshTask` and also refreshes on launch /
foreground; when it sees an `attention` item that is not `done`, not yet notified *on this phone*,
and newer than 24 h, it posts a local notification (title = contact/organization/number, body =
summary). Scams and Review never notify.
