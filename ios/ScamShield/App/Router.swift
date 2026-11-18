import Foundation
import Observation

enum AppTab: Hashable {
    case bucket(Bucket)
    case settings
}

struct ItemRoute: Hashable {
    let id: String
}

/// Selected tab and each tab's navigation stack, so notification taps can open a call.
@Observable
@MainActor
final class Router {
    static let shared = Router()

    var tab: AppTab = .bucket(.attention)
    var attentionPath: [ItemRoute] = []
    var reviewPath: [ItemRoute] = []
    var scamPath: [ItemRoute] = []
    /// Item whose Move sheet should open as soon as its detail view appears (DEBUG launch argument).
    var moveSheetItemID: String?

    init() {
        #if DEBUG
        applyDebugArguments(UserDefaults.standard)
        #endif
    }

    func path(for bucket: Bucket) -> [ItemRoute] {
        switch bucket {
        case .attention: attentionPath
        case .review: reviewPath
        case .scam: scamPath
        }
    }

    func setPath(_ path: [ItemRoute], for bucket: Bucket) {
        switch bucket {
        case .attention: attentionPath = path
        case .review: reviewPath = path
        case .scam: scamPath = path
        }
    }

    /// Shows a call's detail on top of its list, e.g. after tapping its notification.
    func open(itemID: String, in bucket: Bucket) {
        tab = .bucket(bucket)
        setPath([ItemRoute(id: itemID)], for: bucket)
    }

    #if DEBUG
    /// `-ScamShieldTab attention|review|scam|settings`, `-ScamShieldItem <id>`, `-ScamShieldMoveSheet YES`:
    /// lets screenshots and UI tests start on a given screen.
    private func applyDebugArguments(_ defaults: UserDefaults) {
        let bucket = defaults.string(forKey: "ScamShieldTab").flatMap(Bucket.init(rawValue:))
        if defaults.string(forKey: "ScamShieldTab") == "settings" {
            tab = .settings
        } else if let bucket {
            tab = .bucket(bucket)
        }
        if let itemID = defaults.string(forKey: "ScamShieldItem") {
            let target = bucket ?? .attention
            tab = .bucket(target)
            setPath([ItemRoute(id: itemID)], for: target)
            if defaults.bool(forKey: "ScamShieldMoveSheet") { moveSheetItemID = itemID }
        }
    }
    #endif
}
