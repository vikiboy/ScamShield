#!/usr/bin/env python3
"""Write a synthetic ScamShield sync folder for the simulator (stdlib only).

    python3 ios/scripts/make_fixtures.py [--no-audio] [OUT_DIR]

OUT_DIR defaults to ios/Fixtures/ScamShield. Dates are relative to now, so re-run it
before taking screenshots (otherwise everything drifts into "Earlier" and nothing is
inside the 24 h notification window). All numbers are fictional 555-01xx numbers.
Keys whose value is null are omitted, like the real Mac agent (docs/API.md).
With audio enabled (macOS only), two voicemails get spoken recordings via `say` +
`afconvert`, stored as audio/<voicemailId>.m4a.
"""

import datetime as dt
import json
import os
import shutil
import subprocess
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_OUT = os.path.join(os.path.dirname(HERE), "Fixtures", "ScamShield")
NOW = dt.datetime.now(dt.timezone.utc).replace(microsecond=0)


def iso(minutes_ago):
    return (NOW - dt.timedelta(minutes=minutes_ago)).strftime("%Y-%m-%dT%H:%M:%SZ")


def phone(n):
    """Fictional (415) 555-01nn number: (E.164, display)."""
    return f"+1415555{n:04d}", f"(415) 555-{n:04d}"


def strip_nulls(value):
    if isinstance(value, dict):
        return {k: strip_nulls(v) for k, v in value.items() if v is not None}
    if isinstance(value, list):
        return [strip_nulls(v) for v in value]
    return value


def item(
    id,
    n,
    minutes_ago,
    bucket,
    category,
    *,
    contact=None,
    name=None,
    org=None,
    summary=None,
    transcript=None,
    vm_id=None,
    vm_secs=None,
    vm_conf=None,
    has_audio=False,
    audio=None,
    callback=False,
    cb_prob=None,
    confidence=0.9,
    reasons=(),
    rep=None,
    count=1,
    done=False,
    labeled=False,
    number=None,
    display=None,
):
    if number is None:
        number, display = phone(n) if n is not None else ("", None)
    voicemail = None
    if vm_id:
        voicemail = {
            "id": vm_id,
            "durationSec": vm_secs,
            "transcript": transcript,
            "transcriptConfidence": vm_conf,
            "hasAudio": has_audio,
            "audioFile": f"audio/{vm_id}.m4a" if audio else None,
        }
    return {
        "id": id,
        "number": number,
        "displayNumber": display,
        "contactName": contact,
        "date": iso(minutes_ago),
        "answered": False,
        "durationSec": 0,
        "callCount": count,
        "voicemail": voicemail,
        "bucket": bucket,
        "category": category,
        "confidence": confidence,
        "callback": {"recommended": callback, "probability": cb_prob},
        "caller": {"name": name, "organization": org} if (name or org) else None,
        "summary": summary,
        "reasons": list(reasons),
        "reputation": rep or {"score": 0.0, "complaints": 0, "robocallShare": 0.0},
        "userLabeled": labeled,
        "done": done,
        "notified": False,
    }, (vm_id, transcript) if audio else None


DENTAL = (
    "Hi, this is Dana from Bayview Dental calling to confirm your cleaning on Thursday at 3 PM. "
    "If that time no longer works, please give us a call back at 415 555 0101 before Wednesday "
    "so we can offer the slot to someone on the waitlist. Thanks, and have a great day."
)
SSA = (
    "This is an urgent message from the Social Security Administration. Your social security number "
    "has been suspended due to suspicious activity. Press one now to speak with an officer or a "
    "warrant will be issued for your arrest."
)

ENTRIES = [
    item(
        "call:F1A0-0001",
        101,
        25,
        "attention",
        "medical",
        name="Dana",
        org="Bayview Dental",
        summary="Confirming your cleaning on Thursday at 3 PM; call back before Wednesday to reschedule.",
        transcript=DENTAL,
        vm_id="4D92688B-0001-4A1E-9C1B-5550101AAAA1",
        vm_secs=19.4,
        vm_conf=0.93,
        has_audio=True,
        audio=True,
        callback=True,
        cb_prob=0.86,
        confidence=0.91,
        reasons=[
            "Mentions an appointment",
            "Asks for a call back",
            "Local business number",
        ],
    ),
    item(
        "call:F1A0-0002",
        102,
        40,
        "attention",
        "repeated_caller",
        count=3,
        confidence=0.74,
        summary="Called 3 times in the last hour without leaving a message.",
        callback=True,
        cb_prob=0.61,
        reasons=["3 calls in under an hour", "No spam reports for this number"],
    ),
    item(
        "call:F1A0-0003",
        None,
        150,
        "attention",
        "personal",
        contact="Jordan Lee",
        number="jordan.lee@example.com",
        confidence=0.95,
        summary="Missed FaceTime audio call.",
        reasons=["In your contacts", "FaceTime call"],
    ),
    item(
        "call:F1A0-0004",
        104,
        230,
        "attention",
        "financial_legit",
        org="First Harbor Credit Union",
        summary="Fraud team asking you to confirm a recent card purchase; call the number on your card.",
        transcript="Hello, this is the fraud prevention team at First Harbor Credit Union. We noticed an unusual "
        "purchase on your debit card ending in 4421. Please call the number on the back of your card.",
        vm_id="4D92688B-0004-4A1E-9C1B-5550104AAAA4",
        vm_secs=22.0,
        vm_conf=0.88,
        has_audio=True,
        callback=True,
        cb_prob=0.79,
        confidence=0.82,
        reasons=[
            "Matches your bank",
            "Doesn’t ask for personal details",
            "Tells you to use the number on your card",
        ],
    ),
    item(
        "call:F1A0-0005",
        105,
        360,
        "attention",
        "callback_request",
        name="Sam",
        summary="Sam about the bike you listed; wants to see it this weekend.",
        transcript="Hey, it's Sam, I saw your listing for the road bike. Is it still available? Call me back.",
        vm_id="4D92688B-0005-4A1E-9C1B-5550105AAAA5",
        vm_secs=9.0,
        vm_conf=0.9,
        has_audio=True,
        callback=True,
        cb_prob=0.7,
        confidence=0.77,
        reasons=["Asks for a call back", "Mentions something you posted"],
    ),
    item(
        "call:F1A0-0006",
        106,
        60 * 26,
        "attention",
        "known_contact",
        contact="Mom",
        summary="Asking whether you’re coming for dinner on Sunday.",
        transcript="Hi sweetheart, just checking if you're still coming for dinner on Sunday. Love you.",
        vm_id="4D92688B-0006-4A1E-9C1B-5550106AAAA6",
        vm_secs=7.5,
        vm_conf=0.95,
        has_audio=True,
        callback=True,
        cb_prob=0.9,
        confidence=0.98,
        reasons=["In your contacts"],
    ),
    item(
        "call:F1A0-0007",
        107,
        60 * 29,
        "attention",
        "delivery",
        org="Parcel Express",
        summary="Driver couldn’t find your building entrance; package returned to depot.",
        transcript="Parcel Express driver here, I couldn't find the entrance to your building. "
        "Your package is going back to the depot, you can reschedule online.",
        vm_id="4D92688B-0007-4A1E-9C1B-5550107AAAA7",
        vm_secs=12.0,
        vm_conf=0.84,
        has_audio=True,
        confidence=0.8,
        reasons=["Mentions a delivery"],
    ),
    item(
        "call:F1A0-0008",
        108,
        60 * 50,
        "attention",
        "recruiter",
        name="Priya",
        org="Brightpath Talent",
        summary="Recruiter with a senior engineering role; asks for 15 minutes this week.",
        transcript="Hi, this is Priya with Brightpath Talent. I have a senior engineering role I think you'd be a "
        "great fit for. Do you have fifteen minutes this week?",
        vm_id="4D92688B-0008-4A1E-9C1B-5550108AAAA8",
        vm_secs=16.0,
        vm_conf=0.9,
        has_audio=True,
        callback=True,
        cb_prob=0.55,
        confidence=0.72,
        reasons=["Recruiter", "Specific details about you"],
    ),
    item(
        "call:F1A0-0009",
        109,
        60 * 75,
        "attention",
        "business",
        org="Greenleaf Plumbing",
        summary="Quote for the water heater is ready.",
        transcript="Greenleaf Plumbing calling, your quote for the water heater replacement is ready.",
        vm_id="4D92688B-0009-4A1E-9C1B-5550109AAAA9",
        vm_secs=6.0,
        vm_conf=0.92,
        has_audio=True,
        confidence=0.8,
        reasons=["You called this number last week"],
    ),
    item(
        "call:F1A0-0010",
        110,
        60 * 26 + 30,
        "attention",
        "appointment",
        org="Northside Physical Therapy",
        summary="Reminder: physical therapy session tomorrow at 9 AM.",
        transcript="This is Northside Physical Therapy with a reminder of your appointment tomorrow at 9 AM.",
        vm_id="4D92688B-0010-4A1E-9C1B-5550110AAA10",
        vm_secs=8.0,
        vm_conf=0.94,
        has_audio=True,
        confidence=0.88,
        reasons=["Matches a calendar event", "Mentions an appointment"],
    ),
    item(
        "call:F1A0-0011",
        111,
        60 * 120,
        "attention",
        "medical",
        org="Bayview Pharmacy",
        done=True,
        summary="Prescription ready for pickup.",
        transcript="Your prescription is ready for pickup.",
        vm_id="4D92688B-0011-4A1E-9C1B-5550111AAA11",
        vm_secs=5.0,
        vm_conf=0.9,
        has_audio=True,
        confidence=0.9,
        reasons=["Mentions a prescription"],
    ),
    item(
        "call:F1A0-0012",
        112,
        70,
        "review",
        "no_message",
        confidence=0.6,
        reasons=["No voicemail", "Unknown number"],
    ),
    item(
        "call:F1A0-0013",
        None,
        60 * 23,
        "review",
        "no_message",
        confidence=0.55,
        reasons=["No voicemail", "Caller ID withheld"],
    ),
    item(
        "vm:F1A0-0014",
        114,
        300,
        "review",
        "unclear",
        confidence=0.48,
        summary="Hard to make out; mentions an account and a callback.",
        transcript="hi this is calling about the account we need you to call back at your earliest",
        vm_id="4D92688B-0014-4A1E-9C1B-5550114AAA14",
        vm_secs=11.0,
        vm_conf=0.42,
        has_audio=True,
        reasons=["Transcript is unclear", "Mentions an account"],
    ),
    item(
        "call:F1A0-0015",
        115,
        60 * 49,
        "review",
        "no_message",
        confidence=0.58,
        reasons=["No voicemail", "Unknown number"],
    ),
    item(
        "call:F1A0-0016",
        116,
        50,
        "scam",
        "fraud",
        org="Social Security Administration",
        summary="Claims your Social Security number is suspended and threatens arrest.",
        transcript=SSA,
        vm_id="4D92688B-0016-4A1E-9C1B-5550116AAA16",
        vm_secs=14.8,
        vm_conf=0.9,
        has_audio=True,
        audio=True,
        confidence=0.97,
        reasons=[
            "Government agencies don’t call like this",
            "Threatens arrest",
            "Asks you to press 1",
        ],
        rep={
            "score": 0.92,
            "complaints": 148,
            "lastReported": iso(90),
            "robocallShare": 0.88,
        },
    ),
    item(
        "call:F1A0-0017",
        117,
        200,
        "scam",
        "robocall",
        summary="Recorded message about lowering your energy bill.",
        transcript="Congratulations, you qualify for a lower energy rate. Press 1 to learn more.",
        vm_id="4D92688B-0017-4A1E-9C1B-5550117AAA17",
        vm_secs=10.0,
        vm_conf=0.86,
        has_audio=True,
        confidence=0.93,
        reasons=["Recorded message", "Reported as robocall"],
        rep={
            "score": 0.81,
            "complaints": 63,
            "lastReported": iso(60 * 30),
            "robocallShare": 0.97,
        },
    ),
    item(
        "call:F1A0-0018",
        118,
        60 * 27,
        "scam",
        "loan_offer",
        org="Capital Lending Partners",
        summary="Pre-approved business loan offer.",
        transcript="You've been pre-approved for a business loan of up to two hundred fifty thousand dollars.",
        vm_id="4D92688B-0018-4A1E-9C1B-5550118AAA18",
        vm_secs=13.0,
        vm_conf=0.88,
        has_audio=True,
        confidence=0.89,
        reasons=["Unsolicited loan offer"],
        rep={
            "score": 0.66,
            "complaints": 21,
            "lastReported": iso(60 * 72),
            "robocallShare": 0.7,
        },
    ),
    item(
        "call:F1A0-0019",
        119,
        60 * 30,
        "scam",
        "telemarketing",
        org="Vehicle Services Department",
        summary="Final notice about your car’s extended warranty.",
        transcript="This is your final notice regarding your vehicle's extended warranty.",
        vm_id="4D92688B-0019-4A1E-9C1B-5550119AAA19",
        vm_secs=12.0,
        vm_conf=0.9,
        has_audio=True,
        confidence=0.94,
        reasons=["Extended warranty pitch", "Reported as telemarketing"],
        rep={
            "score": 0.88,
            "complaints": 310,
            "lastReported": iso(60 * 5),
            "robocallShare": 0.91,
        },
    ),
    item(
        "call:F1A0-0020",
        120,
        60 * 52,
        "scam",
        "spam_other",
        confidence=0.71,
        reasons=["Reported as spam"],
        rep={"score": 0.58, "complaints": 9, "robocallShare": 0.4},
    ),
    item(
        "call:F1A0-0021",
        121,
        60 * 53,
        "scam",
        "blocked",
        confidence=1.0,
        reasons=["You blocked this number"],
        labeled=True,
    ),
    item(
        "call:F1A0-0022",
        122,
        60 * 80,
        "scam",
        "fraud",
        org="Amazon Security",
        done=True,
        summary="Claims a suspicious order was placed on your account.",
        transcript="This is Amazon security, a suspicious order of an iPhone was placed on your account.",
        vm_id="4D92688B-0022-4A1E-9C1B-5550122AAA22",
        vm_secs=9.0,
        vm_conf=0.89,
        has_audio=True,
        confidence=0.95,
        reasons=["Impersonates a company", "Reported as fraud"],
        rep={
            "score": 0.9,
            "complaints": 205,
            "lastReported": iso(60 * 2),
            "robocallShare": 0.8,
        },
    ),
]


def make_audio(out_dir, vm_id, text):
    audio_dir = os.path.join(out_dir, "audio")
    with tempfile.TemporaryDirectory() as tmp:
        aiff = os.path.join(tmp, "vm.aiff")
        subprocess.run(["say", "-o", aiff, text], check=True)
        subprocess.run(
            [
                "afconvert",
                "-f",
                "m4af",
                "-d",
                "aac",
                "-b",
                "32000",
                aiff,
                os.path.join(audio_dir, f"{vm_id}.m4a"),
            ],
            check=True,
        )


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    out = os.path.abspath(args[0]) if args else DEFAULT_OUT
    with_audio = (
        "--no-audio" not in sys.argv
        and shutil.which("say")
        and shutil.which("afconvert")
    )
    items = [entry for entry, _ in ENTRIES]
    for name in ("corrections", "audio"):
        os.makedirs(os.path.join(out, name), exist_ok=True)
    inbox = {
        "version": 1,
        "generatedAt": iso(0),
        "mac": {
            "lastCallSeen": max(i["date"] for i in items),
            "lastIngest": iso(1),
            "models": "ok",
        },
        "items": sorted(items, key=lambda i: i["date"], reverse=True),
    }
    with open(os.path.join(out, "inbox.json"), "w") as f:
        json.dump(strip_nulls(inbox), f, indent=2, ensure_ascii=False)
        f.write("\n")
    if with_audio:
        for _, audio in ENTRIES:
            if audio:
                make_audio(out, *audio)
    print(f"wrote {out} ({len(items)} items{', with audio' if with_audio else ''})")


if __name__ == "__main__":
    main()
