// PortSense — model and port data collection straight from IORegistry.

import Foundation
import IOKit
import DiskArbitration

// MARK: - Language

enum Lang {
    static var current: String = resolve()
    static func resolve() -> String {
        let s = UserDefaults.standard.string(forKey: "lang") ?? "system"
        if s == "ru" || s == "en" { return s }
        return (Locale.preferredLanguages.first ?? "en").hasPrefix("ru") ? "ru" : "en"
    }
}

/// A string in the current interface language.
func L(_ ru: String, _ en: String) -> String { Lang.current == "ru" ? ru : en }

// MARK: - Model

enum PortKind: String { case usbc, magsafe, hdmi, sd, other }

struct USBDevice: Identifiable {
    let id: String            // locationID in hex
    let name: String
    let vendor: String?
    let speedBps: Int
    let powerMA: Int?
    let depth: Int            // 0 — connected directly, >0 — behind a hub
    let bcdUSB: Int
    let deviceClass: Int
    let bsdDisk: String?      // "disk4" when the device is a storage drive

    var speed: String? { speedBps > 0 ? formatSpeed(speedBps) : nil }

    /// The device reports USB 2.1+ (which is how USB 3 devices present themselves on a slow link)
    /// yet runs at 480 Mb/s. Hubs are excluded: their USB 2 half always looks like this.
    var slow: Bool { speedBps == 480_000_000 && bcdUSB >= 0x0210 && deviceClass != 9 }
}

struct PowerOption { let mV: Int; let mA: Int; let mW: Int }

struct PowerSource {
    let name: String
    let active: PowerOption
    let options: [PowerOption]
}

struct PortInfo: Identifiable {
    let id: String            // "usbc-1", "magsafe-1" …
    let kind: PortKind
    let number: Int
    var connected = false
    var transports: [String] = []
    var transportProduct: String?
    var usb3Provisioned = false
    var displayActive = false
    var dpLink: String?
    var displays: [String] = []
    var activeCable = false
    var opticalCable = false
    var cableDetails: [String] = []
    var hasEMarker = false
    var usbDevices: [USBDevice] = []
    var thunderboltSpeed: String?
    var thunderboltDevices: [String] = []
    var powerIn: PowerSource?
    var powerOutMW: Int?

    var title: String {
        switch kind {
        case .usbc: return "USB-C \(number)"
        case .magsafe: return "MagSafe"
        case .hdmi: return "HDMI"
        case .sd: return L("SD-карта", "SD Card")
        case .other: return L("Порт", "Port") + " \(number)"
        }
    }

    var occupied: Bool { connected || !usbDevices.isEmpty }

    /// What to show on the card as the name of the connected device.
    var deviceName: String? {
        guard occupied else { return nil }
        if let d = usbDevices.first(where: { $0.depth == 0 }) { return d.name }
        if let t = thunderboltDevices.first { return t }
        if let d = displays.first { return d }
        if let p = transportProduct { return p }
        if powerIn != nil { return L("Зарядка", "Charger") }
        if kind == .sd { return L("Карта вставлена", "Card inserted") }
        return nil
    }

    /// Short text for the badge on the card.
    var badge: String? {
        if let tb = thunderboltSpeed { return tb }
        if let direct = usbDevices.first(where: { $0.depth == 0 })?.speed { return direct }
        if let p = powerIn { return formatWatts(p.active.mW) }
        if displayActive { return dpLink ?? "DisplayPort" }
        return nil
    }

    var hasSlowDevice: Bool { usbDevices.contains { $0.slow } }
}

struct Adapter { let name: String; let watts: Int }

struct Snapshot {
    var ports: [PortInfo] = []
    var adapter: Adapter?
    var isLaptop = false
}

// MARK: - Formatting

func formatSpeed(_ bps: Int) -> String {
    if bps >= 1_000_000_000 {
        let g = Double(bps) / 1e9
        return (g == g.rounded() ? String(Int(g)) : String(format: "%.1f", g)) + " Gb/s"
    }
    let m = Double(bps) / 1e6
    return (m == m.rounded() ? String(Int(m)) : String(format: "%.1f", m)) + " Mb/s"
}

func formatWatts(_ mW: Int) -> String {
    let w = Double(mW) / 1000
    let s = w >= 20 || w == w.rounded() ? String(Int(w.rounded())) : String(format: "%.1f", w)
    return s + " " + L("Вт", "W")
}

func formatOption(_ o: PowerOption) -> String {
    let v = Double(o.mV) / 1000, a = Double(o.mA) / 1000
    let vs = v == v.rounded() ? String(Int(v)) : String(format: "%.1f", v)
    return "\(vs) \(L("В", "V")) × \(String(format: "%.2f", a)) \(L("А", "A")) · \(formatWatts(o.mW))"
}

/// Human-readable standard name for a link speed.
func speedClass(_ speed: String) -> String {
    let s = speed.lowercased()
    if s.hasPrefix("1.5 mb") { return "USB 1.x Low Speed" }
    if s.hasPrefix("12 mb") { return "USB 1.x Full Speed" }
    if s.hasPrefix("480 mb") { return "USB 2.0 High Speed" }
    if s.hasPrefix("5 gb") { return "USB 3.x Gen 1" }
    if s.hasPrefix("10 gb") { return "USB 3.x Gen 2" }
    if s.hasPrefix("20 gb") { return "USB 3.2 Gen 2×2 / USB4" }
    if s.contains("40 gb") { return "Thunderbolt 3/4 / USB4" }
    if s.contains("80 gb") || s.contains("120 gb") { return "Thunderbolt 5" }
    return ""
}

// MARK: - IORegistry

enum IO {
    static func props(_ e: io_registry_entry_t) -> [String: Any] {
        var cf: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(e, &cf, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let d = cf?.takeRetainedValue() as? [String: Any] else { return [:] }
        return d
    }

    static func name(_ e: io_registry_entry_t) -> String {
        var buf = [CChar](repeating: 0, count: 128)
        IORegistryEntryGetName(e, &buf)
        return String(cString: buf)
    }

    static func children(_ e: io_registry_entry_t, _ body: (io_registry_entry_t) -> Void) {
        var it: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(e, kIOServicePlane, &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        while case let c = IOIteratorNext(it), c != 0 { body(c); IOObjectRelease(c) }
    }

    static func services(_ matching: CFDictionary?, _ body: (io_registry_entry_t) -> Void) {
        var it: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &it) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(it) }
        while case let s = IOIteratorNext(it), s != 0 { body(s); IOObjectRelease(s) }
    }

    /// Finds a whole disk (IOMedia, Whole) below a device and returns its BSD name.
    static func wholeDisk(under e: io_registry_entry_t, depth: Int = 0) -> String? {
        guard depth < 14 else { return nil }
        var found: String?
        children(e) { c in
            guard found == nil else { return }
            if IOObjectConformsTo(c, "IOMedia") != 0 {
                let p = props(c)
                if p["Whole"] as? Bool == true, let bsd = p["BSD Name"] as? String { found = bsd; return }
            }
            found = wholeDisk(under: c, depth: depth + 1)
        }
        return found
    }
}

// MARK: - Data collection

enum Probe {
    static func run(_ path: String, _ args: [String]) -> Data? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return data
    }

    static func snapshot() -> Snapshot {
        var snap = Snapshot()
        var ports: [String: PortInfo] = [:]

        // 1. Every physical receptacle: each one carries a PortTypeDescription.
        IO.services([kIOPropertyExistsMatchKey: "PortTypeDescription"] as CFDictionary) { e in
            let p = IO.props(e)
            guard p["BuiltIn"] as? Bool ?? true,
                  let type = p["PortTypeDescription"] as? String,
                  let number = p["PortNumber"] as? Int else { return }
            let kind: PortKind
            switch type {
            case "USB-C": kind = .usbc
            case let t where t.hasPrefix("MagSafe"): kind = .magsafe
            case "HDMI": kind = .hdmi
            case "SD Card": kind = .sd
            default: kind = .other
            }
            var port = PortInfo(id: "\(kind.rawValue)-\(number)", kind: kind, number: number)
            port.connected = (p["ConnectionActive"] as? Bool ?? false) || (p["Card Present"] as? Bool ?? false)
            port.transports = (p["TransportsActive"] as? [String] ?? []).filter { $0 != "CC" }
            port.usb3Provisioned = (p["TransportsProvisioned"] as? [String] ?? []).contains("USB3")
            port.activeCable = p["ActiveCable"] as? Bool ?? false
            port.opticalCable = p["OpticalCable"] as? Bool ?? false

            IO.children(e) { c in
                let cp = IO.props(c)
                switch IO.name(c) {
                case "USB2", "USB3":
                    if cp["Active"] as? Bool == true, port.transportProduct == nil {
                        port.transportProduct = cp["Product"] as? String
                    }
                case "DisplayPort":
                    if cp["Active"] as? Bool == true {
                        port.displayActive = true
                        if let rate = cp["LinkRateDescription"] as? String, rate != "No Link" {
                            let lanes = cp["LaneCount"] as? Int ?? 0
                            port.dpLink = lanes > 0 ? "\(rate) × \(lanes)" : rate
                        }
                    }
                case "CC":
                    // SOP'/SOP'' components are the e-marker chip inside the cable itself.
                    IO.children(c) { comp in
                        let n = IO.name(comp)
                        guard n != "SOP" else { return }
                        port.hasEMarker = true
                        for (k, v) in IO.props(comp).sorted(by: { $0.key < $1.key }) {
                            let lk = k.lowercased()
                            guard !lk.hasPrefix("parent"), lk.contains("speed") || lk.contains("current")
                                    || lk.contains("cable") || lk.contains("vendor name") || lk.contains("product name") else { continue }
                            if let s = v as? String { port.cableDetails.append("\(k): \(s)") }
                            else if let i = v as? Int { port.cableDetails.append("\(k): \(i)") }
                        }
                    }
                case "Power In":
                    IO.children(c) { src in
                        let sp = IO.props(src)
                        guard port.powerIn == nil, let win = sp["WinningPowerSourceOption"] as? [String: Any],
                              let active = option(win) else { return }
                        var raw: [[String: Any]] = sp["PowerSourceOptions"] as? [[String: Any]] ?? []
                        if raw.isEmpty, let set = sp["PowerSourceOptions"] as? NSSet { raw = set.allObjects as? [[String: Any]] ?? [] }
                        port.powerIn = PowerSource(name: sp["PowerSourceName"] as? String ?? "USB-PD", active: active,
                                                   options: raw.compactMap(option).sorted { $0.mW < $1.mW })
                    }
                default: break
                }
            }
            if kind == .hdmi, p["HDMI_HPD"] as? Bool == true { port.connected = true }
            ports[port.id] = port
        }

        // 2. USB devices. The top byte of locationID is the bus number; bus N maps to port N+1.
        var devices: [(Int, USBDevice)] = []
        IO.services(IOServiceMatching("IOUSBHostDevice")) { e in
            let p = IO.props(e)
            guard let loc = p["locationID"] as? Int else { return }
            var nibbles = 0
            var rest = loc & 0x00FF_FFFF
            while rest != 0 { if rest & 0xF0_0000 != 0 { nibbles += 1 }; rest = (rest << 4) & 0x00FF_FFFF }
            guard nibbles > 0 else { return }   // the bus root hub
            let dev = USBDevice(
                id: String(loc, radix: 16),
                name: p["USB Product Name"] as? String ?? IO.name(e),
                vendor: p["USB Vendor Name"] as? String,
                speedBps: p["UsbLinkSpeed"] as? Int ?? 0,
                powerMA: p["UsbPowerSinkAllocation"] as? Int,
                depth: nibbles - 1,
                bcdUSB: p["bcdUSB"] as? Int ?? 0,
                deviceClass: p["bDeviceClass"] as? Int ?? 0,
                bsdDisk: IO.wholeDisk(under: e))
            devices.append((loc, dev))
        }
        for (loc, dev) in devices.sorted(by: { $0.0 < $1.0 }) {
            let key = "usbc-\((loc >> 24) + 1)"
            ports[key]?.usbDevices.append(dev)
        }

        // 3. Power: the charger and how much each port supplies to its device.
        IO.services(IOServiceMatching("AppleSmartBattery")) { e in
            snap.isLaptop = true
            let p = IO.props(e)
            if p["ExternalConnected"] as? Bool == true, let a = p["AdapterDetails"] as? [String: Any], let w = a["Watts"] as? Int, w > 0 {
                snap.adapter = Adapter(name: a["Name"] as? String ?? L("Зарядное устройство", "Power adapter"), watts: w)
            }
            for out in p["PowerOutDetails"] as? [[String: Any]] ?? [] {
                guard let idx = out["PortIndex"] as? Int, let mW = out["Watts"] as? Int, mW > 200 else { continue }
                ports["usbc-\(idx)"]?.powerOutMW = mW
            }
        }

        // 4. Thunderbolt / USB4: receptacle_id_key is the port number.
        if let data = run("/usr/sbin/system_profiler", ["SPThunderboltDataType", "-json"]),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            for bus in json["SPThunderboltDataType"] as? [[String: Any]] ?? [] {
                guard let rec = bus["receptacle_1_tag"] as? [String: Any],
                      let idStr = rec["receptacle_id_key"] as? String else { continue }
                let status = rec["receptacle_status_key"] as? String ?? ""
                let items = bus["_items"] as? [[String: Any]] ?? []
                if status != "receptacle_no_devices_connected" || !items.isEmpty {
                    ports["usbc-\(idStr)"]?.thunderboltSpeed = rec["current_speed_key"] as? String
                    ports["usbc-\(idStr)"]?.thunderboltDevices = items.compactMap { $0["_name"] as? String }
                }
            }
        }

        // 5. External displays — only when at least one port has DisplayPort active.
        let displayPorts = ports.values.filter { $0.displayActive || ($0.kind == .hdmi && $0.connected) }.map(\.id).sorted()
        if !displayPorts.isEmpty { assignDisplays(to: displayPorts, in: &ports) }

        snap.ports = ports.values.sorted { ($0.kind.order, $0.number) < ($1.kind.order, $1.number) }
        return snap
    }

    private static func option(_ d: [String: Any]) -> PowerOption? {
        guard let mV = d["Voltage (mV)"] as? Int, let mA = d["Max Current (mA)"] as? Int else { return nil }
        return PowerOption(mV: mV, mA: mA, mW: d["Max Power (mW)"] as? Int ?? mV * mA / 1000)
    }

    private static func assignDisplays(to ids: [String], in ports: inout [String: PortInfo]) {
        guard let data = run("/usr/sbin/system_profiler", ["SPDisplaysDataType", "-json"]),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        var external: [String] = []
        for gpu in json["SPDisplaysDataType"] as? [[String: Any]] ?? [] {
            for d in gpu["spdisplays_ndrvs"] as? [[String: Any]] ?? [] {
                let conn = d["spdisplays_connection_type"] as? String ?? ""
                guard conn != "spdisplays_internal", conn != "spdisplays_airplay" else { continue }
                let name = d["_name"] as? String ?? L("Монитор", "Display")
                if let res = d["_spdisplays_resolution"] as? String { external.append("\(name) · \(res)") }
                else { external.append(name) }
            }
        }
        guard !external.isEmpty else { return }
        if external.count == ids.count {
            for (id, d) in zip(ids, external) { ports[id]?.displays = [d] }
        } else {
            // A display cannot be mapped to a port unambiguously — show them all.
            for id in ids { ports[id]?.displays = external }
        }
    }
}

extension PortKind {
    var order: Int {
        switch self { case .magsafe: return 0; case .usbc: return 1; case .hdmi: return 2; case .sd: return 3; case .other: return 4 }
    }
}

// MARK: - Ejecting disks

enum Ejector {
    private static let session: DASession? = {
        guard let s = DASessionCreate(kCFAllocatorDefault) else { return nil }
        DASessionScheduleWithRunLoop(s, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        return s
    }()

    static let didFinish = Notification.Name("PortSenseEjectFinished")

    /// Unmounts every volume of the disk and ejects it. The outcome arrives as a didFinish notification (object: error text or nil).
    static func eject(bsd: String) {
        guard let session, let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd) else {
            NotificationCenter.default.post(name: didFinish, object: L("Диск не найден", "Disk not found"))
            return
        }
        DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionWhole), { disk, dissenter, _ in
            if let dissenter {
                let reason = DADissenterGetStatusString(dissenter) as String? ?? L("диск занят", "disk is busy")
                NotificationCenter.default.post(name: Ejector.didFinish, object: reason)
            } else {
                DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), nil, nil)
                NotificationCenter.default.post(name: Ejector.didFinish, object: nil)
            }
        }, nil)
    }
}
