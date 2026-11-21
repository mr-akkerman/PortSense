// PortSense — the popover panel: a diagram of the Mac with its ports and details for the selected one.

import SwiftUI

let rowWidth: CGFloat = 196
let rowHeight: CGFloat = 58
let rowSpacing: CGFloat = 8
let macWidth: CGFloat = 132
let columnGap: CGFloat = 10
let panelEdge: CGFloat = 14   // room for the shadow
let panelHeight: CGFloat = 660

/// Glass backdrop: Liquid Glass on macOS 26, a material on earlier systems.
struct Glass: ViewModifier {
    var radius: CGFloat
    var tint: Color? = nil
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(tint.map { .regular.tint($0) } ?? .regular,
                                in: RoundedRectangle(cornerRadius: radius, style: .continuous))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(.white.opacity(0.15), lineWidth: 1))
        }
    }
}

extension View {
    func glass(_ radius: CGFloat, tint: Color? = nil) -> some View { modifier(Glass(radius: radius, tint: tint)) }
}

// MARK: - Port layout on the chassis

struct PortLayout {
    var left: [PortInfo] = []
    var right: [PortInfo] = []
    var showMac = false

    /// Laptops: MagSafe and the first USB-C ports on the left (top = furthest from the user), HDMI/SD and the last USB-C on the right.
    /// Desktop Macs: two plain columns without the chassis diagram.
    init(_ snap: Snapshot) {
        let ports = snap.ports
        let usbc = ports.filter { $0.kind == .usbc }
        let magsafe = ports.filter { $0.kind == .magsafe }
        let hdmi = ports.filter { $0.kind == .hdmi }
        let sd = ports.filter { $0.kind == .sd }
        let other = ports.filter { $0.kind == .other }
        if snap.isLaptop {
            showMac = true
            if (!hdmi.isEmpty || !sd.isEmpty) && usbc.count >= 3 {
                left = magsafe + usbc.prefix(2)
                right = hdmi + usbc.dropFirst(2) + sd
            } else {
                left = magsafe + usbc
                right = hdmi + sd
            }
            right += other
        } else {
            let all = ports
            let half = (all.count + 1) / 2
            left = Array(all.prefix(half))
            right = Array(all.dropFirst(half))
        }
    }

    var rows: Int { max(left.count, right.count, 1) }
    var columnsHeight: CGFloat { CGFloat(rows) * (rowHeight + rowSpacing) - rowSpacing }
    var width: CGFloat {
        var w = rowWidth
        if showMac { w += columnGap + macWidth }
        if !right.isEmpty { w += columnGap + rowWidth }
        return w
    }

    /// Placement caption, e.g. "left · rear".
    func place(of port: PortInfo) -> String? {
        guard showMac else { return nil }
        let isLeft = left.contains { $0.id == port.id }
        let column = isLeft ? left : right
        let side = isLeft ? L("слева", "left") : L("справа", "right")
        guard column.count > 1, let i = column.firstIndex(where: { $0.id == port.id }) else { return side }
        if i == 0 { return side + " · " + L("дальний", "rear") }
        if i == column.count - 1 { return side + " · " + L("ближний", "front") }
        return side + " · " + L("средний", "middle")
    }
}

// MARK: - Port row

struct PortGlyph: View {
    let port: PortInfo
    var body: some View {
        let color: Color = port.occupied ? .green : .secondary.opacity(0.6)
        Group {
            switch port.kind {
            case .usbc, .other:
                ZStack {
                    Capsule().stroke(color, lineWidth: 2).frame(width: 34, height: 13)
                    Capsule().fill(color).frame(width: 18, height: 3.5)
                }
            case .magsafe: Image(systemName: "bolt.fill").font(.system(size: 17)).foregroundStyle(color)
            case .hdmi: Image(systemName: "tv").font(.system(size: 16)).foregroundStyle(color)
            case .sd: Image(systemName: "sdcard").font(.system(size: 17)).foregroundStyle(color)
            }
        }
        .frame(width: 38)
        .shadow(color: port.occupied ? .green.opacity(0.7) : .clear, radius: 6)
    }
}

struct PortRow: View {
    let port: PortInfo
    let place: String?
    let hovered: Bool

    var body: some View {
        HStack(spacing: 8) {
            PortGlyph(port: port)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(port.title).font(.subheadline.weight(.semibold))
                    if port.hasSlowDevice {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                    }
                }
                Text(port.occupied ? (port.deviceName ?? L("Занят", "In use")) : L("Свободен", "Empty"))
                    .font(.caption)
                    .foregroundStyle(port.occupied ? .primary : .secondary)
                    .lineLimit(1)
                if let badge = port.badge {
                    Text(badge).font(.caption2.monospacedDigit().weight(.medium))
                        .foregroundStyle(port.hasSlowDevice ? .orange : .green)
                        .lineLimit(1)
                } else if let place {
                    Text(place).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(width: rowWidth, height: rowHeight)
        .glass(14, tint: hovered ? Color.accentColor.opacity(0.35) : nil)
        .scaleEffect(hovered ? 1.03 : 1)
        .animation(.spring(response: 0.25, dampingFraction: 0.7), value: hovered)
    }
}

// MARK: - Chassis diagram

struct MacShape: View {
    let layout: PortLayout
    let hoveredID: String?

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.white.opacity(0.05))
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.white.opacity(0.35), lineWidth: 1.5)
            // Keyboard and trackpad, so it is obvious which side is the front.
            VStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.2), lineWidth: 1)
                    .frame(width: macWidth - 34, height: max(layout.columnsHeight * 0.36, 40))
                RoundedRectangle(cornerRadius: 4).stroke(.white.opacity(0.2), lineWidth: 1)
                    .frame(width: macWidth - 74, height: max(layout.columnsHeight * 0.22, 26))
            }
            pips(layout.left, x: 1)
            pips(layout.right, x: macWidth - 1)
        }
        .frame(width: macWidth, height: layout.columnsHeight)
        .glass(12)
    }

    private func pips(_ ports: [PortInfo], x: CGFloat) -> some View {
        ForEach(Array(ports.enumerated()), id: \.element.id) { i, port in
            Capsule()
                .fill(port.id == hoveredID ? Color.accentColor : (port.occupied ? Color.green : Color.white.opacity(0.45)))
                .frame(width: 5, height: port.id == hoveredID ? 26 : 18)
                .shadow(color: port.occupied ? .green.opacity(0.8) : .clear, radius: 4)
                .position(x: x, y: CGFloat(i) * (rowHeight + rowSpacing) + rowHeight / 2)
        }
    }
}

// MARK: - Port details

struct PortDetails: View {
    let port: PortInfo
    let place: String?
    let adapter: Adapter?
    @ObservedObject var store: Store

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Circle().fill(port.occupied ? Color.green : Color.secondary).frame(width: 8, height: 8)
                Text("\(port.title) — \(port.occupied ? L("занят", "in use") : L("свободен", "empty"))").font(.headline)
                Spacer()
                if let place { Text(place).font(.caption).foregroundStyle(.secondary) }
            }

            if !port.occupied && port.powerIn == nil {
                Text(L("Ничего не подключено", "Nothing connected")).foregroundStyle(.secondary)
            }
            if !port.transports.isEmpty { row(L("Линии", "Transports"), port.transports.joined(separator: ", ")) }

            if let src = port.powerIn {
                row(L("Зарядка", "Charging"), formatOption(src.active))
                if let adapter { row(L("Адаптер", "Adapter"), adapter.name) }
                if src.options.count > 1 {
                    row(L("Профили", "Profiles"), src.options.map { "\($0.mV / 1000)\(L("В", "V"))" }.joined(separator: " / "))
                }
            }
            if let out = port.powerOutMW { row(L("Отдаёт устройству", "Supplying device"), formatWatts(out)) }

            if port.connected && port.kind == .usbc {
                row(L("Кабель", "Cable"), (port.opticalCable ? L("оптический", "optical") : (port.activeCable ? L("активный", "active") : L("пассивный", "passive")))
                    + (port.hasEMarker ? L(", с чипом e-marker", ", e-marked") : ""))
                ForEach(port.cableDetails, id: \.self) { Text($0).font(.caption).foregroundStyle(.secondary) }
            }
            if port.displayActive || !port.displays.isEmpty {
                row(L("Видеосигнал", "Video link"), port.dpLink ?? "DisplayPort")
                ForEach(port.displays, id: \.self) { Text("• \($0)").font(.callout) }
            }
            if let tb = port.thunderboltSpeed {
                row("Thunderbolt", tb)
                ForEach(port.thunderboltDevices, id: \.self) { Text("• \($0)").font(.callout) }
            }

            if !port.usbDevices.isEmpty {
                Divider().padding(.vertical, 2)
                ForEach(port.usbDevices) { dev in device(dev) }
            }
            if let msg = store.ejectMessage, port.kind == .usbc {
                Text(msg).font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(16)
    }

    private func device(_ dev: USBDevice) -> some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(dev.name).font(.callout.bold())
                if let speed = dev.speed {
                    Text("\(speed) · \(speedClass(speed))").font(.callout.monospacedDigit())
                }
                if let mA = dev.powerMA, mA > 0 {
                    Text(L("Запрошено питание: ", "Power requested: ") + "\(formatWatts(mA * 5)) (\(mA) \(L("мА", "mA")))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if dev.slow {
                    Label(L("Похоже, устройство умеет быстрее: проверьте кабель или переходник",
                            "Device looks capable of more: check the cable or adapter"),
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            if let bsd = dev.bsdDisk {
                Button { Ejector.eject(bsd: bsd) } label: {
                    Label(L("Извлечь", "Eject"), systemImage: "eject.fill")
                }
                .controlSize(.small)
            }
        }
        .padding(.leading, CGFloat(dev.depth) * 14)
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit().multilineTextAlignment(.trailing)
        }
        .font(.callout)
    }
}

// MARK: - Panel

struct PanelView: View {
    @ObservedObject var store: Store

    var body: some View {
        let layout = PortLayout(store.snapshot)
        VStack(alignment: .leading, spacing: 10) {
            header(width: layout.width)

            HStack(alignment: .top, spacing: columnGap) {
                column(layout.left, layout)
                if layout.showMac { MacShape(layout: layout, hoveredID: store.hoveredID) }
                if !layout.right.isEmpty { column(layout.right, layout) }
            }

            if let port = store.ports.first(where: { $0.id == store.hoveredID }) {
                PortDetails(port: port, place: layout.place(of: port),
                            adapter: port.powerIn != nil ? store.snapshot.adapter : nil, store: store)
                    .frame(width: layout.width)
                    .transition(.opacity.combined(with: .scale(scale: 0.97, anchor: .top)))
                    .id(store.hoveredID)
            }
        }
        .padding(panelEdge)
        .animation(.easeOut(duration: 0.15), value: store.hoveredID)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { store.contentRect = g.frame(in: .global) }
                .onChange(of: g.size) { store.contentRect = g.frame(in: .global) }
        })
        .frame(width: layout.width + panelEdge * 2, height: panelHeight, alignment: .topLeading)
    }

    private func header(width: CGFloat) -> some View {
        HStack(spacing: 8) {
            Text("PortSense").font(.subheadline.weight(.semibold))
            if let a = store.snapshot.adapter {
                Label("\(a.watts) \(L("Вт", "W"))", systemImage: "bolt.fill").font(.caption).foregroundStyle(.green)
            }
            let out = store.ports.compactMap(\.powerOutMW).reduce(0, +)
            if out > 0 {
                Label(formatWatts(out), systemImage: "arrow.up.right").font(.caption).foregroundStyle(.secondary)
                    .help(L("Суммарно отдаётся устройствам", "Total supplied to devices"))
            }
            Spacer()
            Button { store.openSettings?() } label: { Image(systemName: "gearshape") }
                .buttonStyle(.plain)
                .help(L("Настройки", "Settings"))
        }
        .padding(.horizontal, 12)
        .frame(width: width, height: 32)
        .glass(12)
    }

    private func column(_ ports: [PortInfo], _ layout: PortLayout) -> some View {
        VStack(spacing: rowSpacing) {
            ForEach(ports) { port in
                PortRow(port: port, place: layout.place(of: port), hovered: store.hoveredID == port.id)
                    // Selection is sticky: it stays until another port is hovered, otherwise the buttons in the details would be unreachable.
                    .onHover { inside in if inside { store.hoveredID = port.id } }
            }
        }
        .frame(width: rowWidth, alignment: .top)
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var store: Store
    @AppStorage(Pref.menuBarMode) private var menuBarMode = "count"
    @AppStorage(Pref.notifyConnect) private var notifyConnect = false
    @AppStorage(Pref.notifySlow) private var notifySlow = true
    @AppStorage(Pref.lang) private var lang = "system"
    @State private var loginEnabled = LoginItem.enabled

    var body: some View {
        TabView {
            general.tabItem { Label(L("Основные", "General"), systemImage: "gearshape") }
            history.tabItem { Label(L("Журнал", "History"), systemImage: "clock") }
        }
        .frame(width: 460, height: 380)
        .padding(12)
    }

    private var general: some View {
        Form {
            Picker(L("В строке меню", "Menu bar shows"), selection: $menuBarMode) {
                Text(L("Число занятых портов", "Number of ports in use")).tag("count")
                Text(L("Мощность зарядки", "Charging power")).tag("watts")
                Text(L("Скорость самого быстрого устройства", "Fastest device speed")).tag("speed")
                Text(L("Только значок", "Icon only")).tag("icon")
            }
            .onChange(of: menuBarMode) { store.onChange?() }

            Picker(L("Язык", "Language"), selection: $lang) {
                Text(L("Как в системе", "System")).tag("system")
                Text("Русский").tag("ru")
                Text("English").tag("en")
            }
            .onChange(of: lang) { store.languageChanged() }

            Toggle(L("Запускать при входе в систему", "Launch at login"), isOn: Binding(
                get: { loginEnabled },
                set: { LoginItem.set($0); loginEnabled = LoginItem.enabled }))

            Section(L("Уведомления", "Notifications")) {
                Toggle(L("Предупреждать о медленном подключении", "Warn about slow connections"), isOn: $notifySlow)
                Toggle(L("Сообщать о подключении и отключении устройств", "Notify when devices connect or disconnect"), isOn: $notifyConnect)
            }
            .onChange(of: notifySlow) { if notifySlow { store.requestNotificationPermission() } }
            .onChange(of: notifyConnect) { if notifyConnect { store.requestNotificationPermission() } }
        }
        .formStyle(.grouped)
    }

    private var history: some View {
        VStack(alignment: .leading, spacing: 8) {
            if store.events.isEmpty {
                Spacer()
                Text(L("Пока пусто. Здесь появятся подключения и отключения устройств.",
                       "Nothing yet. Device connections and disconnections will appear here."))
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                List(store.events) { e in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: icon(e.kind)).foregroundStyle(color(e.kind)).frame(width: 16)
                        Text(e.text).font(.callout)
                        Spacer()
                        Text(e.date.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    Spacer()
                    Button(L("Очистить журнал", "Clear history")) { store.clearEvents() }
                }
            }
        }
        .padding(8)
    }

    private func icon(_ k: LogEvent.Kind) -> String {
        switch k {
        case .connected: return "plus.circle.fill"
        case .disconnected: return "minus.circle"
        case .slow: return "exclamationmark.triangle.fill"
        case .power: return "bolt.fill"
        }
    }

    private func color(_ k: LogEvent.Kind) -> Color {
        switch k {
        case .connected: return .green
        case .disconnected: return .secondary
        case .slow: return .orange
        case .power: return .yellow
        }
    }
}
