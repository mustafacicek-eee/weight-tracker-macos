import SwiftUI
import Charts
import AppKit

// MARK: - PDF report (A4, multi-page, vector)

@MainActor
enum PDFReport {
    static let pageSize = CGSize(width: 595.28, height: 841.89) // A4, points
    static let firstPageRows = 12
    static let otherPageRows = 32

    struct Row: Identifiable {
        let entry: Entry
        let diff: Double?
        var id: String { entry.id }
    }

    enum ExportError: LocalizedError {
        case context
        var errorDescription: String? { L("pdf.error") }
    }

    static func write(entries: [Entry], goal: Double, to url: URL) throws {
        let sorted = entries.sorted { $0.date < $1.date }
        let rows: [Row] = sorted.enumerated().map { i, e in
            Row(entry: e, diff: i > 0 ? e.kg - sorted[i - 1].kg : nil)
        }
        var pages: [[Row]] = [Array(rows.prefix(firstPageRows))]
        var rest = rows.dropFirst(firstPageRows)
        while !rest.isEmpty {
            pages.append(Array(rest.prefix(otherPageRows)))
            rest = rest.dropFirst(otherPageRows)
        }

        var box = CGRect(origin: .zero, size: pageSize)
        let info = [
            kCGPDFContextTitle as String: L("pdf.title"),
            kCGPDFContextCreator as String: L("app.name"),
        ] as CFDictionary
        guard let ctx = CGContext(url as CFURL, mediaBox: &box, info) else { throw ExportError.context }

        for (i, pageRows) in pages.enumerated() {
            let page = ReportPage(pageIndex: i, pageCount: pages.count, rows: pageRows,
                                  entries: sorted, goal: goal)
                .environment(\.locale, LanguageManager.shared.locale)
                .environment(\.colorScheme, .light)
            let renderer = ImageRenderer(content: page)
            renderer.proposedSize = ProposedViewSize(pageSize)
            ctx.beginPDFPage(nil)
            renderer.render { _, draw in draw(ctx) }
            ctx.endPDFPage()
        }
        ctx.closePDF()
    }
}

// MARK: - Page view

struct ReportPage: View {
    let pageIndex: Int
    let pageCount: Int
    let rows: [PDFReport.Row]
    let entries: [Entry]
    let goal: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if pageIndex == 0 {
                header
                summary.padding(.top, 16)
                chartBox.padding(.top, 16)
                Text(upper(L("pdf.entries")))
                    .font(.system(size: 9, weight: .semibold))
                    .tracking(1.4)
                    .foregroundStyle(Color.kMuted)
                    .padding(.top, 18)
                    .padding(.bottom, 6)
            } else {
                Text(L("pdf.continued"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.kMuted)
                    .padding(.bottom, 10)
            }
            table
            Spacer(minLength: 0)
            footer
        }
        .padding(36)
        .frame(width: PDFReport.pageSize.width, height: PDFReport.pageSize.height, alignment: .topLeading)
        .background(Color.white)
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L("pdf.title"))
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.kInk)
                // With the Turkish locale, special 'i' shaping can copy wrongly from PDF text
                .environment(\.locale, Locale(identifier: "en_US_POSIX"))
            Text(subtitle)
                .font(.system(size: 10))
                .foregroundStyle(Color.kMuted)
        }
    }

    private var subtitle: String {
        var parts = [LF("pdf.created", DateUtil.long(Date())), LP("pdf.count", count: entries.count)]
        if let f = entries.first, let l = entries.last {
            parts.append("\(DateUtil.long(f.day)) – \(DateUtil.long(l.day))")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: Summary

    private var summary: some View {
        let kgs = entries.map(\.kg)
        let first = entries.first
        let last = entries.last
        let avg = kgs.isEmpty ? nil : kgs.reduce(0, +) / Double(kgs.count)
        let change: Double? = (first != nil && last != nil) ? last!.kg - first!.kg : nil
        let left: Double? = last.map { $0.kg - goal }

        return VStack(spacing: 8) {
            HStack(spacing: 8) {
                SummaryCell(title: L("pdf.latest"), value: last.map { Fmt.kg($0.kg) } ?? "—",
                            sub: last.map { DateUtil.short($0.day) })
                SummaryCell(title: L("pdf.start"), value: first.map { Fmt.kg($0.kg) } ?? "—",
                            sub: first.map { DateUtil.short($0.day) })
                SummaryCell(title: L("pdf.totalChange"), value: change.map(Fmt.signed) ?? "—",
                            color: signColor(change))
                SummaryCell(title: L("pdf.average"), value: avg.map(Fmt.kg) ?? "—")
            }
            HStack(spacing: 8) {
                SummaryCell(title: L("pdf.lowest"), value: kgs.min().map(Fmt.kg) ?? "—")
                SummaryCell(title: L("pdf.highest"), value: kgs.max().map(Fmt.kg) ?? "—")
                SummaryCell(title: L("pdf.goal"), value: Fmt.kg(goal), color: .kAmber)
                SummaryCell(title: L("pdf.toGoal"),
                            value: left.map { $0 <= 0 ? L("pdf.reached") : Fmt.kg($0) } ?? "—",
                            color: (left ?? 1) <= 0 ? .kGood : .kInk,
                            showUnit: (left ?? 1) > 0)
            }
        }
    }

    private func signColor(_ v: Double?) -> Color {
        guard let v = v, abs(v) >= 0.05 else { return .kMuted }
        return v < 0 ? .kGood : .kBad
    }

    // MARK: Chart

    private var chartBox: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(upper(L("pdf.trendAll")))
                .font(.system(size: 9, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Color.kMuted)
            if entries.isEmpty {
                Text(L("pdf.noEntries")).foregroundStyle(Color.kMuted).frame(maxWidth: .infinity, minHeight: 190)
            } else {
                WeightChart(data: entries, goal: goal, solidArea: true).frame(height: 190)
            }
        }
        .padding(12)
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.kLine, lineWidth: 1))
    }

    // MARK: Table

    private var table: some View {
        VStack(spacing: 0) {
            tableRow(date: L("pdf.colDate"), day: L("pdf.colDay"), kg: L("pdf.colWeight"), diff: L("pdf.colChange"),
                     isHeader: true, diffColor: .kMuted)
                .background(Color.kPaper)
            ForEach(Array(rows.enumerated()), id: \.element.id) { i, r in
                tableRow(date: DateUtil.long(r.entry.day),
                         day: DateUtil.weekday(r.entry.day),
                         kg: Fmt.kg(r.entry.kg),
                         diff: r.diff.map(Fmt.signed) ?? "—",
                         isHeader: false,
                         diffColor: signColor(r.diff))
                    .background(i % 2 == 1 ? Color.kPaper.opacity(0.6) : Color.white)
            }
        }
        .overlay(Rectangle().stroke(Color.kLine, lineWidth: 0.5))
    }

    private func tableRow(date: String, day: String, kg: String, diff: String,
                          isHeader: Bool, diffColor: Color) -> some View {
        HStack(spacing: 0) {
            Text(date).frame(width: 150, alignment: .leading)
            Text(day).frame(width: 130, alignment: .leading)
            Text(kg).frame(width: 110, alignment: .trailing)
                .font(.system(size: 10, weight: isHeader ? .semibold : .bold, design: isHeader ? .default : .monospaced))
            Text(diff).frame(maxWidth: .infinity, alignment: .trailing)
                .font(.system(size: 10, weight: isHeader ? .semibold : .regular, design: isHeader ? .default : .monospaced))
                .foregroundStyle(diffColor)
        }
        .font(.system(size: 10, weight: isHeader ? .semibold : .regular))
        .foregroundStyle(isHeader ? Color.kMuted : Color.kInk)
        .padding(.horizontal, 10)
        .frame(height: 20)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text(L("pdf.footer"))
            Spacer()
            Text(LF("pdf.page", pageIndex + 1, pageCount))
        }
        .font(.system(size: 8))
        .foregroundStyle(Color.kMuted)
    }
}

struct SummaryCell: View {
    let title: String
    let value: String
    var sub: String? = nil
    var color: Color = .kInk
    var showUnit: Bool = true

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(upper(title))
                .font(.system(size: 7.5, weight: .semibold))
                .foregroundStyle(Color.kMuted)
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(value)
                    .font(.system(size: 15, weight: .bold, design: .monospaced))
                    .foregroundStyle(color)
                if showUnit && value != "—" {
                    Text(verbatim: "kg").font(.system(size: 8, design: .monospaced)).foregroundStyle(Color.kMuted)
                }
            }
            Text(sub ?? " ")
                .font(.system(size: 8))
                .foregroundStyle(Color.kMuted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.kLine, lineWidth: 1))
    }
}
