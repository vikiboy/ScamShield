# Rehearsal notes

## Hero (`index.tsx`, `docs/images/hero.gif`)

- **Gold copied:** `device-pair` (framing: window pinned top-left off the bottom, phone straddling its right edge, one 32px gutter). The banner and touch motion come from `phone-touch`.
- **Changed:**
  - The dashboard became the Mac's decision panel: transcript, Kev-4B's top category with a rolling percentage, the result pill.
  - The lock screen became the ScamShield app's Attention list with an in-app banner.
  - Two scenes with different outcomes: a scam filed silently, then an appointment with an alert.
  - The reset has a cause: the banner retreats, a tap on Seen clears the row, and the next voicemail arrives as new.
- **Film:** `--gate` ended `rehearsal passed`.
  - **Remaining deliberate line:** "Attention" (x 20pt) and section headers (x 36pt) are near-aligned. That is iOS's inset-grouped geometry: the large title and the list's section headers sit on different insets.
  - **Recording:** frames were captured on the kit's virtual clock at 20 fps (`record-frames.mjs`). One loop is 254 frames (12.7 s).
- **Not checked:** a `compact` (358 px) design. The output is a GIF in a README, which can't switch layouts; it scales down as one image. Dark mode is not checked either: the GIF is light only.

## Scams still (`scams/`, `docs/images/scams.png`)

- **Gold copied:** `phone-touch` (a lone phone pinned 48px from the top, centered, off the bottom, on a soft wash; 400 × 460).
- **Real strings:** Scams, Archive All, Open/Done, two category headers with counts, two fictional rows. Everything else is bars.
- **Film:** one "uneven padding" line on the inset-grouped card. That is the row padding iOS uses, and it is deliberate.
