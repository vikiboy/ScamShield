// Records one loop of the README hero frame by frame on Stageshow's virtual
// clock (deterministic, 20 fps). Run the Stageshow playground first (npm run dev)
// with this folder copied to <stageshow>/examples/scamshield, then:
//   STAGESHOW_DIR=/path/to/stageshow node record-frames.mjs ./frames
// and encode with ffmpeg (see README.md in this folder).
const { launch } = await import(`${process.env.STAGESHOW_DIR}/scripts/browser.mjs`)
import { mkdirSync } from 'node:fs'
const out = process.argv[2]; mkdirSync(out, { recursive: true })
const browser = await launch()
const page = await (await browser.newContext({ viewport: { width: 900, height: 600 }, deviceScaleFactor: 2 })).newPage()
await page.goto('http://127.0.0.1:4521/?embed=scamshield&still=0')
const el = await page.waitForSelector('#example .ss-stage')
await page.evaluate(() => window.postMessage({ type: 'stageshow:control', playing: false }, location.origin))
await page.waitForTimeout(300)
const fps = await page.evaluate(() => window.__stageshow.clock.fps)
const per = Math.round(fps / 20)
const t0 = await page.evaluate(() => window.__stageshow.clock.now())
let seenScam = 0, last = null, i = 0, end = null
while (true) {
  await page.evaluate((n) => window.__stageshow.clock.step(n), per)
  const [now, mark] = await page.evaluate(() => [window.__stageshow.clock.now(), document.querySelector('.ss-stage').getAttribute('data-mark')])
  if (mark === 'scam' && last !== 'scam') { seenScam++; if (seenScam === 2) { end = now - t0; break } }
  last = mark
  await el.screenshot({ path: `${out}/f${String(i++).padStart(4, '0')}.png` })
  if (i > 900) break
}
console.log(JSON.stringify({ fps, per, frames: i, loopEndMs: end }))
await browser.close()
