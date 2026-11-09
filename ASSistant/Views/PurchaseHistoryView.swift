import SwiftUI

/// Purchase records are a log, not a live Amazon order-management API.
/// Cancellation is handled on Amazon's authenticated Your Orders page.
@MainActor
struct PurchaseHistoryView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var browser = BrowserWorkspace.shared
    @State private var orderBrowserOpen = false
    @State private var selectedToMarkCanceled: PurchaseRecord?
    @State private var errorMessage = ""
    @State private var filter = "All"

    private var filteredPurchases: [PurchaseRecord] {
        store.purchases.filter { record in
            switch filter {
            case "Confirmed": return record.status == "confirmed"
            case "Unverified": return record.status == "submissionUnverified"
            case "Canceled": return record.status == "canceledUserReported"
            default: return true
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if store.purchases.isEmpty {
                    ContentUnavailablePurchases()
                } else {
                    Section {
                        HStack {
                            Label("\(store.purchases.count) purchase records",
                                  systemImage: "shippingbox")
                            Spacer()
                            Text("This month: " +
                                ShoppingPolicy.currency(
                                    ShoppingPolicy.monthSpentCents(store.purchases)))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Picker("Filter", selection: $filter) {
                            ForEach(["All", "Confirmed", "Unverified", "Canceled"],
                                    id: \.self) { option in
                                Text(option).tag(option)
                            }
                        }
                        .pickerStyle(.segmented)
                    }
                    ForEach(filteredPurchases) { record in
                        purchaseRow(record)
                    }
                }
                Section("Manage Amazon orders") {
                    Button {
                        openOrderHistory()
                    } label: {
                        Label("Open Amazon Your Orders", systemImage: "arrow.up.right.square")
                    }
                    Text("Amazon determines which orders can be canceled or returned. Opening Your Orders does not cancel anything automatically. Check the status on Amazon before marking a record canceled.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if !errorMessage.isEmpty {
                    Text(errorMessage).font(.footnote).foregroundStyle(.orange)
                }
            }
            .navigationTitle("Purchases")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .confirmationDialog("Mark this purchase canceled?", isPresented:
                Binding(get: { selectedToMarkCanceled != nil },
                        set: { if !$0 { selectedToMarkCanceled = nil } }),
                titleVisibility: .visible) {
                Button("I confirmed cancellation with Amazon") {
                    if var value = selectedToMarkCanceled {
                        value.status = "canceledUserReported"
                        value.updatedAt = .now
                        value.note = "User reported cancellation; not independently verified via Amazon."
                        store.save(value)
                    }
                    selectedToMarkCanceled = nil
                }
                Button("Never mind", role: .cancel) { selectedToMarkCanceled = nil }
            } message: {
                Text("Only mark this after Amazon confirms the cancellation in Your Orders. ASSistant cannot cancel an order merely by updating this local record.")
            }
            .fullScreenCover(isPresented: $orderBrowserOpen) {
                BrowserFullScreenView(workspace: browser)
            }
        }
    }

    private func purchaseRow(_ record: PurchaseRecord) -> some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(record.productName)
                        .font(.headline)
                    Text("\(record.merchant) · \(record.createdAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                Text(ShoppingPolicy.currency(record.totalCents, code: record.currency))
                    .font(.headline).monospacedDigit()
            }
            if !record.variant.isEmpty || !record.description.isEmpty {
                Text([record.variant, record.description].filter { !$0.isEmpty }
                    .joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
            HStack(spacing: 5) {
                Image(systemName: icon(for: record.status))
                Text(statusTitle(record.status))
            }
            .font(.caption).fontWeight(.semibold)
            .foregroundStyle(record.status == "confirmed" ? Color.green : Color.orange)

            if let orderID = record.orderID {
                Text("Order #\(orderID)").font(.caption).textSelection(.enabled)
            }
            HStack(spacing: 12) {
                if let productURL = URL(string: record.productURL),
                   BrowserSession.safeURL(record.productURL) != nil {
                    Link(destination: productURL) {
                        Label("Product", systemImage: "shippingbox")
                    }
                    .font(.caption)
                }
                Button {
                    openOrderHistory(preferredURL: record.orderURL)
                } label: {
                    Label("Cancel / Return", systemImage: "arrow.uturn.backward.circle")
                }
                .font(.caption)
                Spacer()
                Menu {
                    if record.status != "canceledUserReported" {
                        Button {
                            selectedToMarkCanceled = record
                        } label: {
                            Label("Mark canceled after Amazon confirmation",
                                  systemImage: "checkmark.circle")
                        }
                    }
                    if let orderURL = record.orderURL, let url = URL(string: orderURL),
                       BrowserSession.safeURL(orderURL) != nil {
                        Link(destination: url) {
                            Label("View order details", systemImage: "doc.text")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            .buttonStyle(.bordered)
        }
        .padding(.vertical, 8)
    }

    private func icon(for state: String) -> String {
        switch state {
        case "confirmed": return "checkmark.seal.fill"
        case "canceledUserReported": return "xmark.circle"
        case "submissionUnverified": return "questionmark.circle"
        case "notSubmitted": return "xmark.shield"
        default: return "clock"
        }
    }

    private func statusTitle(_ state: String) -> String {
        switch state {
        case "confirmed": return "Confirmed by retailer"
        case "submissionUnverified": return "Submission not verified — check Your Orders"
        case "canceledUserReported": return "Canceled (reported by you)"
        case "prepared": return "Prepared — not purchased"
        case "notSubmitted": return "Order not submitted"
        default: return state
        }
    }

    private func openOrderHistory(preferredURL: String? = nil) {
        // Use ASSistant's signed-in WebKit state and open verified order details
        // when possible; fall back to the retailer's standard order history.
        let official = "https://www.amazon.com/gp/your-account/order-history"
        let destination: String
        if let preferredURL, let candidate = BrowserSession.safeURL(preferredURL),
           ShoppingPolicy.amazonHost(candidate),
           candidate.path.contains("order-details") {
            destination = candidate.absoluteString
        } else { destination = official }
        orderBrowserOpen = true
        browser.fullScreen = true
        let tab = browser.newBrowser()
        Task {
            do {
                _ = try await tab.navigate(destination)
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}

private struct ContentUnavailablePurchases: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("No recorded purchases", systemImage: "bag")
                .font(.headline)
            Text("When you approve a checkout in ASSistant, it records the product, total, date, and verification status here. These records may sync if you enabled iCloud for app data.")
                .font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
    }
}
