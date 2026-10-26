import Foundation

/// Coordinates CEF-backed cookie/HTTP-cache clearing across request contexts.
///
/// CEF only exposes whole-store deletion: `delete_cookies` removes every cookie
/// and `clear_http_cache` clears the complete cache. Time ranges therefore only
/// apply to data Peekr owns (history, downloads, permissions, zoom).
@MainActor
public enum CefBrowsingData {
    /// Clears the requested CEF-backed data for every profile, then calls
    /// `completion` exactly once on the main actor.
    ///
    /// A rejected (`false`) delete/flush call counts as finished with failure:
    /// CEF will never deliver a callback for it, so waiting would hang the
    /// caller forever. The same applies when a profile has no cookie manager.
    public static func clear(
        profiles: [CefProfile],
        cookies: Bool,
        cache: Bool,
        completion: @escaping () -> Void
    ) {
        guard !profiles.isEmpty else {
            completion()
            return
        }

        var remaining = profiles.count
        let profileFinished = {
            remaining -= 1
            if remaining == 0 { completion() }
        }
        for profile in profiles {
            clear(
                profile: profile,
                cookies: cookies,
                cache: cache,
                completion: profileFinished
            )
        }
    }

    private static func clear(
        profile: CefProfile,
        cookies: Bool,
        cache: Bool,
        completion: @escaping () -> Void
    ) {
        var isFinished = false
        let finish = {
            guard !isFinished else { return }
            isFinished = true
            completion()
        }
        let clearCache = {
            if cache {
                profile.clearHTTPCache(completion: finish)
            } else {
                finish()
            }
        }

        guard cookies, let manager = profile.cookieManager() else {
            clearCache()
            return
        }
        let accepted = manager.deleteAllCookies { _ in
            // A rejected flush also means CEF will never call back; treat it as
            // a completed (failed) cookie clear and move on to the cache.
            if !manager.flush(completion: finish) {
                finish()
            }
        }
        if !accepted { clearCache() }
    }
}
