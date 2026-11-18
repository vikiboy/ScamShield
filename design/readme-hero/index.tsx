import { Avatar, Badge, Bar, Collapse, Count, Meter, Notification, Phone, Row, Spinner, Stage, Text, Window, type Act } from '../../kit'
import icon from './icon.png'
import './scamshield.css'

// ScamShield README hero: a device pair. The Mac (hero, top-left, off the
// bottom) hears each voicemail and its local decision model files it; the
// iPhone app (satellite, straddling the window's right edge) only hears about
// the one that needs you. Two scenes, two outcomes: a loan robocall is filed
// in Scams silently (the phone does nothing, which is the point), then a
// dentist's voicemail lands in Attention with an alert. The reset has a seen
// cause: the banner retreats as iOS's do, a tap on Seen clears the row, and the
// next voicemail arrives as new.
//
// Real strings: the caller, "Voicemail", the transcript, the category and its
// probability, the result, the model line; on the phone "Attention", "Seen",
// the banner and two rows. Everything else is bars.

type S = { vm: 0 | 1; decided: boolean; alert: boolean; row: boolean }
const START: S = { vm: 0, decided: false, alert: false, row: false }

const VMS = [
  {
    caller: '(415) 555-0118',
    meta: 'Voicemail · 0:24',
    text: '“…you’ve been pre-approved for a business loan of up to $250,000. Press 2 to speak with a specialist…”',
    category: 'Loan offer',
    pct: 94,
    tone: 'danger' as const,
    result: 'Filed in Scams · no alert',
  },
  {
    caller: 'Bayview Dental',
    meta: 'Voicemail · 0:18',
    text: '“Hi, this is Dana from Bayview Dental confirming your cleaning on Thursday at 3 PM. Please call us back…”',
    category: 'Appointment',
    pct: 97,
    tone: 'accent' as const,
    result: 'Needs Attention · alert sent',
  },
]

const REST = { x: 700, y: 330 }

const script = async (a: Act<S>) => {
  // Scene 1: a loan robocall, decided and filed. The phone stays quiet.
  await a.wait(900)
  a.mark('scam')
  a.set({ decided: true })
  await a.wait(3000)
  // Scene 2: a new voicemail arrives
  a.set({ vm: 1, decided: false })
  await a.wait(1300)
  a.set({ decided: true })
  await a.wait(900)
  a.mark('alert')
  a.set({ alert: true, row: true })
  await a.wait(3200)
  // The banner goes away on its own, as iOS's do
  a.set({ alert: false })
  await a.wait(700)
  a.mark('seen')
  await a.click('seen')
  a.set({ row: false })
  await a.wait(900)
  await a.move(REST)
  // The next voicemail arrives as new
  a.set({ vm: 0, decided: false })
  await a.wait(500)
}

function Panel({ vm, decided, on }: { vm: 0 | 1; decided: boolean; on: boolean }) {
  const v = VMS[vm]
  return (
    <div className="sx-panel" data-on={on || undefined}>
      <Row
        className="sx-caller"
        lead={<Avatar size={36} plain />}
        title={v.caller}
        subtitle={v.meta}
        meta="now"
      />
      <p className="sx-quote">{v.text}</p>
      <div className="sx-decision">
        <div className="sx-decision__head">
          <span className="sx-model">Kev-4B · on this Mac</span>
          <span className="sx-status" data-on={decided || undefined}>
            <Spinner size={12} />
            <span>Analyzing</span>
          </span>
        </div>
        <div className="sx-cat">
          <span className="sx-cat__label">{v.category}</span>
          <Meter value={decided ? v.pct / 100 : 0} tone={v.tone} className="sx-meter" />
          <span className="sx-cat__pct" data-on={decided || undefined}>
            <Count value={decided ? v.pct : 0} />%
          </span>
        </div>
        <div className="sx-cat sx-cat--quiet">
          <Bar w={64} h={6} tone={2} />
          <Meter value={decided ? 0.03 : 0} tone="ink" className="sx-meter" />
          <Bar w={22} h={6} tone={2} />
        </div>
        <div className="sx-result" data-on={decided || undefined}>
          <Badge tone={v.tone} dot>
            {v.result}
          </Badge>
        </div>
      </div>
    </div>
  )
}

export default function ScamShieldHero() {
  return (
    <Stage<S>
      width={760}
      height={460}
      initial={START}
      poster={{ vm: 1, decided: true, alert: true, row: true }}
      script={script}
      cursor={{ at: REST, style: 'touch' }}
      className="sx"
    >
      {(s) => (
        <>
          <Window url="127.0.0.1:8787" urlShape="pill" className="sx-window">
            <div className="sx-body">
              {/* Both voicemails stay mounted in one cell and crossfade */}
              <div className="sx-swap">
                <Panel vm={0} decided={s.vm === 0 && s.decided} on={s.vm === 0} />
                <Panel vm={1} decided={s.vm === 1 && s.decided} on={s.vm === 1} />
              </div>
              <div className="sx-earlier">
                <Bar w={52} h={6} tone={3} />
                {[
                  [96, 120],
                  [120, 90],
                  [84, 132],
                ].map(([a, b], i) => (
                  <div key={i} className="sx-earlier__row">
                    <Bar w={28} h={28} r={14} tone={2} />
                    <span className="sx-earlier__lines">
                      <Bar w={a} h={7} tone={3} />
                      <Bar w={b} h={6} tone={2} />
                    </span>
                  </div>
                ))}
              </div>
            </div>
          </Window>

          <Phone width={290} className="sx-phone">
            <div className="sx-app">
              <div className="sx-nav">
                <span className="sx-seen" data-target="seen">
                  Seen
                </span>
              </div>
              <Text className="sx-title">Attention</Text>
              <div className="sx-stack">
                <span className="sx-section">Today</span>
                <div className="sx-group" style={{ position: 'static', margin: '0 16px' }}>
                  <Collapse open={s.row}>
                    <Row
                      className="sx-row"
                      title="Bayview Dental"
                      meta="9:41"
                      subtitle="Cleaning Thursday 3 PM; call back to confirm."
                    />
                  </Collapse>
                  <Row className="sx-row" title="Mom" meta="8:05" subtitle="Coming for dinner on Sunday?" />
                </div>
                <span className="sx-section sx-section--gap">Yesterday</span>
                <div className="sx-group" style={{ position: 'static', margin: '0 16px' }}>
                  {[
                    [92, 150],
                    [120, 128],
                    [80, 160],
                    [104, 136],
                    [88, 144],
                    [116, 120],
                  ].map(([a, b], i) => (
                    <Row key={i} className="sx-row" title={<Bar w={a} h={8} tone={3} />} meta={<Bar w={26} h={6} tone={2} />} subtitle={<Bar w={b} h={6} tone={2} />} />
                  ))}
                </div>
              </div>
            </div>
            <div className="sx-banner" data-on={s.alert || undefined}>
              <Notification
                banner
                icon={<img src={icon} alt="" className="sx-appicon" />}
                title="Bayview Dental"
                body="Confirming your cleaning Thursday at 3 PM. Call back to confirm."
              />
            </div>
          </Phone>
        </>
      )}
    </Stage>
  )
}
