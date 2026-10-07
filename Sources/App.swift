import SwiftUI
import Charts
import AppKit

// MARK: - App

/// Launch options
///   --demo               show generated sample data; nothing is read from or written to disk
///   --sample-pdf <path>  write a PDF report of the sample data to <path> and quit (build test)
enum LaunchArgs {
    static let all = CommandLine.arguments
    static var demo: Bool { all.contains("--demo") }
    static var samplePDFPath: String? {
        guard let i = all.firstIndex(of: "--sample-pdf"), i + 1 < all.count else { return nil }
        return all[i + 1]
    }
}

@main
struct WeightTrackerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var store = Store(demo: LaunchArgs.demo || LaunchArgs.samplePDFPath != nil)
    @ObservedObject private var language = LanguageManager.shared

    var body: some Scene {
        Window(L("app.name"), id: "main") {
            ContentView()
                .environmentObject(store)
                .environment(\.locale, language.locale)
                .preferredColorScheme(.light)
                .frame(minWidth: 420, minHeight: 600)
        }
        .defaultSize(width: 460, height: 880)
        .commands { AppCommands(store: store, language: language) }
    }
}

struct AppCommands: Commands {
    let store: Store
    @ObservedObject var language: LanguageManager

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L("menu.about")) { AboutPanel.show() }
        }
        CommandGroup(after: .appInfo) {
            Picker(L("menu.language"), selection: Binding(
                get: { language.preference },
                set: { language.setPreference($0) }
            )) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.pickerLabel).tag(lang)
                }
            }
        }
        CommandGroup(replacing: .newItem) {
            Button(L("menu.import")) { store.importPanel() }
                .keyboardShortcut("o")
            Divider()
            Button(L("menu.exportPDF")) { store.exportPDFPanel() }
                .keyboardShortcut("p")
            Button(L("menu.exportCSV")) { store.exportPanel(csv: true) }
            Button(L("menu.exportJSON")) { store.exportPanel(csv: false) }
            Divider()
            Button(L("menu.showData")) { store.revealData() }
                .disabled(!store.persists)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Build test: `--sample-pdf <path>` writes a PDF of the generated sample data and quits.
    /// It never touches the user's data file.
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let path = LaunchArgs.samplePDFPath else { return }
        let url = URL(fileURLWithPath: path)
        var code: Int32 = 0
        do {
            let store = Store(demo: true)
            try PDFReport.write(entries: store.entries, goal: store.goal, to: url)
            print("PDF written: \(url.path) (\(store.entries.count) sample entries)")
        } catch {
            print("PDF ERROR: \(error)")
            code = 1
        }
        exit(code)
    }
}

// MARK: - Colors

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
    static let kPaper = Color(hex: 0xF6F4EF)
    static let kInk = Color(hex: 0x191C19)
    static let kMuted = Color(hex: 0x6B7066)
    static let kCard = Color.white
    static let kLine = Color(hex: 0xE7E3DA)
    static let kTeal = Color(hex: 0x0F766E)
    static let kGood = Color(hex: 0x0F766E)
    static let kBad = Color(hex: 0xC2533B)
    static let kAmber = Color(hex: 0xC8941F)
}

extension View {
    func card() -> some View {
        self
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.kCard))
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.kLine, lineWidth: 1))
    }
}

struct SectionTitle: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(upper(text))
            .font(.system(size: 11, weight: .semibold))
            .tracking(1.6)
            .foregroundStyle(Color.kMuted)
    }
}

enum ChartRange: String, CaseIterable, Identifiable {
    case d7, d30, d90, d180, d270, all
    var id: String { rawValue }
    var title: String {
        if let d = days { return LF("range.days", d) }
        return L("range.all")
    }
    var days: Int? {
        switch self {
        case .d7: return 7
        case .d30: return 30
        case .d90: return 90
        case .d180: return 180
        case .d270: return 270
        case .all: return nil
        }
    }
}

// MARK: - Main screen

/// Form state (an ObservableObject so it doesn't depend on the SwiftUI @State macro).
final class FormState: ObservableObject {
    @Published var date = Date()
    @Published var kgText = ""
    @Published var goalText = ""
    @Published var range: ChartRange = .all
}

struct ContentView: View {
    @EnvironmentObject var store: Store
    @ObservedObject private var language = LanguageManager.shared
    @StateObject private var form = FormState()
    @FocusState private var kgFocused: Bool
    @FocusState private var goalFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                hero
                entryCard
                chartCard
                statsRow
                goalRow
                listSection
                footer
            }
            .padding(16)
            .frame(maxWidth: 540)
            .frame(maxWidth: .infinity)
            // Rebuild every text when the language changes
            .id(language.code)
        }
        .background(Color.kPaper)
        .navigationTitle(L("app.name"))
        .onAppear {
            form.goalText = Fmt.kg(store.goal)
            DispatchQueue.main.async { kgFocused = true }
        }
        .onChange(of: goalFocused) { _, focused in
            if !focused { saveGoal() }
        }
        .onChange(of: language.code) { _, _ in
            store.status = nil   // the last message was written in the old language
        }
    }

    // MARK: Top: latest weight

    private var hero: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionTitle(store.current.map { LF("hero.latest", DateUtil.short($0.day)) } ?? L("hero.noEntries"))
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(store.current.map { Fmt.kg($0.kg) } ?? "—")
                    .font(.system(size: 60, weight: .bold, design: .monospaced))
                Text(verbatim: "kg")
                    .font(.system(size: 18, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.kMuted)
            }
            if let cur = store.current {
                HStack(spacing: 6) {
                    if let p = store.previous { DeltaChip(value: cur.kg - p.kg, label: L("delta.previous")) }
                    if let f = store.entries.first { DeltaChip(value: cur.kg - f.kg, label: L("delta.start")) }
                    DeltaChip(value: cur.kg - store.goal, label: L("delta.goal"))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    // MARK: New entry

    private var entryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                DatePicker("", selection: $form.date, in: ...Date(), displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.field)
                    .fixedSize()
                TextField(L("entry.placeholder"), text: $form.kgText)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 16, design: .monospaced))
                    .focused($kgFocused)
                    .onSubmit(save)
                Button(action: save) {
                    Text(L("entry.save")).fontWeight(.semibold).padding(.horizontal, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color.kInk)
                .controlSize(.large)
            }
            HStack(spacing: 6) {
                if let s = store.status {
                    Text(s.text).foregroundStyle(s.isError ? Color.kBad : Color.kGood)
                } else {
                    Text(L("entry.hint")).foregroundStyle(Color.kMuted)
                }
                if store.lastDeleted != nil {
                    Button(L("entry.undo")) { store.undoDelete() }
                        .buttonStyle(.link)
                }
            }
            .font(.system(size: 12))
        }
        .card()
    }

    private func save() {
        let t = form.kgText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        guard let v = Double(t), kgRange.contains(v) else {
            store.status = Store.Status(text: L("error.invalidWeight"), isError: true)
            kgFocused = true
            return
        }
        if store.save(date: form.date, kg: v) { form.kgText = "" }
        kgFocused = true
    }

    // MARK: Chart

    private var chartCard: some View {
        let data = store.inRange(form.range.days)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionTitle(L("chart.title"))
                    .fixedSize()
                Spacer(minLength: 8)
                Picker("", selection: $form.range) {
                    ForEach(ChartRange.allCases) { r in Text(r.title).tag(r) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .fixedSize()
            }
            if data.isEmpty {
                Text(L("chart.empty"))
                    .foregroundStyle(Color.kMuted)
                    .frame(maxWidth: .infinity, minHeight: 200)
            } else {
                WeightChart(data: data, goal: store.goal)
                    .frame(height: 220)
            }
        }
        .card()
    }

    // MARK: Summary

    private var statsRow: some View {
        HStack(spacing: 8) {
            StatCell(title: L("stat.lowest"), text: store.minKg.map(Fmt.kg) ?? "—", color: .kInk)
            StatCell(title: L("stat.week"), text: store.weekTrend.map(Fmt.signed) ?? "—", color: signColor(store.weekTrend))
            StatCell(title: L("stat.total"), text: store.totalChange.map(Fmt.signed) ?? "—", color: signColor(store.totalChange))
            StatCell(title: L("stat.toGoal"), text: leftText, color: leftDone ? .kGood : .kInk)
        }
    }

    private var leftDone: Bool {
        guard let c = store.current else { return false }
        return c.kg - store.goal <= 0
    }
    private var leftText: String {
        guard let c = store.current else { return "—" }
        let left = c.kg - store.goal
        return left <= 0 ? "✓" : Fmt.kg(left)
    }
    private func signColor(_ v: Double?) -> Color {
        guard let v = v, abs(v) >= 0.05 else { return .kMuted }
        return v < 0 ? .kGood : .kBad
    }

    // MARK: Goal

    private var goalRow: some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 3).fill(Color.kAmber).frame(width: 9, height: 9)
            Text(L("goal.label")).font(.system(size: 13, weight: .semibold)).foregroundStyle(Color.kMuted)
            TextField("", text: $form.goalText)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 14, design: .monospaced))
                .multilineTextAlignment(.center)
                .frame(width: 70)
                .focused($goalFocused)
                .onSubmit(saveGoal)
            Text(verbatim: "kg").font(.system(size: 13, design: .monospaced)).foregroundStyle(Color.kMuted)
            Spacer()
            if let c = store.current {
                let left = c.kg - store.goal
                Text(left <= 0 ? L("goal.reached") : LF("goal.left", Fmt.kg(left)))
                    .font(.system(size: 13, weight: .semibold, design: .monospaced))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.kCard))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.kLine, lineWidth: 1))
    }

    private func saveGoal() {
        let t = form.goalText.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: ",", with: ".")
        if let g = Double(t) { store.setGoal(g) }
        form.goalText = Fmt.kg(store.goal)
    }

    // MARK: Entry list

    private var listSection: some View {
        let desc = Array(store.entries.reversed())
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionTitle(L("list.title"))
                Text(verbatim: "\(desc.count)").font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.kMuted)
                Spacer()
                Button(L("list.import")) { store.importPanel() }
                    .controlSize(.small)
                    .help(L("list.importHelp"))
                Menu(L("list.export")) {
                    Button(L("list.exportPDF")) { store.exportPDFPanel() }
                    Button { store.exportPanel(csv: true) } label: { Text(verbatim: "CSV…") }
                    Button { store.exportPanel(csv: false) } label: { Text(verbatim: "JSON…") }
                }
                .controlSize(.small)
                .fixedSize()
            }
            .padding(.horizontal, 4)
            LazyVStack(spacing: 0) {
                if desc.isEmpty {
                    Text(L("list.empty"))
                        .foregroundStyle(Color.kMuted)
                        .frame(maxWidth: .infinity)
                        .padding(28)
                }
                ForEach(Array(desc.enumerated()), id: \.element.id) { i, e in
                    EntryRow(entry: e, diff: i + 1 < desc.count ? e.kg - desc[i + 1].kg : nil) {
                        store.delete(e)
                    }
                    if i < desc.count - 1 { Divider().padding(.horizontal, 14) }
                }
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.kCard))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.kLine, lineWidth: 1))
        }
    }

    // MARK: Footer: privacy note, language, credits

    private var footer: some View {
        VStack(spacing: 10) {
            Text(L(store.persists ? "footer.local" : "footer.demo"))
                .font(.system(size: 11))
                .foregroundStyle(Color.kMuted)
                .multilineTextAlignment(.center)
            Picker("", selection: Binding(
                get: { language.preference },
                set: { language.setPreference($0) }
            )) {
                ForEach(AppLanguage.allCases) { lang in
                    Text(lang.pickerLabel).tag(lang)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
            .fixedSize()
            .help(L("menu.language"))
            HStack(spacing: 6) {
                Text(LF("credits.developedBy", AppInfo.developerName))
                Text(verbatim: "·")
                Link(destination: AppInfo.githubURL) { Text(verbatim: "GitHub") }
                Text(verbatim: "·")
                Link(destination: AppInfo.linkedinURL) { Text(verbatim: "LinkedIn") }
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.kMuted)
            Text(verbatim: "v\(AppInfo.version) · \(AppInfo.copyrightLine)")
                .font(.system(size: 10))
                .foregroundStyle(Color.kMuted.opacity(0.8))
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 6)
    }
}

// MARK: - Parts

struct DeltaChip: View {
    let value: Double
    let label: String
    var body: some View {
        let flat = abs(value) < 0.05
        let color: Color = flat ? .kMuted : (value < 0 ? .kGood : .kBad)
        HStack(spacing: 4) {
            Text(verbatim: "\(flat ? "•" : (value < 0 ? "▼" : "▲")) \(Fmt.signed(value))")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(color)
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Color.kMuted)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(Capsule().fill(color.opacity(0.07)))
        .overlay(Capsule().stroke(color.opacity(0.25), lineWidth: 1))
    }
}

struct StatCell: View {
    let title: String
    let text: String
    let color: Color
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(upper(title))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.kMuted)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(text)
                    .font(.system(size: 19, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
                if text != "—" && text != "✓" {
                    Text(verbatim: "kg").font(.system(size: 11, design: .monospaced)).foregroundStyle(Color.kMuted)
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.kCard))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.kLine, lineWidth: 1))
    }
}

struct EntryRow: View {
    let entry: Entry
    let diff: Double?
    let onDelete: () -> Void

    private var diffColor: Color {
        guard let d = diff, abs(d) >= 0.05 else { return .kMuted }
        return d < 0 ? .kGood : .kBad
    }

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 1) {
                Text(DateUtil.long(entry.day))
                    .font(.system(size: 13, weight: .semibold))
                Text(DateUtil.weekday(entry.day))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.kMuted)
            }
            .frame(width: 124, alignment: .leading)
            Text(diff.map(Fmt.signed) ?? "—")
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(diffColor)
            Spacer()
            Text(Fmt.kg(entry.kg))
                .font(.system(size: 16, weight: .bold, design: .monospaced))
            Button(action: onDelete) {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(Color.kMuted.opacity(0.6))
            .help(L("row.delete"))
            .accessibilityLabel(L("row.delete"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .contextMenu {
            Button(L("row.delete"), role: .destructive, action: onDelete)
        }
    }
}

/// Entry under the mouse pointer on the chart (an ObservableObject instead of the @State macro).
final class ChartHover: ObservableObject {
    @Published var date: String? = nil
}

struct WeightChart: View {
    let data: [Entry]
    let goal: Double
    /// In the PDF a transparent gradient turns into a solid color, so use a light solid fill.
    var solidArea: Bool = false
    @StateObject private var hover = ChartHover()

    /// Entry closest to the date under the pointer
    private func nearest(to date: Date) -> Entry? {
        data.min { abs($0.day.timeIntervalSince(date)) < abs($1.day.timeIntervalSince(date)) }
    }

    var body: some View {
        let ks = data.map(\.kg) + [goal]
        let lo0 = ks.min() ?? goal
        let hi0 = ks.max() ?? goal
        let span = max(hi0 - lo0, 1)
        let lo = lo0 - span * 0.15
        let hi = hi0 + span * 0.15
        let showPoints = data.count <= 45
        // With one point or a very short range, keep at least a 6-day window so the axis
        // doesn't repeat the same date.
        let d0 = data.first?.day ?? Date()
        let d1 = data.last?.day ?? d0
        let minSpan: TimeInterval = 6 * 86_400
        let gap = d1.timeIntervalSince(d0)
        let pad = gap < minSpan ? (minSpan - gap) / 2 : 0
        let xlo = d0.addingTimeInterval(-pad)
        let xhi = d1.addingTimeInterval(pad)
        let selIndex = hover.date.flatMap { d in data.firstIndex { $0.date == d } }
        let sel = selIndex.map { data[$0] }

        Chart {
            ForEach(data) { e in
                AreaMark(
                    x: .value("Date", e.day),
                    yStart: .value("Base", lo),
                    yEnd: .value("Weight", e.kg)
                )
                .foregroundStyle(
                    solidArea
                        ? AnyShapeStyle(Color(hex: 0xE3EEEC))
                        : AnyShapeStyle(LinearGradient(colors: [Color.kTeal.opacity(0.22), Color.kTeal.opacity(0.0)],
                                                       startPoint: .top, endPoint: .bottom))
                )
                LineMark(
                    x: .value("Date", e.day),
                    y: .value("Weight", e.kg)
                )
                .foregroundStyle(Color.kTeal)
                .lineStyle(StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
                if showPoints {
                    PointMark(
                        x: .value("Date", e.day),
                        y: .value("Weight", e.kg)
                    )
                    .foregroundStyle(Color.kTeal)
                    .symbolSize(26)
                }
            }
            RuleMark(y: .value("Goal", goal))
                .foregroundStyle(Color.kAmber)
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
                .annotation(position: .top, alignment: .leading) {
                    Text(LF("chart.goal", Fmt.kg(goal)))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(Color.kAmber)
                }
            if let s = sel {
                RuleMark(x: .value("Selected", s.day))
                    .foregroundStyle(Color.kMuted.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                PointMark(x: .value("Selected", s.day), y: .value("Weight", s.kg))
                    .foregroundStyle(Color.kTeal)
                    .symbolSize(90)
                PointMark(x: .value("Selected", s.day), y: .value("Weight", s.kg))
                    .foregroundStyle(Color.white)
                    .symbolSize(28)
            }
        }
        .chartYScale(domain: lo...hi)
        .chartXScale(domain: xlo...xhi)
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.day().month(.abbreviated))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4))
        }
        .chartOverlay { proxy in
            GeometryReader { geo in
                let plot: CGRect = proxy.plotFrame.map { geo[$0] } ?? .zero
                ZStack(alignment: .topLeading) {
                    Rectangle()
                        .fill(Color.clear)
                        .contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let loc):
                                let x = loc.x - plot.minX
                                if let d: Date = proxy.value(atX: x), let e = nearest(to: d) {
                                    if hover.date != e.date { hover.date = e.date }
                                } else {
                                    hover.date = nil
                                }
                            case .ended:
                                hover.date = nil
                            }
                        }
                    if let s = sel, let i = selIndex,
                       let px = proxy.position(forX: s.day),
                       let py = proxy.position(forY: s.kg) {
                        let pt = CGPoint(x: plot.minX + px, y: plot.minY + py)
                        let halfW: CGFloat = 78
                        let tx = min(max(pt.x, halfW), max(geo.size.width - halfW, halfW))
                        let above = pt.y - 40 >= 18
                        let ty = above ? pt.y - 36 : pt.y + 36
                        ChartTooltip(entry: s, diff: i > 0 ? s.kg - data[i - 1].kg : nil)
                            .position(x: tx, y: ty)
                            .allowsHitTesting(false)
                    }
                }
            }
        }
    }
}

struct ChartTooltip: View {
    let entry: Entry
    let diff: Double?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: "\(DateUtil.long(entry.day)) · \(DateUtil.weekday(entry.day))")
                .font(.system(size: 11))
                .foregroundStyle(Color.kMuted)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(verbatim: "\(Fmt.kg(entry.kg)) kg")
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.kInk)
                if let d = diff {
                    let c: Color = abs(d) < 0.05 ? .kMuted : (d < 0 ? .kGood : .kBad)
                    Text(Fmt.signed(d))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(c)
                }
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.white)
                .shadow(color: Color.black.opacity(0.12), radius: 4, y: 1)
        )
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.kLine, lineWidth: 1))
        .fixedSize()
    }
}
