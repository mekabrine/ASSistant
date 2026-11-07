import SwiftUI

struct AgentActivityView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var displayed: [ToolAudit] {
        store.audits.filter {
            query.isEmpty || $0.tool.localizedCaseInsensitiveContains(query) ||
            $0.result.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        Label("Recorded actions", systemImage: "bolt.horizontal.circle")
                        Spacer()
                        Text("\(store.audits.count)").foregroundStyle(.secondary)
                    }
                    Text("Browser navigation is automatic only when this agent has web access enabled. Other device actions require approval. Website content is untrusted and cannot authorize purchases, messages or account changes.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Recent activity") {
                    if displayed.isEmpty {
                        VStack(spacing: 7) {
                            Image(systemName: "clock.arrow.circlepath").font(.title2)
                            Text("No actions yet").font(.headline)
                            Text("Web searches and approved tools appear here.").font(.caption)
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding()
                    }
                    ForEach(displayed) { audit in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 6) {
                                Image(systemName: audit.tool.hasPrefix("browser") ? "globe" : "hand.tap")
                                    .foregroundStyle(audit.approved ? Color.cyan : Color.orange)
                                Text(audit.tool.replacingOccurrences(of: "_", with: " ").capitalized)
                                    .font(.subheadline).fontWeight(.semibold)
                                Spacer()
                                Text(audit.timestamp, style: .time).font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                            if !audit.detail.isEmpty {
                                Text(audit.detail).font(.caption).lineLimit(3)
                            }
                            Text(audit.result)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .lineLimit(10)
                        }
                        .padding(.vertical, 5)
                    }
                }
                Section {
                    Text("To reset this history, swipe an action left. The AI never receives this audit automatically unless its relevant history is deliberately included.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .searchable(text: $query)
            .scrollContentBackground(.hidden)
            .background(AmbientBackground())
            .navigationTitle("Agent Activity")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
