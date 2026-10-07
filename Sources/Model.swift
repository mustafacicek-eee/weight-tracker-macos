import Foundation
import AppKit
import UniformTypeIdentifiers

// MARK: - Data types

struct Entry: Codable, Identifiable, Equatable {
    var date: String   // "yyyy-MM-dd"
    var kg: Double
    var id: String { date }
    var day: Date { DateUtil.parse(date) ?? Date.distantPast }
}

/// On-disk file format.
struct SavedFile: Codable {
    var app: String?
    var version: Int?
    var updated: String?
    var goal: Double?
    var entries: [Entry]
}

// MARK: - Helpers

enum DateUtil {
    /// Storage format, independent of the UI language.
    static let iso: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f
    }()

    static func parse(_ s: String) -> Date? { iso.date(from: s) }
    static func string(_ d: Date) -> String { iso.string(from: d) }
    static func valid(_ s: String) -> Bool { s.count == 10 && parse(s) != nil }

    // Display formatters follow the selected app language; cached per language.
    nonisolated(unsafe) private static var cache: [String: DateFormatter] = [:]
    private static func formatter(_ template: String) -> DateFormatter {
        let loc = LanguageManager.shared.locale
        let key = loc.identifier + "|" + template
        if let f = cache[key] { return f }
        let f = DateFormatter()
        f.locale = loc
        f.setLocalizedDateFormatFromTemplate(template)
        cache[key] = f
        return f
    }
    /// "6 Oct" / "6 Eki"
    static func short(_ d: Date) -> String { formatter("dMMM").string(from: d) }
    /// "6 Oct 2026" / "6 Eki 2026"
    static func long(_ d: Date) -> String { formatter("dMMMy").string(from: d) }
    /// "Tuesday" / "Salı"
    static func weekday(_ d: Date) -> String { formatter("EEEE").string(from: d) }
}

enum Fmt {
    static func kg(_ v: Double) -> String {
        String(format: "%.1f", (v * 10).rounded() / 10)
    }
    static func signed(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        if r == 0 { return "0.0" }
        return (r > 0 ? "+" : "") + String(format: "%.1f", r)
    }
}

let kgRange: ClosedRange<Double> = 30...400
let defaultGoal: Double = 70

// MARK: - Import (JSON or CSV)

enum Importer {
    static func parse(_ text: String) -> (rows: [Entry], bad: Int, goal: Double?) {
        var rows: [Entry] = []
        var bad = 0
        var goal: Double? = nil

        func push(_ d: Any?, _ k: Any?) {
            let ds = (d as? String)?.trimmingCharacters(in: .whitespaces) ?? ""
            var kv: Double? = nil
            if let n = k as? NSNumber {
                kv = n.doubleValue
            } else if let s = k as? String {
                kv = Double(s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: "."))
            }
            if DateUtil.valid(ds), let v = kv, kgRange.contains(v) {
                rows.append(Entry(date: ds, kg: (v * 100).rounded() / 100))
            } else {
                bad += 1
            }
        }

        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("{") || t.hasPrefix("[") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(t.utf8)) else {
                return ([], 1, nil)
            }
            var arr: [Any] = []
            if let a = obj as? [Any] {
                arr = a
            } else if let o = obj as? [String: Any] {
                arr = (o["entries"] as? [Any]) ?? []
                if let g = (o["goal"] as? NSNumber)?.doubleValue, kgRange.contains(g) { goal = g }
            }
            for item in arr {
                let o = item as? [String: Any]
                // "tarih"/"kilo" keys: files exported by the earlier Turkish-only version
                push(o?["date"] ?? o?["tarih"], o?["kg"] ?? o?["kilo"])
            }
        } else {
            for (i, raw) in t.components(separatedBy: .newlines).enumerated() {
                let line = raw.trimmingCharacters(in: .whitespaces)
                if line.isEmpty { continue }
                var cells: [String]
                if line.contains(";") || line.contains("\t") {
                    cells = line.components(separatedBy: CharacterSet(charactersIn: ";\t"))
                } else {
                    // Also accept a decimal comma, e.g. "2024-01-15,72,5"
                    let p = line.components(separatedBy: ",")
                    cells = [p[0], p.dropFirst().joined(separator: ".")]
                }
                if i == 0, let c = cells.first?.trimmingCharacters(in: .whitespaces).first, !c.isNumber {
                    continue // header row
                }
                push(cells.first, cells.count > 1 ? cells[1] : nil)
            }
        }
        return (rows, bad, goal)
    }
}

// MARK: - Sample data (demo mode, screenshots, build test)

/// Synthetic, generated values — not anyone's real measurements.
enum DemoData {
    static let goal: Double = 72
    static var entries: [Entry] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var seed: UInt64 = 2026
        func noise() -> Double {   // deterministic pseudo-random value in -0.5...0.5
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            return Double(seed >> 33) / Double(UInt64(1) << 31) - 0.5
        }
        var out: [Entry] = []
        for i in 0..<120 {
            let n = noise()
            if i % 9 == 4 { continue } // a few skipped days
            guard let d = cal.date(byAdding: .day, value: i - 119, to: today) else { continue }
            let kg = 82.0 - Double(i) * 0.06 + n * 0.8
            out.append(Entry(date: DateUtil.string(d), kg: (kg * 10).rounded() / 10))
        }
        return out
    }
}

// MARK: - Store

@MainActor
final class Store: ObservableObject {
    struct Status: Equatable {
        var text: String
        var isError: Bool
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var goal: Double = defaultGoal
    @Published var status: Status? = nil
    @Published private(set) var lastDeleted: Entry? = nil

    /// false in demo mode: nothing is read from or written to disk.
    let persists: Bool
    let dir: URL
    // Folder and file names are kept from the first (Turkish-only) version so existing
    // data keeps loading after an update.
    var file: URL { dir.appendingPathComponent("kilo_takibi.json") }
    var backupDir: URL { dir.appendingPathComponent("yedekler", isDirectory: true) }
    var prevFile: URL { backupDir.appendingPathComponent("onceki_surum.json") }
    private let fm = FileManager.default
    private let keepBackups = 30

    init(demo: Bool = false) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        dir = base.appendingPathComponent("KiloTakibi", isDirectory: true)
        persists = !demo
        if demo {
            entries = DemoData.entries
            goal = DemoData.goal
        } else {
            load()
        }
    }

    // MARK: Derived values

    var current: Entry? { entries.last }
    var previous: Entry? { entries.count > 1 ? entries[entries.count - 2] : nil }
    var minKg: Double? { entries.map(\.kg).min() }
    var totalChange: Double? {
        guard let f = entries.first, let l = entries.last else { return nil }
        return l.kg - f.kg
    }
    /// Difference between the latest entry and the closest entry at least 7 days before it.
    var weekTrend: Double? {
        guard let last = entries.last, let first = entries.first else { return nil }
        guard let cut = Calendar.current.date(byAdding: .day, value: -7, to: last.day) else { return nil }
        let ref = entries.last(where: { $0.day <= cut }) ?? first
        return last.kg - ref.kg
    }

    func inRange(_ days: Int?) -> [Entry] {
        guard let days = days, let last = entries.last else { return entries }
        guard let cut = Calendar.current.date(byAdding: .day, value: -(days - 1), to: last.day) else { return entries }
        return entries.filter { $0.day >= cut }
    }

    // MARK: Actions

    @discardableResult
    func save(date: Date, kg: Double) -> Bool {
        let key = DateUtil.string(date)
        let v = (kg * 100).rounded() / 100
        let existed = entries.contains { $0.date == key }
        let ok = commit {
            if let i = entries.firstIndex(where: { $0.date == key }) {
                entries[i].kg = v
            } else {
                entries.append(Entry(date: key, kg: v))
            }
        }
        if ok {
            lastDeleted = nil
            status = Status(text: LF(existed ? "status.updated" : "status.added", DateUtil.short(date), Fmt.kg(v)),
                            isError: false)
        }
        return ok
    }

    func delete(_ e: Entry) {
        if commit({ entries.removeAll { $0.date == e.date } }) {
            lastDeleted = e
            status = Status(text: LF("status.deleted", DateUtil.short(e.day), Fmt.kg(e.kg)), isError: false)
        }
    }

    func undoDelete() {
        guard let e = lastDeleted else { return }
        if commit({ if !entries.contains(where: { $0.date == e.date }) { entries.append(e) } }) {
            lastDeleted = nil
            status = Status(text: LF("status.restored", DateUtil.short(e.day)), isError: false)
        }
    }

    func setGoal(_ g: Double) {
        guard kgRange.contains(g) else {
            status = Status(text: L("status.goalRange"), isError: true)
            return
        }
        if abs(g - goal) < 0.001 { return }
        if commit({ goal = (g * 10).rounded() / 10 }) {
            status = Status(text: LF("status.goalSaved", Fmt.kg(goal)), isError: false)
        }
    }

    func importPanel() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.json, .commaSeparatedText, .plainText]
        p.allowsMultipleSelection = false
        p.message = L("import.panelMessage")
        guard p.runModal() == .OK, let url = p.url else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            status = Status(text: L("status.readFailed"), isError: true)
            return
        }
        let res = Importer.parse(text)
        if res.rows.isEmpty {
            status = Status(text: L("status.noValidRows"), isError: true)
            return
        }
        var added = 0, updated = 0, same = 0
        let ok = commit {
            for r in res.rows {
                if let i = entries.firstIndex(where: { $0.date == r.date }) {
                    if abs(entries[i].kg - r.kg) > 1e-9 { entries[i].kg = r.kg; updated += 1 } else { same += 1 }
                } else {
                    entries.append(r); added += 1
                }
            }
            if let g = res.goal { goal = g }
        }
        if ok {
            var msg = LF("status.imported", added, updated, same)
            if res.bad > 0 { msg += LF("status.importedBad", res.bad) }
            if let g = res.goal { msg += LF("status.importedGoal", Fmt.kg(g)) }
            status = Status(text: msg + ".", isError: false)
        }
    }

    func exportPanel(csv: Bool) {
        let p = NSSavePanel()
        p.nameFieldStringValue = "\(L("export.fileBase"))_\(DateUtil.string(Date())).\(csv ? "csv" : "json")"
        p.allowedContentTypes = [csv ? .commaSeparatedText : .json]
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            let data: Data
            if csv {
                let lines = ["date,kg"] + entries.map { "\($0.date),\(Fmt.kg($0.kg))" }
                data = Data((lines.joined(separator: "\n") + "\n").utf8)
            } else {
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                data = try enc.encode(SavedFile(app: nil, version: nil, updated: nil, goal: goal, entries: entries))
            }
            try data.write(to: url, options: .atomic)
            status = Status(text: LF("status.exported", url.lastPathComponent), isError: false)
        } catch {
            status = Status(text: LF("status.exportFailed", error.localizedDescription), isError: true)
        }
    }

    func exportPDFPanel() {
        let p = NSSavePanel()
        p.nameFieldStringValue = "\(L("export.reportBase"))_\(DateUtil.string(Date())).pdf"
        p.allowedContentTypes = [.pdf]
        guard p.runModal() == .OK, let url = p.url else { return }
        do {
            try PDFReport.write(entries: entries, goal: goal, to: url)
            status = Status(text: LF("status.pdfSaved", url.lastPathComponent), isError: false)
            NSWorkspace.shared.open(url)
        } catch {
            status = Status(text: LF("status.pdfFailed", error.localizedDescription), isError: true)
        }
    }

    func revealData() {
        guard persists else { return }
        if fm.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
            NSWorkspace.shared.open(dir)
        }
    }

    // MARK: Disk

    /// Applies a change and writes it to disk; rolls back if the write fails.
    private func commit(_ change: () -> Void) -> Bool {
        let oldEntries = entries
        let oldGoal = goal
        change()
        entries.sort { $0.date < $1.date }
        guard persists else { return true }
        do {
            try write()
            return true
        } catch {
            entries = oldEntries
            goal = oldGoal
            status = Status(text: LF("status.saveFailed", error.localizedDescription), isError: true)
            return false
        }
    }

    private func write() throws {
        guard persists else { return }
        try fm.createDirectory(at: backupDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: file.path) {
            // Daily backup before the first change of the day
            let daily = backupDir.appendingPathComponent("kilo_takibi-\(DateUtil.string(Date())).json")
            if !fm.fileExists(atPath: daily.path) {
                try? fm.copyItem(at: file, to: daily)
                pruneBackups()
            }
            // Previous version (for same-day recovery)
            try? fm.removeItem(at: prevFile)
            try? fm.copyItem(at: file, to: prevFile)
        }
        let out = SavedFile(app: "kilo-takibi", version: 1,
                            updated: ISO8601DateFormatter().string(from: Date()),
                            goal: goal, entries: entries)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(out).write(to: file, options: .atomic)
    }

    private func backupFiles() -> [URL] {
        let items = (try? fm.contentsOfDirectory(at: backupDir, includingPropertiesForKeys: nil)) ?? []
        return items.filter { $0.lastPathComponent.hasPrefix("kilo_takibi-") && $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Keeps the newest 30 daily backups.
    private func pruneBackups() {
        let all = backupFiles()
        if all.count > keepBackups {
            for u in all.prefix(all.count - keepBackups) { try? fm.removeItem(at: u) }
        }
    }

    private func read(_ url: URL) -> (entries: [Entry], goal: Double)? {
        guard let data = try? Data(contentsOf: url),
              let f = try? JSONDecoder().decode(SavedFile.self, from: data) else { return nil }
        var by: [String: Double] = [:]
        for e in f.entries {
            guard DateUtil.valid(e.date), kgRange.contains(e.kg) else { return nil }
            by[e.date] = e.kg
        }
        let g = f.goal.flatMap { kgRange.contains($0) ? $0 : nil } ?? defaultGoal
        return (by.keys.sorted().map { Entry(date: $0, kg: by[$0]!) }, g)
    }

    private func load() {
        // No data file yet: start empty. The file is created with the first entry.
        guard fm.fileExists(atPath: file.path) else {
            entries = []
            goal = defaultGoal
            return
        }
        if let s = read(file) {
            entries = s.entries
            goal = s.goal
            return
        }
        // Never delete a damaged file: copy it aside and fall back to the newest good backup.
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        try? fm.copyItem(at: file, to: dir.appendingPathComponent("kilo_takibi.json.bozuk-\(stamp)"))
        let candidates = [prevFile] + backupFiles().reversed()
        for c in candidates where fm.fileExists(atPath: c.path) {
            if let s = read(c) {
                entries = s.entries
                goal = s.goal
                try? write()
                status = Status(text: L("status.restoredFromBackup"), isError: true)
                return
            }
        }
        entries = []
        goal = defaultGoal
        status = Status(text: L("status.noBackup"), isError: true)
    }
}
