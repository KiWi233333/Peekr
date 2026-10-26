import SwiftUI

/// Native `peekr://site-settings` page. Lists the permission decisions that
/// CEF's permission delegate remembers for each origin and lets the user revoke
/// them, either per site/permission or all at once.
struct SiteSettingsPageView: View {
    let permissions: SitePermissionStore
    let settings: Settings
    let filterOrigin: String?
    let onClose: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsClearAllAlert = false

    private var loc: Localized { settings.strings }

    private var normalizedFilter: String? {
        guard let filterOrigin else { return nil }
        return SitePermissionStore.normalize(filterOrigin)
    }

    private var hasAnyDecisions: Bool {
        permissions.sites.values.contains { !$0.isEmpty }
    }

    /// Sites in the order they should be rendered. With a filter, only the
    /// matching origin is kept; otherwise every origin is listed alphabetically.
    private var siteGroups: [SiteGroup] {
        let all = permissions.sites
        let origins: [String]
        if let normalizedFilter {
            origins = all.keys.filter { SitePermissionStore.normalize($0) == normalizedFilter }
        } else {
            origins = all.keys.sorted()
        }
        return origins.compactMap { origin in
            guard let decisions = all[origin], !decisions.isEmpty else { return nil }
            return SiteGroup(origin: origin, decisions: decisions)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
                .overlay(Theme.hairline)
                .padding(.horizontal, 20)

            if siteGroups.isEmpty {
                emptyState
            } else {
                siteList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .alert(loc.clearAllSitePermissions, isPresented: $showsClearAllAlert) {
            Button(loc.cancel, role: .cancel) {}
            Button(loc.clearAll, role: .destructive) { clearAll() }
        } message: {
            Text(loc.clearAllSitePermissionsMessage)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(loc.siteSettings)
                    .font(.system(size: 16, weight: .semibold))
                    .accessibilityAddTraits(.isHeader)
                if let normalizedFilter {
                    Text(normalizedFilter)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
            }

            Spacer(minLength: 8)

            if filterOrigin != nil {
                headerTextButton(
                    loc.backToAllSites,
                    symbol: "chevron.left",
                    action: onClose
                )
            }
            if hasAnyDecisions {
                if filterOrigin == nil {
                    headerTextButton(
                        loc.clearAllSitePermissions,
                        symbol: "trash",
                        action: { showsClearAllAlert = true }
                    )
                } else {
                    headerIconButton(
                        symbol: "trash",
                        label: loc.clearAllSitePermissions,
                        action: { showsClearAllAlert = true }
                    )
                }
            }
        }
        .frame(maxWidth: 760, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 12)
    }

    private func headerTextButton(
        _ title: String,
        symbol: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.primary.opacity(0.06), in: Capsule())
                .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 0.8))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.primary)
        .help(title)
        .accessibilityLabel(title)
        .fixedSize()
    }

    private func headerIconButton(
        symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Circle())
        }
        .buttonStyle(IconButtonStyle())
        .foregroundStyle(.primary)
        .help(label)
        .accessibilityLabel(label)
    }

    // MARK: - Sites

    private var siteList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                ForEach(siteGroups) { group in
                    siteCard(group)
                }
                Text(loc.sitePermissionsRememberedHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
    }

    private func siteCard(_ group: SiteGroup) -> some View {
        let ordered = sortedPermissions(group.decisions)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)

                Text(group.displayOrigin)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)

                Spacer(minLength: 8)

                Text(loc.sitePermissionCount(ordered.count))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Button {
                    forgetSite(group.origin)
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 12.5, weight: .medium))
                        .frame(width: 26, height: 26)
                        .contentShape(Circle())
                }
                .buttonStyle(IconButtonStyle())
                .help(loc.delete)
                .accessibilityLabel(loc.deleteSitePermissions(group.displayOrigin))
            }

            Divider().overlay(Theme.hairline)

            ForEach(ordered) { permission in
                permissionRow(
                    origin: group.origin,
                    permission: permission,
                    allowed: group.decisions[permission] ?? false
                )
                if permission != ordered.last {
                    Divider()
                        .overlay(Theme.hairline.opacity(0.7))
                        .padding(.leading, 24)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            .primary.opacity(0.055),
            in: RoundedRectangle(cornerRadius: Theme.popoverRowCorner, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.popoverRowCorner, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 0.8)
        )
    }

    private func permissionRow(
        origin: String,
        permission: SitePermissionStore.Permission,
        allowed: Bool
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: permission.symbolName)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)

            Text(loc.sitePermissionName(permission))
                .font(.system(size: 12))
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)

            Spacer(minLength: 6)

            Picker(
                loc.sitePermissionName(permission),
                selection: allowedBinding(
                    origin: origin,
                    permission: permission,
                    fallback: allowed
                )
            ) {
                Text(loc.allow).tag(true)
                Text(loc.deny).tag(false)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .frame(width: 126)
            .accessibilityLabel(loc.sitePermissionName(permission))

            Button {
                resetToAsk(origin: origin, permission: permission)
            } label: {
                Image(systemName: "arrow.uturn.backward")
                    .font(.system(size: 11.5, weight: .medium))
                    .frame(width: 24, height: 24)
                    .contentShape(Circle())
            }
            .buttonStyle(IconButtonStyle())
            .foregroundStyle(.secondary)
            .help(loc.resetToAsk)
            .accessibilityLabel(loc.resetToAsk)
        }
        .padding(.vertical, 6)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "hand.raised")
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.tertiary)
                .accessibilityHidden(true)

            Text(filterOrigin == nil ? loc.noSitePermissions : loc.noPermissionsForSite)
                .font(.system(size: 14, weight: .semibold))
                .multilineTextAlignment(.center)

            Text(loc.sitePermissionsRememberedHint)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 380)
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func sortedPermissions(
        _ decisions: [SitePermissionStore.Permission: Bool]
    ) -> [SitePermissionStore.Permission] {
        SitePermissionStore.Permission.allCases.filter { decisions[$0] != nil }
    }

    private func allowedBinding(
        origin: String,
        permission: SitePermissionStore.Permission,
        fallback: Bool
    ) -> Binding<Bool> {
        Binding(
            get: { permissions.decision(origin: origin, permission: permission) ?? fallback },
            set: { newValue in
                withAnimation(reduceMotion ? nil : Motion.controlFeedback) {
                    permissions.remember(
                        origin: origin,
                        permission: permission,
                        allowed: newValue
                    )
                }
            }
        )
    }

    /// `SitePermissionStore` has no per-permission removal API, so returning one
    /// row to "ask" means forgetting the origin and re-remembering everything
    /// else. Decision keys written by a newer build are not exposed by `sites`
    /// and would not survive this rebuild — a `forget(origin:permission:)` store
    /// method is the proper long-term fix.
    private func resetToAsk(
        origin: String,
        permission: SitePermissionStore.Permission
    ) {
        guard let decisions = permissions.sites[origin],
              decisions[permission] != nil
        else { return }

        var remaining = decisions
        remaining.removeValue(forKey: permission)

        withAnimation(reduceMotion ? nil : Motion.controlFeedback) {
            permissions.forget(origin: origin)
            for (remainingPermission, allowed) in remaining {
                permissions.remember(
                    origin: origin,
                    permission: remainingPermission,
                    allowed: allowed
                )
            }
        }
    }

    private func forgetSite(_ origin: String) {
        withAnimation(reduceMotion ? nil : Motion.controlFeedback) {
            permissions.forget(origin: origin)
        }
    }

    private func clearAll() {
        withAnimation(reduceMotion ? nil : Motion.controlFeedback) {
            permissions.forgetAll()
        }
    }
}

// MARK: - Models

private struct SiteGroup: Identifiable {
    /// Stored key; the store writes normalized origins, so this normally equals
    /// `displayOrigin` already.
    let origin: String
    let decisions: [SitePermissionStore.Permission: Bool]

    var id: String { origin }
    var displayOrigin: String { SitePermissionStore.normalize(origin) }
}

private extension SitePermissionStore.Permission {
    /// `midi` and `cursor` are not SF Symbols; `pianokeys`/`cursorarrow` are
    /// their closest stock equivalents.
    var symbolName: String {
        switch self {
        case .camera: return "camera"
        case .microphone: return "mic"
        case .geolocation: return "location"
        case .notifications: return "bell"
        case .clipboard: return "clipboard"
        case .midi: return "pianokeys"
        case .pointerLock: return "cursorarrow"
        case .storageAccess: return "externaldrive"
        case .sensors: return "sensor"
        case .windowManagement: return "rectangle"
        case .downloads: return "arrow.down"
        case .other: return "questionmark"
        }
    }
}

