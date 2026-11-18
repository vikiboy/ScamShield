import { Bar, Phone, Row, Segmented, Stage } from '../../kit'
import './scams.css'

// ScamShield README still: the iPhone app's Scams list, grouped by type.
// Phone only, pinned a gutter from the top, off the bottom (phone-touch's
// framing). Real words: the title, Archive All, Open/Done, the two category
// headers with their counts, and the first loan-offer row. Everything else is
// bars. Fictional 555 numbers only.

const LOAN_ROWS: (null | { w: number; s: number })[] = [null, { w: 112, s: 168 }, { w: 98, s: 150 }]
const ROBO_ROWS = [
  { w: 104, s: 140 },
  { w: 120, s: 160 },
  { w: 92, s: 132 },
]

export default function ScamsStill() {
  return (
    <Stage width={400} height={460} className="sxs">
      {() => (
        <>
          <div className="sxs-wash" />
          <Phone width={300} className="sxs-phone">
            <div className="sxs-app">
              <span className="sxs-action">Archive All</span>
              <span className="sxs-title">Scams</span>
              <Segmented items={['Open', 'Done']} value={0} className="sxs-seg" />

              <span className="sxs-section">
                Loan offer <span className="sxs-count">· 12</span>
              </span>
              <div className="sxs-group">
                {LOAN_ROWS.map((r, i) =>
                  r === null ? (
                    <Row key={i} className="sxs-row" title="(415) 555-0118" meta="9:12" subtitle="Pre-approved business loan; press 2." />
                  ) : (
                    <Row key={i} className="sxs-row" title={<Bar w={r.w} h={8} tone={3} />} meta={<Bar w={26} h={6} tone={2} />} subtitle={<Bar w={r.s} h={6} tone={2} />} />
                  ),
                )}
              </div>

              <span className="sxs-section">
                Robocall <span className="sxs-count">· 4</span>
              </span>
              <div className="sxs-group">
                <Row className="sxs-row" title="(415) 555-0117" meta="Mon" subtitle="Recorded message about your energy bill." />
                {ROBO_ROWS.slice(1).map((r, i) => (
                  <Row key={i} className="sxs-row" title={<Bar w={r.w} h={8} tone={3} />} meta={<Bar w={26} h={6} tone={2} />} subtitle={<Bar w={r.s} h={6} tone={2} />} />
                ))}
              </div>
            </div>
          </Phone>
        </>
      )}
    </Stage>
  )
}
