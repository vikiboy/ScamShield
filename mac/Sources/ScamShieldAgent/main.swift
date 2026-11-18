import Foundation
import ScamShieldCore
import EventKit

setvbuf(stdout, nil, _IOLBF, 0)
let df = ISO8601DateFormatter()
func log(_ s: String) { print("[\(df.string(from: Date()))] \(s)") }

let args = CommandLine.arguments
let config = Config.load()
let support = Config.supportDir

/// Resources: inside ScamShield.app/Contents/Resources, or the repo when run via `swift run`.
func resource(_ name: String) -> URL {
    if let env = ProcessInfo.processInfo.environment["SCAMSHIELD_RESOURCES"] { return URL(fileURLWithPath: env).appendingPathComponent(name) }
    if let r = Bundle.main.resourceURL?.appendingPathComponent(name), FileManager.default.fileExists(atPath: r.path) { return r }
    var dir = URL(fileURLWithPath: #filePath)
    for _ in 0..<4 { dir.deleteLastPathComponent() }    // mac/Sources/ScamShieldAgent/main.swift → repo root
    return name == "prompts" ? dir.appendingPathComponent("brain/prompts") : dir.appendingPathComponent(name)
}

do {
    let store = try Store(path: support.appendingPathComponent("scamshield.sqlite").path)
    let snapshots = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("ScamShield/snapshots")
    let sources = AppleSources(snapshotDir: snapshots)
    let brain = try Brain(config: config, promptsDir: resource("prompts"))
    let devNoPersonal = ProcessInfo.processInfo.environment["SCAMSHIELD_NO_PERSONAL"] == "1"   // dev runs from a terminal
    let context = PersonalContext(useContacts: config.useContacts && !devNoPersonal, useCalendar: config.useCalendar && !devNoPersonal, log: log)
    let push = try? WebPush(keyFile: support.appendingPathComponent("vapid.key"), subject: config.vapidSubject)
    let engine = Engine(config: config, store: store, sources: sources, brain: brain, context: context, push: push, log: log)
    let feed = ReputationFeed(store: store, config: config, log: log)
    let reminders = (config.useReminders && !devNoPersonal) ? RemindersBridge(store: store, log: log) : nil
    engine.reminders = reminders
    if config.useRoboKiller { engine.robokiller = RoboKillerLookup(store: store, log: log) }
    if config.useCloudDrive && !devNoPersonal { engine.cloud = CloudDriveBridge(store: store, log: log) }

    if let i = args.firstIndex(of: "--parse-robokiller"), i + 1 < args.count {   // diagnostics
        let html = (try? String(contentsOfFile: args[i + 1], encoding: .utf8)) ?? ""
        if let r = RoboKillerLookup.parse(html) { print(r.summaryLine, "→", r.scamCategory ?? "no spam evidence") } else { print("unrecognized page") }
        exit(0)
    }
    if args.contains("--check-access") {
        for f in [sources.callHistoryPath, sources.voicemailDBPath] {
            print(FileManager.default.isReadableFile(atPath: f) ? "readable: \(f)" : "NOT readable: \(f)")
        }
        exit(0)
    }

    if args.contains("--setup") {
        // One-time, launched via LaunchServices (`open`) so macOS can show permission prompts;
        // the background agent shares this signature and inherits the grants.
        context.requestAccess()
        reminders?.requestAccess()
        log("setup: contacts=\(context.contactsStatus) calendar=\(context.calendarStatus) reminders=\(reminders?.status ?? "off")")
        exit(0)
    }

    log("ScamShield agent starting (data: \(support.path))")
    context.requestAccess()
    reminders?.refreshStatus()
    // Delivery moved to the iPhone app: remove the Reminders lists ScamShield created (once).
    if !config.useReminders && !devNoPersonal && store.get("rem.listsRemoved") == nil {
        let rb = RemindersBridge(store: store, log: log)
        if rb.authorized {
            do { let n = try rb.removeLists(); store.set("rem.listsRemoved", "1"); if n > 0 { log("reminders: removed \(n) ScamShield lists") } }
            catch { log("reminders: could not remove lists: \(error.localizedDescription)") }
        }
    }
    log("permissions: contacts=\(context.contactsStatus) calendar=\(context.calendarStatus) reminders=\(reminders?.status ?? "off")")
    // Changes made on the iPhone arrive via iCloud as EventKit change notifications.
    let ekObserver = NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: nil, queue: nil) { _ in engine.scheduleReminderSync() }

    if args.contains("--once") {
        feed.refreshIfDue(backfillDays: config.backfillDays)
        engine.ingestSync()
        let c = store.counts()
        log("counts: \(c)")
        exit(0)
    }

    engine.reclassifyIfPolicyChanged()
    let api = API(engine: engine, brain: brain, push: push, webRoot: resource("web"))
    let server = try HTTPServer(port: UInt16(config.port)) { api.handle($0) }
    server.start { log("http: \($0) on 127.0.0.1:\(config.port)") }

    // Direct Wi-Fi path for the iPhone app. The token is generated once and built into the
    // iPhone app by scripts/ios-install.sh; requests without it are rejected.
    var lanServer: HTTPServer?
    if config.useLAN, engine.cloud != nil {
        let tokenFile = support.appendingPathComponent("lan.token")
        var token = (try? String(contentsOf: tokenFile, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if token.count < 32 {
            token = (0..<32).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
            try? token.write(to: tokenFile, atomically: true, encoding: .utf8)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: tokenFile.path)
        }
        let expected = Data("Bearer \(token)".utf8)
        lanServer = try? HTTPServer(port: UInt16(config.lanPort), bonjourType: "_scamshield._tcp") { req in
            let given = Data((req.headers["authorization"] ?? "").utf8)
            // Constant-time comparison.
            guard given.count == expected.count, zip(given, expected).reduce(0, { $0 | ($1.0 ^ $1.1) }) == 0 else {
                return .error(401, "unauthorized")
            }
            switch (req.method, req.path) {
            case ("GET", "/inbox"):
                guard let data = engine.currentInbox() else { return .error(503, "inbox not ready") }
                return HTTPResponse(status: 200, headers: ["Content-Type": "application/json", "Cache-Control": "no-store"], body: data)
            case ("GET", let p) where p.hasPrefix("/audio/"):
                guard let path = engine.audioPath(voicemailID: String(p.dropFirst(7)).components(separatedBy: ".")[0]) else { return .error(404, "no audio") }
                return HTTPResponse(status: 200, headers: ["Content-Type": "video/quicktime"], body: Data(), filePath: path)
            default:
                return .error(404, "unknown")
            }
        }
        lanServer?.start { log("wifi: \($0) on port \(config.lanPort) (Bonjour _scamshield._tcp)") }
    }

    // Reputation refresh (network) on its own queue, checked hourly.
    let repQueue = DispatchQueue(label: "scamshield.reputation", qos: .utility)
    let repTimer = DispatchSource.makeTimerSource(queue: repQueue)
    repTimer.schedule(deadline: .now() + 5, repeating: 3600)
    repTimer.setEventHandler {
        let before = store.complaintStats().rows
        feed.refreshIfDue(backfillDays: config.backfillDays)
        if store.complaintStats().rows != before { engine.reclassifyNoMessageItems() }
    }
    repTimer.resume()

    // Watch Apple's stores: cheap mtime poll every 10 s, plus a full pass every 10 min.
    var lastStamp = ""
    let watchTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    watchTimer.schedule(deadline: .now(), repeating: 10)
    var ticks = 0
    watchTimer.setEventHandler {
        let stamp = sources.watchedFiles.map { f -> String in
            let a = try? FileManager.default.attributesOfItem(atPath: f)
            return "\((a?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\(a?[.size] as? Int ?? 0)"
        }.joined(separator: "|")
        ticks += 1
        if stamp != lastStamp || ticks % 60 == 0 {
            lastStamp = stamp
            engine.scheduleIngest()
        }
    }
    watchTimer.resume()

    signal(SIGTERM, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    term.setEventHandler { log("stopping"); exit(0) }
    term.resume()
    // Also reconcile Reminders every 2 minutes (covers missed change notifications).
    let remTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    remTimer.schedule(deadline: .now() + 15, repeating: 120)
    remTimer.setEventHandler { engine.scheduleReminderSync(after: 0) }
    // iPhone corrections arrive as files in iCloud Drive; check every 30 s.
    let cloudTimer = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
    cloudTimer.schedule(deadline: .now() + 5, repeating: 30)
    cloudTimer.setEventHandler { engine.scheduleCloudSync(after: 0) }
    cloudTimer.resume()
    remTimer.resume()
    withExtendedLifetime([server, repTimer, watchTimer, remTimer, cloudTimer, term, ekObserver, lanServer as Any] as [AnyObject]) { dispatchMain() }
} catch {
    log("fatal: \(error)")
    exit(1)
}
