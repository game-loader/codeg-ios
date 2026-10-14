import SwiftUI
import Charts

struct GenerativeUIChartView: View {
    let chart: GenerativeUISpec.Chart

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            plot
                .chartForegroundStyleScale(domain: chart.series.map(\.id), range: chart.series.indices.map(GenerativeUIChartPalette.color))
                .chartLegend(.hidden)
                .frame(height: chart.height)
            if chart.legend {
                GenerativeUIChartLegend(series: chart.series)
            }
        }
    }

    @ViewBuilder
    private var plot: some View {
        switch chart.type {
        case "BarChart": GenerativeUIBarChart(chart: chart)
        case "LineChart": GenerativeUILineChart(chart: chart)
        case "AreaChart": GenerativeUIAreaChart(chart: chart)
        default: GenerativeUIPieChart(chart: chart)
        }
    }
}

private struct GenerativeUIBarChart: View {
    let chart: GenerativeUISpec.Chart

    var body: some View {
        if chart.horizontal {
            GenerativeUIHorizontalBars(chart: chart)
                .chartYScale(domain: Array(categories.reversed()))
        } else {
            GenerativeUIVerticalBars(chart: chart)
                .chartXScale(domain: categories)
        }
    }

    private var categories: [String] {
        var seen: Set<String> = []
        return chart.points.compactMap { seen.insert($0.category).inserted ? $0.category : nil }
    }
}

private struct GenerativeUIHorizontalBars: View {
    let chart: GenerativeUISpec.Chart

    var body: some View {
        Chart(chart.points) { point in
            if chart.stacked {
                BarMark(x: .value("Value", point.value), y: .value(chart.categoryLabel, point.category))
                    .foregroundStyle(by: .value("Series", point.series))
                    .annotation(position: .trailing) { annotation(point) }
            } else {
                BarMark(x: .value("Value", point.value), y: .value(chart.categoryLabel, point.category))
                    .foregroundStyle(by: .value("Series", point.series))
                    .position(by: .value("Series", point.series), axis: .vertical)
                    .annotation(position: .trailing) { annotation(point) }
            }
        }
    }

    @ViewBuilder
    private func annotation(_ point: GenerativeUISpec.Chart.Point) -> some View {
        if chart.labels { Text(point.value, format: .number).font(.caption2) }
    }
}

private struct GenerativeUIVerticalBars: View {
    let chart: GenerativeUISpec.Chart

    var body: some View {
        Chart(chart.points) { point in
            if chart.stacked {
                BarMark(x: .value(chart.categoryLabel, point.category), y: .value("Value", point.value))
                    .foregroundStyle(by: .value("Series", point.series))
                    .annotation(position: .top) { annotation(point) }
            } else {
                BarMark(x: .value(chart.categoryLabel, point.category), y: .value("Value", point.value))
                    .foregroundStyle(by: .value("Series", point.series))
                    .position(by: .value("Series", point.series), axis: .horizontal)
                    .annotation(position: .top) { annotation(point) }
            }
        }
    }

    @ViewBuilder
    private func annotation(_ point: GenerativeUISpec.Chart.Point) -> some View {
        if chart.labels { Text(point.value, format: .number).font(.caption2) }
    }
}

private struct GenerativeUILineChart: View {
    let chart: GenerativeUISpec.Chart

    var body: some View {
        Chart(chart.points) { point in
            LineMark(x: .value(chart.categoryLabel, point.category), y: .value("Value", point.value))
                .foregroundStyle(by: .value("Series", point.series))
                .interpolationMethod(chart.curve == "step" ? .stepCenter : .linear)
            if chart.dots {
                PointMark(x: .value(chart.categoryLabel, point.category), y: .value("Value", point.value))
                    .foregroundStyle(by: .value("Series", point.series))
                    .annotation(position: .top) {
                        if chart.labels { Text(point.value, format: .number).font(.caption2) }
                    }
            }
        }
    }
}

private struct GenerativeUIAreaChart: View {
    let chart: GenerativeUISpec.Chart

    var body: some View {
        Chart(chart.points) { point in
            AreaMark(x: .value(chart.categoryLabel, point.category), y: .value("Value", point.value),
                     stacking: chart.stacked ? .standard : .unstacked)
                .foregroundStyle(by: .value("Series", point.series))
                .interpolationMethod(chart.curve == "step" ? .stepCenter : .linear)
                .opacity(0.4)
        }
    }
}

private struct GenerativeUIPieChart: View {
    let chart: GenerativeUISpec.Chart

    var body: some View {
        Chart(chart.points) { point in
            SectorMark(angle: .value("Value", point.value), innerRadius: .ratio(chart.donut ? 0.48 : 0))
                .foregroundStyle(by: .value("Category", point.series))
                .annotation(position: .overlay) {
                    if chart.labels { Text(point.value, format: .number).font(.caption2) }
                }
        }
        .chartBackground { proxy in
            if let caption = chart.centerLabel, let frame = proxy.plotFrame {
                GeometryReader { geometry in
                    let rect = geometry[frame]
                    VStack(spacing: 4) {
                        Text(chart.total, format: .number).font(.title2.bold())
                        Text(verbatim: caption).font(.caption).foregroundStyle(Theme.textSecondary)
                    }
                    .frame(width: rect.width * 0.4)
                    .position(x: rect.midX, y: rect.midY)
                }
            }
        }
    }
}

private enum GenerativeUIChartPalette {
    static func color(_ index: Int) -> Color {
        let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .indigo, .brown]
        return colors[index % colors.count]
    }
}

private struct GenerativeUIChartLegend: View {
    let series: [GenerativeUISpec.Chart.Series]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 100), alignment: .leading)], alignment: .leading) {
            ForEach(Array(series.enumerated()), id: \.offset) { index, entry in
                HStack(spacing: 5) {
                    Circle().fill(GenerativeUIChartPalette.color(index)).frame(width: 8, height: 8)
                    Text(verbatim: entry.label).font(.caption)
                }
            }
        }
    }
}
