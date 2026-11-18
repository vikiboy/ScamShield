# ScamShield agent HTTP API (v1)

Served by the Mac agent on `127.0.0.1:8787`, exposed to the iPhone through
`tailscale serve` (HTTPS, tailnet-only). The web app is served from `/` (static files
in `web/`). All JSON. No auth beyond tailnet membership (tailnet is private to the user).

## Item

```json
{
  "id": "call:EBBEF96E-...",              // stable; "call:<uuid>" or "vm:<uuid>" when voicemail has no call row
  "number": "+18775551234",               // E.164 when possible, "" if withheld
  "displayNumber": "(877) 555-1234",
  "contactName": null,                    // from Contacts, if known
  "date": "2026-11-16T17:13:56Z",
  "answered": false,
  "durationSec": 0,
  "callCount": 1,                         // calls from this number in the last 24h
  "voicemail": {                          // null when no voicemail
    "id": "4D92688B-...",
    "durationSec": 32.1,
    "transcript": "Hi this is ...",
    "transcriptConfidence": 0.91,         // 0..1, null if unknown
    "hasAudio": true
  },
  "bucket": "attention",                  // "attention" | "review" | "scam"
  "category": "medical",                  // see categories below
  "confidence": 0.87,                     // 0..1, confidence of the bucket decision
  "callback": { "recommended": true, "probability": 0.82 },
  "caller": { "name": "Dana", "organization": "Bayview Dental" },
  "summary": "Confirming your cleaning on Thursday at 3pm; call back to reschedule.",
  "reasons": ["In your contacts", "Mentions an appointment"],   // short, human-readable
  "reputation": { "score": 0.0, "complaints": 0, "lastReported": null, "robocallShare": 0.0 },
  "userLabeled": false,                   // true when the user moved/labelled it
  "done": false,                          // user marked handled / archived
  "notified": false
}
```

Categories
- attention: `personal`, `known_contact`, `appointment`, `medical`, `delivery`, `recruiter`, `business`, `financial_legit`, `callback_request`, `repeated_caller`
- review: `no_message`, `unclear`
- scam: `fraud`, `robocall`, `loan_offer`, `telemarketing`, `spam_other`, `blocked`

Notes: keys whose value is empty/null are **omitted** from Item JSON (e.g. `contactName`, `voicemail`,
`caller.name`, `reputation.lastReported`); clients must treat absent as null. `number` may be a FaceTime
email handle (contains `@`) — not dialable with `tel:`.

## Endpoints

| Method | Path | Body / query | Response |
|---|---|---|---|
| GET | `/api/items?bucket=attention&include_done=0&limit=200` | | `{ "items": [Item], "counts": {"attention": {"open": n, "total": n}, "review": {...}, "scam": {...}}, "updatedAt": iso }` |
| GET | `/api/items/{id}` | | `Item` |
| POST | `/api/items/{id}/label` | `{ "bucket": "scam", "category": "telemarketing", "applyToNumber": true }` | `Item` (user correction; learns) |
| POST | `/api/items/{id}/done` | `{ "done": true }` | `Item` |
| POST | `/api/bulk/done` | `{ "bucket": "scam" }` | `{ "updated": n }` (archive all open in bucket) |
| GET | `/api/audio/{voicemailId}` | | audio bytes (`video/quicktime` or `audio/mp4`), supports `Range` |
| GET | `/api/blocklist` | | `{ "numbers": [{ "number", "displayNumber", "reason", "addedAt" }] }` |
| POST | `/api/blocklist` | `{ "number": "+1...", "block": true }` | `{ "ok": true }` |
| GET | `/api/status` | | `{ "lastIngest": iso, "lastCallSeen": iso, "lastVoicemailSeen": iso, "models": {"decider": "ok"|"down", "writer": "ok"|"down"}, "reputation": {"numbers": n, "updatedAt": iso}, "pending": n, "permissions": {"contacts", "calendar"}, "pushSubscriptions": n, "error": string|null, "version": "1.0" }` |
| GET | `/api/push/key` | | `{ "publicKey": "<base64url VAPID public key>" }` |
| POST | `/api/push/subscribe` | PushSubscription JSON (`endpoint`, `keys.p256dh`, `keys.auth`) | `{ "ok": true }` |
| POST | `/api/push/test` | | `{ "sent": n }` |

## Push payload (encrypted, aes128gcm)

```json
{ "title": "Bayview Dental", "body": "Confirming your cleaning Thu 3pm — call back", "id": "call:...", "url": "/#/item/call:..." }
```
The service worker must always show a notification for each push (Safari requirement) and
must not need to contact the Mac to do so.
