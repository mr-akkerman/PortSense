// PortSense — app state: port snapshot, preferences, history and notifications.

import SwiftUI
import UserNotifications

enum Pref {
    static let menuBarMode = "menuBarMode"       // count | watts | speed | icon
    static let notifyConnect = "notifyConnect"
    static let notifySlow = "notifySlow"
    static let lang = "lang"                     // system | ru | en
    static let events = "events"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [menuBarMode: "count", notifyConnect: false, notifySlow: true, lang: "system"])
    }
}

struct LogEvent: Identifiable, Codable {
    enum Kind: String, Codable { case connected, disconnected, slow, power }
    var id = UUID()
    let date: Date
    let kind: Kind
    let text: String
}

@MainActor
final class Store: ObservableObject {
    @Published var snapshot = Snapshot()
    @Published var hoveredID: String?
    @Published var events: [LogEvent] = []
    @Published var ejectMessage: String?
    /// Area occupied by the visible panel content (SwiftUI coordinates, origin at top-left).
    var contentRect: CGRect = .zero
    var onChange: (() -> Void)?
    var openSettings: (() -> Void)?
    private var loading = false
    private var firstLoad = true

    var ports: [PortInfo] { snapshot.ports }
    var occupiedCount: Int { ports.filter(\.occupied).count }

    init() {
        if let data = UserDefaults.standard.data(forKey: Pref.events),
           let saved = try? JSONDecoder().decode([LogEvent].self, from: data) { events = saved }
        NotificationCenter.default.addObserver(forName: Ejector.didFinish, object: nil, queue: .main) { [weak self] note in
            let error = note.object as? String
            MainActor.assumeIsolated {
                self?.ejectMessage = error.map { L("Не удалось извлечь: ", "Could not eject: ") + $0 } ?? L("Диск извлечён", "Disk ejected")
                self?.refresh()
            }
        }
    }

    func refresh() {
        guard !loading else { return }
        loading = true
        Task.detached {
            let snap = Probe.snapshot()
            await MainActor.run {
                self.diff(old: self.snapshot, new: snap)
                self.snapshot = snap
                self.loading = false
                self.firstLoad = false
                self.onChange?()
            }
        }
    }

    /// Text shown next to the menu bar icon for the selected mode.
    var menuBarText: String {
        switch UserDefaults.standard.string(forKey: Pref.menuBarMode) {
        case "icon": return ""
        case "watts":
            if let a = snapshot.adapter { return "\(a.watts)\(L("Вт", "W"))" }
            let out = ports.compactMap(\.powerOutMW).reduce(0, +)
            return out > 0 ? "↑" + formatWatts(out).replacingOccurrences(of: " ", with: "") : ""
        case "speed":
            let top = ports.flatMap(\.usbDevices).filter { $0.depth == 0 }.map(\.speedBps).max() ?? 0
            return top > 0 ? formatSpeed(top).replacingOccurrences(of: " Gb/s", with: "G").replacingOccurrences(of: " Mb/s", with: "M") : ""
        default:
            return occupiedCount > 0 ? "\(occupiedCount)" : ""
        }
    }

    // MARK: History and notifications

    private func diff(old: Snapshot, new: Snapshot) {
        guard !firstLoad else { return }
        let defaults = UserDefaults.standard
        func index(_ s: Snapshot) -> [String: (PortInfo, USBDevice)] {
            var r: [String: (PortInfo, USBDevice)] = [:]
            for p in s.ports { for d in p.usbDevices { r["\(p.id)|\(d.id)|\(d.name)"] = (p, d) } }
            return r
        }
        let before = index(old), after = index(new)
        for (key, (port, dev)) in after where before[key] == nil {
            let speed = dev.speed.map { " · \($0)" } ?? ""
            log(.connected, "\(dev.name) → \(port.title)\(speed)")
            if defaults.bool(forKey: Pref.notifyConnect) {
                notify(L("Подключено: ", "Connected: ") + dev.name, "\(port.title)\(speed)")
            }
            if dev.slow {
                let text = L("\(dev.name) работает на скорости USB 2.0 (480 Мбит/с), хотя, похоже, умеет быстрее. Проверьте кабель или переходник.",
                             "\(dev.name) is running at USB 2.0 speed (480 Mb/s) but looks capable of more. Check the cable or adapter.")
                log(.slow, "\(dev.name) — \(port.title): 480 Mb/s")
                if defaults.bool(forKey: Pref.notifySlow) { notify(L("Медленное подключение", "Slow connection"), text) }
            }
        }
        for (key, (port, dev)) in before where after[key] == nil {
            log(.disconnected, "\(dev.name) ← \(port.title)")
            if defaults.bool(forKey: Pref.notifyConnect) { notify(L("Отключено: ", "Disconnected: ") + dev.name, port.title) }
        }
        // Charging
        let oldPower = Dictionary(uniqueKeysWithValues: old.ports.compactMap { p in p.powerIn.map { (p.id, $0) } })
        for p in new.ports {
            if let src = p.powerIn, oldPower[p.id] == nil {
                log(.power, L("Зарядка подключена: ", "Charger connected: ") + "\(p.title) · \(formatOption(src.active))")
            } else if p.powerIn == nil, oldPower[p.id] != nil {
                log(.power, L("Зарядка отключена: ", "Charger disconnected: ") + p.title)
            }
        }
    }

    private func log(_ kind: LogEvent.Kind, _ text: String) {
        events.insert(LogEvent(date: Date(), kind: kind, text: text), at: 0)
        if events.count > 300 { events.removeLast(events.count - 300) }
        saveEvents()
    }

    func clearEvents() { events = []; saveEvents() }

    private func saveEvents() {
        if let data = try? JSONEncoder().encode(events) { UserDefaults.standard.set(data, forKey: Pref.events) }
    }

    func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func notify(_ title: String, _ body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    /// Language changed: recompute and redraw everything.
    func languageChanged() {
        Lang.current = Lang.resolve()
        objectWillChange.send()
        onChange?()
    }
}
