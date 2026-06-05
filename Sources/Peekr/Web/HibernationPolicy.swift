import Foundation

/// One tab's hibernation-relevant state, as the policy sees it. Pure data: the
/// `WebViewManager` fills these in from its live engines, so the policy itself
/// never touches AppKit/WebKit and stays unit-testable.
struct HibernationCandidate {
    let id: UUID
    /// When the tab was last the foreground page — the idle clock starts here.
    let lastActiveAt: Date
    /// The foreground tab right now — never hibernated.
    let isActive: Bool
    /// User pinned it awake / allowlisted — never hibernated.
    let keepAwake: Bool
    /// Audible media is playing — never hibernated, matching Chrome/Edge so a
    /// background music tab isn't cut off mid-track.
    let isAudible: Bool
    /// Already suspended — skip so the sweep is idempotent.
    let isAsleep: Bool
}

/// Decides which background tabs to *fully* hibernate (tear down the web process,
/// not just pause) once they've been idle past a threshold. Pure and
/// time-injectable so the rule is testable; the manager applies the result by
/// discarding each returned tab's engine, and recreates it lazily on next
/// activation. Modeled on Chrome/Edge "sleeping tabs": discard after idle, with
/// exceptions for the active tab, audible media, and kept-awake tabs.
///
/// This covers only the *automatic* path. Manual sleep/wake (the bindable
/// shortcut) is a direct user command and doesn't consult the policy.
struct HibernationPolicy {
    /// Idle time before a background tab becomes eligible. `0` disables
    /// auto-hibernation entirely (manual sleep still works).
    var idleThreshold: TimeInterval

    /// The ids that should hibernate as of `now`, in input order. Empty when
    /// auto-hibernation is off.
    func tabsToHibernate(_ candidates: [HibernationCandidate], now: Date) -> [UUID] {
        guard idleThreshold > 0 else { return [] }
        return candidates.filter { shouldHibernate($0, now: now) }.map(\.id)
    }

    func shouldHibernate(_ c: HibernationCandidate, now: Date) -> Bool {
        guard !c.isActive, !c.keepAwake, !c.isAudible, !c.isAsleep else { return false }
        return now.timeIntervalSince(c.lastActiveAt) >= idleThreshold
    }
}
