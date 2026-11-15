import AppKit
import ApplicationServices

/// Windows 11 snap groups: windows placed together through Snap Assist (one snapped, the others picked for the
/// rest of the layout) form a group. Hovering a taskbar app with a window in a group shows the group next to its
/// window thumbnails; clicking it brings every window of the group back together. A window leaves its group once
/// it is no longer where it was snapped (dragged away, resized, maximized, closed); a group of one is gone.
/// Kept in memory only, like macOS window numbers.
@MainActor
final class SnapGroups {
    static let shared = SnapGroups()

    struct Member {
        let pid: pid_t
        let element: AXUIElement
        let id: CGWindowID
        let zone: CGRect           // unit rect of the work area
    }

    struct Group: Identifiable {
        let id = UUID()
        var members: [Member]
        let workArea: CGRect       // AX coordinates
        let display: CGDirectDisplayID
    }

    private(set) var groups: [Group] = []
    /// The group Snap Assist is filling right now.
    private var forming: UUID?

    // MARK: Forming (from SnapAssist)

    /// Snap Assist opened for a window that was just snapped into `zone`.
    func assistStarted(first: WindowSnap.Target, zone: CGRect, workArea: CGRect) {
        forming = nil
        pending = Member(pid: first.pid, element: first.element, id: first.id, zone: zone)
        pendingWorkArea = workArea
    }
    private var pending: Member?
    private var pendingWorkArea: CGRect = .zero

    /// A window picked in Snap Assist went into `zone`: it joins the first window's group.
    func assistPicked(_ t: WindowSnap.Target, zone: CGRect) {
        let m = Member(pid: t.pid, element: t.element, id: t.id, zone: zone)
        if let fid = forming, groups.contains(where: { $0.id == fid }) {
            remove(windowID: t.id)
            if let j = groups.firstIndex(where: { $0.id == fid }) { groups[j].members.append(m) }
        } else if let first = pending {
            remove(windowID: first.id)
            remove(windowID: t.id)
            let display = Displays.screen(forAX: pendingWorkArea).map(Displays.id) ?? 0
            let g = Group(members: [first, m], workArea: pendingWorkArea, display: display)
            groups.append(g)
            forming = g.id
            pending = nil
        }
        if let g = groups.first(where: { $0.id == forming }) {
            Log.write("snap groups: group of \(g.members.count) (\(g.members.map(\.id))), \(groups.count) group(s)")
        }
    }

    func assistEnded() {
        forming = nil
        pending = nil
    }

    private func remove(windowID id: CGWindowID) {
        for i in groups.indices { groups[i].members.removeAll { $0.id == id } }
        groups.removeAll { $0.members.count < 2 }
    }

    // MARK: Reading

    /// Still-valid groups with a window among `ids` (members that moved out of their zone are dropped first).
    func groups(containing ids: Set<CGWindowID>) -> [Group] {
        prune()
        return groups.filter { g in g.members.contains { ids.contains($0.id) } }
    }

    private func prune() {
        let before = groups.map(\.members.count)
        for i in groups.indices {
            groups[i].members.removeAll { m in
                guard let f = AX.frame(m.element), AX.windowID(m.element) == m.id else { return true }
                // Minimized windows keep their frame; either way it must still be the one we snapped there.
                return WindowSnap.shared.snappedZone(m.id, f) != m.zone
            }
        }
        groups.removeAll { $0.members.count < 2 }
        if groups.map(\.members.count) != before {
            Log.write("snap groups: pruned to \(groups.map(\.members.count))")
        }
    }

    // MARK: Restoring

    /// Brings every window of the group forward; `focus` (the hovered app's window) ends up in front with the
    /// keyboard focus, the way Windows focuses the window of the taskbar app you hovered.
    func restore(_ group: Group, focus: CGWindowID?) {
        let ordered = group.members.filter { $0.id != focus } + group.members.filter { $0.id == focus }
        for m in ordered {
            NSRunningApplication(processIdentifier: m.pid)?.unhide()
            if AX.isMinimized(m.element) { AX.setMinimized(m.element, false) }
        }
        for m in ordered { AX.focus(pid: m.pid, window: m.element) }
        Log.write("snap groups: restored \(group.members.map(\.id)), focus \(focus.map(String.init) ?? "-")")
    }
}
