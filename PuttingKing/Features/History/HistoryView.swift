import SwiftUI
import CoreData

struct HistoryView: View {
    @EnvironmentObject var appState: AppState
    @ObservedObject private var historyService = DependencyContainer.shared.scanHistoryService
    @State private var showingDeleteConfirmation = false
    @State private var scanToDelete: ScanRecord?
    @State private var showingClearAllConfirmation = false
    @State private var selectedFilter: HistoryFilter = .all
    @State private var searchText = ""

    enum HistoryFilter: String, CaseIterable {
        case all = "All"
        case today = "Today"
        case thisWeek = "This Week"
        case thisMonth = "This Month"
    }

    private var filteredScans: [ScanRecord] {
        var scans = historyService.recentScans

        // Apply date filter
        let calendar = Calendar.current
        let now = Date()

        switch selectedFilter {
        case .all:
            break
        case .today:
            let start = calendar.startOfDay(for: now)
            scans = scans.filter { ($0.date ?? .distantPast) >= start }
        case .thisWeek:
            if let start = calendar.date(byAdding: .day, value: -7, to: now) {
                scans = scans.filter { ($0.date ?? .distantPast) >= start }
            }
        case .thisMonth:
            if let start = calendar.date(byAdding: .month, value: -1, to: now) {
                scans = scans.filter { ($0.date ?? .distantPast) >= start }
            }
        }

        // Apply search filter
        if !searchText.isEmpty {
            scans = scans.filter { scan in
                let courseName = scan.courseName ?? ""
                return courseName.localizedCaseInsensitiveContains(searchText)
            }
        }

        return scans
    }

    var body: some View {
        NavigationView {
            Group {
                if historyService.recentScans.isEmpty {
                    emptyState
                } else {
                    scanListContent
                }
            }
            .navigationTitle("History")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Done") {
                        appState.currentScreen = .home
                    }
                }

                ToolbarItem(placement: .navigationBarTrailing) {
                    if !historyService.recentScans.isEmpty {
                        Menu {
                            Button(role: .destructive) {
                                showingClearAllConfirmation = true
                            } label: {
                                Label("Clear All History", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                }
            }
        }
        .onAppear {
            historyService.fetchRecentScans()
        }
        .alert("Delete Scan", isPresented: $showingDeleteConfirmation, presenting: scanToDelete) { scan in
            Button("Delete", role: .destructive) {
                historyService.deleteScan(scan)
            }
            Button("Cancel", role: .cancel) { }
        } message: { scan in
            Text("Are you sure you want to delete this scan from \(scan.courseName ?? "Unknown")?")
        }
        .alert("Clear All History", isPresented: $showingClearAllConfirmation) {
            Button("Clear All", role: .destructive) {
                historyService.deleteAllScans()
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("Are you sure you want to delete all \(historyService.totalScansCount) scan records? This cannot be undone.")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 20) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 60))
                .foregroundColor(.gray)

            Text("No Saved Scans")
                .font(DesignSystem.Typography.title)

            Text("Your putting analysis history will appear here after you complete scans.")
                .font(.body)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 40)

            Button(action: {
                appState.currentScreen = .scanning
            }) {
                HStack {
                    Image(systemName: "viewfinder")
                    Text("Start Scanning")
                }
                .foregroundColor(.white)
                .padding(.horizontal, 30)
                .padding(.vertical, 14)
                .background(DesignSystem.Colors.primary)
                .cornerRadius(25)
            }
            .padding(.top, 20)
        }
    }

    private var scanListContent: some View {
        VStack(spacing: 0) {
            // Filter picker
            Picker("Filter", selection: $selectedFilter) {
                ForEach(HistoryFilter.allCases, id: \.self) { filter in
                    Text(filter.rawValue).tag(filter)
                }
            }
            .pickerStyle(.segmented)
            .padding()

            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Search courses...", text: $searchText)
                    .textFieldStyle(.plain)

                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                }
            }
            .padding(10)
            .glassCard(cornerRadius: 10)
            .padding(.horizontal)
            .padding(.bottom)

            // Stats summary
            if !filteredScans.isEmpty {
                statsSummary
            }

            // Scan list
            if filteredScans.isEmpty {
                noResultsView
            } else {
                scanList
            }
        }
    }

    private var statsSummary: some View {
        HStack(spacing: 20) {
            StatView(title: "Scans", value: "\(filteredScans.count)")
            Divider().frame(height: 30)
            StatView(title: "Avg Distance", value: formattedAverageDistance)
            Divider().frame(height: 30)
            StatView(title: "Avg Confidence", value: "\(averageConfidence)%")
        }
        .padding()
        .glassCard(cornerRadius: 12)
        .padding(.horizontal)
        .padding(.bottom)
    }

    private var averageDistance: Float {
        guard !filteredScans.isEmpty else { return 0 }
        let total = filteredScans.reduce(0) { $0 + $1.distance }
        return total / Float(filteredScans.count)
    }

    private var formattedAverageDistance: String {
        if appState.settings.useMetricUnits {
            return String(format: "%.1fm", averageDistance)
        } else {
            return String(format: "%.0fft", averageDistance * 3.28084)
        }
    }

    private func formattedDistance(_ meters: Float) -> String {
        if appState.settings.useMetricUnits {
            return String(format: "%.1fm", meters)
        } else {
            return String(format: "%.0fft", meters * 3.28084)
        }
    }

    private var averageConfidence: Int {
        guard !filteredScans.isEmpty else { return 0 }
        let total = filteredScans.reduce(0) { $0 + $1.confidence }
        return Int((total / Float(filteredScans.count)) * 100)
    }

    private var noResultsView: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text("No scans match your filter")
                .font(.headline)
                .foregroundColor(.secondary)
            Spacer()
        }
    }

    private var scanList: some View {
        List {
            ForEach(filteredScans) { scan in
                scanRow(scan)
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            scanToDelete = scan
                            showingDeleteConfirmation = true
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
            }
        }
        .listStyle(.plain)
    }

    private func scanRow(_ scan: ScanRecord) -> some View {
        HStack(spacing: 12) {
            // Confidence indicator
            ZStack {
                Circle()
                    .fill(confidenceColor(scan.confidence).opacity(0.2))
                    .frame(width: 50, height: 50)

                VStack(spacing: 0) {
                    Text("\(scan.confidencePercentage)")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(confidenceColor(scan.confidence))
                    Text("%")
                        .font(.system(size: 10))
                        .foregroundColor(confidenceColor(scan.confidence))
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(scan.courseName ?? "Unknown Course")
                    .font(DesignSystem.Typography.headline)
                    .lineLimit(1)

                HStack(spacing: 8) {
                    Label("Hole \(scan.holeNumber)", systemImage: "flag.fill")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    if let date = scan.date {
                        Text(date, style: .date)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                Text(formattedDistance(scan.distance))
                    .font(.headline)
                    .foregroundColor(.green)

                Text(scan.breakDescription)
                    .font(.caption)
                    .foregroundColor(.secondary)

                Text(scan.speedDescription)
                    .pillBadge(
                        backgroundColor: speedColor(scan.recommendedSpeed),
                        foregroundColor: speedColor(scan.recommendedSpeed)
                    )
            }
        }
        .padding(.vertical, 8)
    }

    private func confidenceColor(_ confidence: Float) -> Color {
        switch confidence {
        case 0.8...:
            return .green
        case 0.6..<0.8:
            return .yellow  // Match DesignSystem.Colors.confidence definition
        default:
            return .orange
        }
    }

    private func speedColor(_ speed: String?) -> Color {
        switch speed {
        case "gentle":
            return .cyan
        case "moderate":
            return .green
        case "firm":
            return .orange
        default:
            return .green
        }
    }
}

struct StatView: View {
    let title: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.headline)
                .foregroundColor(.green)
            Text(title)
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }
}

#Preview {
    HistoryView()
        .environmentObject(AppState())
}
