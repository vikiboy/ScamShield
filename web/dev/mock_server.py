#!/usr/bin/env python3
"""Mock ScamShield agent for developing the web app (stdlib only).

    python3 web/dev/mock_server.py [--port 8788] [--host 127.0.0.1]

Serves web/ statically and implements the API in docs/API.md against
synthetic fixtures (fictional 555-01xx numbers, no real data). All state is
in memory and resets on restart. /api/audio always returns 404.
"""

import argparse
import json
import os
import threading
import uuid
from datetime import datetime, timedelta, timezone
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, unquote, urlsplit

WEB_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

CATEGORIES = {
    "attention": [
        "personal",
        "known_contact",
        "appointment",
        "medical",
        "delivery",
        "recruiter",
        "business",
        "financial_legit",
        "callback_request",
        "repeated_caller",
    ],
    "review": ["no_message", "unclear"],
    "scam": [
        "fraud",
        "robocall",
        "loan_offer",
        "telemarketing",
        "spam_other",
        "blocked",
    ],
}

# P-256 generator point, uncompressed. A syntactically valid EC public key so that
# pushManager.subscribe() accepts it; the mock never sends real pushes.
DUMMY_VAPID_KEY = (
    "BGsX0fLhLEJH-Lzm5WOkQPJ3A32BLeszoPShOUXYmMKWT-NC4v4af5uOfutKfA-eFivOM1drMV7Oy7ZA"
    "aDe_UfU"
)

NOW = datetime.now(timezone.utc).replace(microsecond=0)
LOCK = threading.Lock()


def iso(dt):
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ") if dt else None


def stable_uuid(tag):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "scamshield-mock/" + tag)).upper()


def fmt_number(area, line):
    return "+1%s555%s" % (area, line), "(%s) 555-%s" % (area, line)


def item(
    n,
    minutes_ago,
    bucket,
    category,
    summary,
    *,
    area,
    contact=None,
    org=None,
    name=None,
    vm=None,
    vm_conf=0.9,
    has_audio=True,
    callback=(False, 0.1),
    reasons=(),
    rep=None,
    confidence=0.9,
    call_count=1,
    done=False,
    withheld=False,
    vm_only=False,
    handle=None,
):
    line = "01%02d" % n
    if handle:  # FaceTime from an Apple ID email: no phone number at all
        number, display = handle, handle
    else:
        number, display = ("", "") if withheld else fmt_number(area, line)
    voicemail = None
    if vm:
        duration, transcript = vm
        voicemail = {
            "id": stable_uuid("vm%d" % n),
            "durationSec": duration,
            "transcript": transcript,
            "transcriptConfidence": vm_conf,
            "hasAudio": has_audio,
        }
    score, complaints, last_days, robo = rep or (0.0, 0, None, 0.0)
    return without_nulls({
        "id": ("vm:" if vm_only else "call:") + stable_uuid("item%d" % n),
        "number": number,
        "displayNumber": display,
        "contactName": contact,
        "date": iso(NOW - timedelta(minutes=minutes_ago)),
        "answered": False,
        "durationSec": 0,
        "callCount": call_count,
        "voicemail": voicemail,
        "bucket": bucket,
        "category": category,
        "confidence": confidence,
        "callback": {"recommended": callback[0], "probability": callback[1]},
        "caller": {"name": name or contact, "organization": org},
        "summary": summary,
        "reasons": list(reasons),
        "reputation": {
            "score": score,
            "complaints": complaints,
            "lastReported": iso(NOW - timedelta(days=last_days))
            if last_days is not None
            else None,
            "robocallShare": robo,
        },
        "userLabeled": False,
        "done": done,
        "notified": bucket == "attention",
    })


def without_nulls(obj):
    """The real agent omits keys whose value is nil (voicemail, contactName, caller.name,
    reputation.lastReported, ...); mirror that so the app is exercised against absent keys."""
    return {k: without_nulls(v) if isinstance(v, dict) else v for k, v in obj.items() if v is not None}


def fixtures():
    H, D = 60, 60 * 24
    return [
        # --- attention ---
        item(
            1,
            25,
            "attention",
            "personal",
            "Checking you're still coming to dinner Sunday; asked you to call back.",
            area="415",
            contact="Mom",
            callback=(True, 0.88),
            confidence=0.97,
            vm=(
                18.4,
                "Hi sweetheart, it's Mom. Nothing urgent, I just wanted to check you're still coming "
                "for dinner on Sunday. Call me when you get a chance. Love you.",
            ),
            reasons=["In your contacts", "Asks you to call back"],
        ),
        item(
            2,
            50,
            "attention",
            "known_contact",
            "Called twice without leaving a message.",
            area="415",
            contact="Priya Shah",
            callback=(True, 0.74),
            call_count=2,
            confidence=0.9,
            reasons=["In your contacts", "Called 2 times today"],
        ),
        item(
            3,
            2 * H,
            "attention",
            "appointment",
            "Confirming your cleaning on Thursday at 3pm; call back to reschedule.",
            area="650",
            name="Dana",
            org="Bayview Dental",
            callback=(True, 0.82),
            confidence=0.87,
            vm=(
                32.1,
                "Hi, this is Dana from Bayview Dental calling to confirm your cleaning on Thursday at "
                "3 PM. If you need to reschedule, please give us a call back at 650-555-0103. Thanks!",
            ),
            reasons=["Mentions an appointment", "Business you've called before"],
        ),
        item(
            4,
            4 * H,
            "attention",
            "medical",
            "Your prescription is ready for pickup.",
            area="312",
            org="Northside Pharmacy",
            callback=(False, 0.18),
            confidence=0.84,
            vm=(
                21.7,
                "This is an automated message from Northside Pharmacy. Your prescription is ready for "
                "pickup at our Main Street location. Pharmacy hours are 9 AM to 9 PM.",
            ),
            reasons=["Mentions a prescription", "Automated but informational"],
        ),
        item(
            5,
            6 * H,
            "attention",
            "delivery",
            "Courier outside with a package that needs a signature; can't find unit 4B.",
            area="646",
            name="Marco",
            org="Swift Courier",
            callback=(True, 0.9),
            confidence=0.81,
            vm=(
                14.2,
                "Hey, this is Marco with Swift Courier. I'm outside with a package that needs a "
                "signature but I can't find unit 4B. Can you call me back? Thanks.",
            ),
            reasons=["Mentions a delivery", "Asks you to call back", "Time-sensitive"],
        ),
        item(
            6,
            1 * D + 2 * H,
            "attention",
            "recruiter",
            "Recruiter with a senior engineering role; wants a quick chat this week.",
            area="206",
            name="Alex Kim",
            org="Harbor Talent",
            callback=(True, 0.61),
            confidence=0.78,
            vm=(
                41.3,
                "Hi, this is Alex Kim with Harbor Talent. I came across your profile and have a senior "
                "engineering role I think you'd be a great fit for. Would love a quick chat this week. "
                "You can reach me at 206-555-0106.",
            ),
            reasons=["Names a company and role", "Leaves a callback number"],
        ),
        item(
            7,
            1 * D + 5 * H,
            "attention",
            "business",
            "Your roof repair quote is ready; they can start next week.",
            area="510",
            name="Luis",
            org="Greenline Roofing",
            callback=(True, 0.7),
            confidence=0.8,
            vm=(
                27.5,
                "Hey, it's Luis from Greenline Roofing. I've got the quote ready for the repair we "
                "talked about. We could start as early as next Tuesday. Give me a call.",
            ),
            reasons=["References earlier conversation", "Asks you to call back"],
        ),
        item(
            8,
            1 * D + 9 * H,
            "attention",
            "financial_legit",
            "Card fraud team asking you to verify a recent charge using the number on your card.",
            area="800",
            org="Coastal Credit Union",
            callback=(True, 0.66),
            confidence=0.72,
            vm=(
                24.0,
                "This is Coastal Credit Union's fraud department calling about a recent transaction on "
                "your debit card. Please call the number on the back of your card. We will never ask "
                "for your PIN.",
            ),
            reasons=[
                "Doesn't ask for personal info",
                "Directs you to the number on your card",
            ],
            rep=(0.05, 1, 40, 0.1),
        ),
        item(
            9,
            2 * D,
            "attention",
            "callback_request",
            "Claims adjuster needs to talk about your auto claim.",
            area="415",
            name="Jordan Lee",
            org="Mercer Insurance",
            callback=(True, 0.85),
            confidence=0.86,
            vm=(
                36.0,
                "Hi, this is Jordan Lee, the adjuster on your auto claim with Mercer Insurance. I have "
                "a couple of questions before I can close it out. Please call me back at your "
                "convenience.",
            ),
            reasons=["Mentions an existing claim", "Asks you to call back"],
        ),
        item(
            10,
            3 * H,
            "attention",
            "repeated_caller",
            "Called 3 times in the last hour without leaving a message.",
            area="408",
            callback=(True, 0.55),
            call_count=3,
            confidence=0.64,
            reasons=["Called 3 times in 24h", "No spam reports"],
        ),
        # --- review ---
        item(
            11,
            1 * H,
            "review",
            "no_message",
            "No voicemail left.",
            area="917",
            confidence=0.6,
            reasons=["No message left", "Not in your contacts"],
            rep=(0.1, 0, None, 0.0),
        ),
        item(
            12,
            5 * H,
            "review",
            "no_message",
            "Caller ID withheld; no message left.",
            area="000",
            withheld=True,
            confidence=0.55,
            reasons=["Caller ID withheld", "No message left"],
        ),
        item(
            13,
            8 * H,
            "review",
            "unclear",
            "Garbled message; couldn't tell what they wanted.",
            area="702",
            confidence=0.42,
            has_audio=False,
            vm_conf=0.31,
            vm=(
                11.0,
                "...hi... calling about the... [inaudible] ...if you could... thanks",
            ),
            reasons=["Transcript is low quality", "Not in your contacts"],
        ),
        item(
            14,
            1 * D + 1 * H,
            "review",
            "no_message",
            "No voicemail left.",
            area="213",
            confidence=0.58,
            reasons=["No message left"],
            rep=(0.3, 4, 12, 0.2),
        ),
        item(
            15,
            2 * D + 3 * H,
            "review",
            "unclear",
            "Short message asking for a call back; caller didn't say who they are.",
            area="347",
            vm_only=True,
            callback=(False, 0.4),
            confidence=0.5,
            vm=(9.0, "Hey, it's me. Call me back when you get this."),
            reasons=["Asks for a call back", "Caller didn't identify themselves"],
        ),
        # --- scam ---
        item(
            16,
            30,
            "scam",
            "fraud",
            "Impersonates Social Security; claims your number is suspended.",
            area="202",
            callback=(False, 0.02),
            confidence=0.98,
            vm=(
                28.0,
                "This is an urgent message from the Social Security Administration. Your social "
                "security number has been suspended due to suspicious activity. Press 1 now to speak "
                "with an officer or a warrant will be issued in your name.",
            ),
            reasons=[
                "Impersonates a government agency",
                "Threatens legal action",
                "412 complaints",
            ],
            rep=(0.97, 412, 0, 0.93),
        ),
        item(
            17,
            3 * H + 20,
            "scam",
            "robocall",
            "Pre-recorded pitch about your car's extended warranty.",
            area="877",
            callback=(False, 0.01),
            confidence=0.96,
            vm=(
                19.0,
                "We've been trying to reach you concerning your car's extended warranty. This is your "
                "final courtesy call. Press 1 to speak with a specialist.",
            ),
            reasons=["Pre-recorded message", "Known robocall script"],
            rep=(0.9, 233, 1, 0.98),
        ),
        item(
            18,
            1 * D + 4 * H,
            "scam",
            "loan_offer",
            "Says you're pre-approved for $250,000 in business funding.",
            area="888",
            callback=(False, 0.03),
            confidence=0.93,
            vm=(
                22.0,
                "Congratulations, your business has been pre-approved for up to two hundred and fifty "
                "thousand dollars in funding. No credit check required. Call us back today.",
            ),
            reasons=["Unsolicited loan offer", "No credit check claim"],
            rep=(0.85, 98, 2, 0.7),
        ),
        item(
            19,
            1 * D + 6 * H,
            "scam",
            "telemarketing",
            "Solar sales pitch offering a free home assessment.",
            area="619",
            callback=(False, 0.05),
            confidence=0.88,
            vm=(
                31.0,
                "Hi, this is Jessica with Bright Future Solar. Homeowners in your area are qualifying for "
                "zero-cost solar panels. We'd like to schedule your free assessment.",
            ),
            reasons=["Sales pitch", "Generic greeting"],
            rep=(0.62, 40, 3, 0.4),
        ),
        item(
            20,
            2 * D + 1 * H,
            "scam",
            "spam_other",
            "Number has many spam reports; no message left.",
            area="702",
            callback=(False, 0.02),
            confidence=0.82,
            reasons=["57 spam reports", "No message left"],
            rep=(0.81, 57, 1, 0.6),
        ),
        item(
            21,
            3 * D,
            "scam",
            "blocked",
            "Blocked number called again.",
            area="866",
            callback=(False, 0.0),
            confidence=1.0,
            reasons=["On your blocklist"],
            rep=(0.7, 20, 6, 0.5),
        ),
        item(
            22,
            4 * D,
            "scam",
            "fraud",
            "Fake Amazon refund asking you to install remote-access software.",
            area="855",
            callback=(False, 0.01),
            confidence=0.95,
            done=True,
            vm=(
                26.0,
                "Hello, this is Amazon customer support. We have processed a refund of three hundred "
                "ninety nine dollars to your account. To receive it, please press 1 so we can help you "
                "install our secure refund app.",
            ),
            reasons=["Impersonates a retailer", "Asks you to install software"],
            rep=(0.95, 301, 0, 0.8),
        ),
        item(
            23,
            90,
            "attention",
            "known_contact",
            "FaceTime call from a contact; no message left.",
            area="000",
            handle="sam.rivera@example.com",
            contact="Sam Rivera",
            callback=(True, 0.7),
            confidence=0.88,
            reasons=["In your contacts", "FaceTime call"],
        ),
    ]


ITEMS = fixtures()
BLOCKLIST = [
    {
        "number": ITEMS[20]["number"],
        "displayNumber": ITEMS[20]["displayNumber"],
        "reason": "Blocked from ScamShield",
        "addedAt": iso(NOW - timedelta(days=5)),
    }
]
SUBSCRIPTIONS = []


def counts():
    out = {}
    for b in CATEGORIES:
        rows = [i for i in ITEMS if i["bucket"] == b]
        out[b] = {"open": sum(1 for i in rows if not i["done"]), "total": len(rows)}
    return out


def find(item_id):
    return next((i for i in ITEMS if i["id"] == item_id), None)


class Handler(SimpleHTTPRequestHandler):
    extensions_map = {
        **SimpleHTTPRequestHandler.extensions_map,
        ".js": "text/javascript",
        ".mjs": "text/javascript",
        ".webmanifest": "application/manifest+json",
        ".svg": "image/svg+xml",
        ".png": "image/png",
    }

    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=WEB_ROOT, **kwargs)

    def end_headers(self):
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()

    # --- helpers ---
    def send_json(self, obj, status=HTTPStatus.OK):
        data = json.dumps(obj).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def read_json(self):
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return {}
        try:
            body = json.loads(self.rfile.read(length))
        except ValueError:
            return None
        return body if isinstance(body, dict) else None

    def api_parts(self):
        # Percent-decode each segment so ids like "call:ABC" work whether or not
        # the client encoded the colon.
        path = urlsplit(self.path).path
        return [unquote(p) for p in path.split("/") if p][1:]

    # --- routing ---
    def do_GET(self):
        if not urlsplit(self.path).path.startswith("/api/"):
            return super().do_GET()
        parts = self.api_parts()
        query = parse_qs(urlsplit(self.path).query)
        with LOCK:
            if parts == ["items"]:
                bucket = (query.get("bucket") or [None])[0]
                include_done = (query.get("include_done") or ["0"])[0] == "1"
                try:
                    limit = int((query.get("limit") or ["200"])[0])
                except ValueError:
                    return self.send_json(
                        {"error": "bad limit"}, HTTPStatus.BAD_REQUEST
                    )
                rows = [
                    i
                    for i in ITEMS
                    if (not bucket or i["bucket"] == bucket)
                    and (include_done or not i["done"])
                ]
                rows.sort(key=lambda i: i["date"], reverse=True)
                return self.send_json(
                    {
                        "items": rows[:limit],
                        "counts": counts(),
                        "updatedAt": iso(datetime.now(timezone.utc)),
                    }
                )
            if len(parts) == 2 and parts[0] == "items":
                found = find(parts[1])
                return (
                    self.send_json(found)
                    if found
                    else self.send_json({"error": "not found"}, HTTPStatus.NOT_FOUND)
                )
            if len(parts) == 2 and parts[0] == "audio":
                return self.send_json(
                    {"error": "no audio in mock"}, HTTPStatus.NOT_FOUND
                )
            if parts == ["blocklist"]:
                return self.send_json({"numbers": BLOCKLIST})
            if parts == ["status"]:
                return self.send_json(
                    {
                        "lastIngest": iso(
                            datetime.now(timezone.utc) - timedelta(minutes=2)
                        ),
                        "lastCallSeen": max(i["date"] for i in ITEMS),
                        "lastVoicemailSeen": max(
                            i["date"] for i in ITEMS if i.get("voicemail")
                        ),
                        "models": {"decider": "ok", "writer": "down"},
                        "reputation": {
                            "numbers": 48213,
                            "complaints": 912004,
                            "updatedAt": iso(NOW - timedelta(hours=7)),
                        },
                        "pending": 1,
                        "permissions": {"contacts": "granted", "calendar": "denied"},
                        "pushSubscriptions": len(SUBSCRIPTIONS),
                        "error": None,
                        "version": "1.0",
                    }
                )
            if parts == ["push", "key"]:
                return self.send_json({"publicKey": DUMMY_VAPID_KEY})
        self.send_json({"error": "not found"}, HTTPStatus.NOT_FOUND)

    def do_POST(self):
        parts = self.api_parts()
        if not urlsplit(self.path).path.startswith("/api/"):
            return self.send_json({"error": "not found"}, HTTPStatus.NOT_FOUND)
        body = self.read_json()
        if body is None:
            return self.send_json({"error": "invalid JSON"}, HTTPStatus.BAD_REQUEST)
        with LOCK:
            if (
                len(parts) == 3
                and parts[0] == "items"
                and parts[2] in ("label", "done")
            ):
                target = find(parts[1])
                if not target:
                    return self.send_json({"error": "not found"}, HTTPStatus.NOT_FOUND)
                if parts[2] == "done":
                    target["done"] = bool(body.get("done", True))
                    return self.send_json(target)
                bucket, category = body.get("bucket"), body.get("category")
                if bucket not in CATEGORIES or category not in CATEGORIES[bucket]:
                    return self.send_json(
                        {"error": "invalid bucket/category"}, HTTPStatus.BAD_REQUEST
                    )
                targets = [target]
                if body.get("applyToNumber") and target["number"]:
                    targets = [i for i in ITEMS if i["number"] == target["number"]]
                for t in targets:
                    t.update(bucket=bucket, category=category, userLabeled=True)
                return self.send_json(target)
            if parts == ["bulk", "done"]:
                bucket = body.get("bucket")
                if bucket not in CATEGORIES:
                    return self.send_json(
                        {"error": "invalid bucket"}, HTTPStatus.BAD_REQUEST
                    )
                updated = 0
                for i in ITEMS:
                    if i["bucket"] == bucket and not i["done"]:
                        i["done"] = True
                        updated += 1
                return self.send_json({"updated": updated})
            if parts == ["blocklist"]:
                number = body.get("number") or ""
                if not number:
                    return self.send_json(
                        {"error": "number required"}, HTTPStatus.BAD_REQUEST
                    )
                BLOCKLIST[:] = [b for b in BLOCKLIST if b["number"] != number]
                if body.get("block", True):
                    match = next((i for i in ITEMS if i["number"] == number), None)
                    BLOCKLIST.append(
                        {
                            "number": number,
                            "displayNumber": match["displayNumber"]
                            if match
                            else number,
                            "reason": "Blocked from ScamShield",
                            "addedAt": iso(datetime.now(timezone.utc)),
                        }
                    )
                return self.send_json({"ok": True})
            if parts == ["push", "subscribe"]:
                if not body.get("endpoint"):
                    return self.send_json(
                        {"error": "endpoint required"}, HTTPStatus.BAD_REQUEST
                    )
                SUBSCRIPTIONS[:] = [
                    s for s in SUBSCRIPTIONS if s.get("endpoint") != body["endpoint"]
                ] + [body]
                return self.send_json({"ok": True})
            if parts == ["push", "test"]:
                return self.send_json({"sent": len(SUBSCRIPTIONS)})
        self.send_json({"error": "not found"}, HTTPStatus.NOT_FOUND)


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8788)
    args = parser.parse_args()
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(
        "ScamShield mock agent on http://%s:%d/ (serving %s)"
        % (args.host, args.port, WEB_ROOT)
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
