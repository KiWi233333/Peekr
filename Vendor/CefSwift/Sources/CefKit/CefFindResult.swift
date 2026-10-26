import Foundation

/// One find-in-page result reported by CEF's `cef_find_handler_t`.
public struct CefFindResult: Sendable, Equatable {
    /// Identifier of the search session that produced this update.
    public var identifier: Int
    /// Number of matches currently identified.
    public var matches: Int
    /// 1-based ordinal of the active match; 0 when there is no match.
    public var activeMatchOrdinal: Int
    /// Whether CEF has finished reporting this session's result.
    public var finalUpdate: Bool

    public init(identifier: Int, matches: Int, activeMatchOrdinal: Int, finalUpdate: Bool) {
        self.identifier = identifier
        self.matches = matches
        self.activeMatchOrdinal = activeMatchOrdinal
        self.finalUpdate = finalUpdate
    }
}
