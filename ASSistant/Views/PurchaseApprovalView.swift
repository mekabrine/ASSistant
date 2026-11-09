import SwiftUI

/// Human approval is tied to the merchant, product, exact total and tab.
@MainActor
struct PurchaseApprovalView: View {
    @EnvironmentObject private var store: AppStore
    @Environment(\.dismiss) private var dismiss
    let review: CheckoutSnapshot
    let onApprove: (CheckoutSnapshot) async -> String

    @State private var placing = false
    @State private var result: String?

    private var allowed: Bool {
        ShoppingPolicy.canApprove(totalCents: review.totalCents, records: store.purchases)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 17) {
                    Label("Review a real purchase", systemImage: "creditcard.circle")
                        .font(.title2).fontWeight(.bold)
                    Text("No order has been placed yet. Approving below authorizes exactly one submission of the current Amazon checkout page.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Amazon.com").font(.caption).foregroundStyle(.secondary)
                        Text(review.productName.isEmpty ? "Amazon order" : review.productName)
                            .font(.headline)
                        if !review.variant.isEmpty {
                            Text(review.variant).font(.subheadline)
                        }
                        Link("Open product listing", destination: URL(string: review.productURL)!)
                            .font(.caption)
                        Divider()
                        Text("Visible order total (shipping and taxes included when shown)")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(review.totalDescription)
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .monospacedDigit()
                        Text("The total is rechecked before pressing Place Order; a changed total requires new approval.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
                    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))

                    VStack(alignment: .leading, spacing: 6) {
                        Label("Your spending limits", systemImage: "shield.checkered")
                            .font(.headline)
                        Text("Per-order limit: \(ShoppingPolicy.currency(ShoppingPolicy.maxOrderCents))")
                        Text("Monthly limit: \(ShoppingPolicy.currency(ShoppingPolicy.monthlyCapCents))")
                        Text("Already submitted this month: \(ShoppingPolicy.currency(ShoppingPolicy.monthSpentCents(store.purchases)))")
                    }
                    .font(.subheadline)

                    if !allowed {
                        Label("This purchase is blocked by your autonomy level or spending limits. Adjust Settings → Agent autonomy to proceed.", systemImage: "lock.fill")
                            .foregroundStyle(.orange)
                    }

                    if let result {
                        Text(result)
                            .textSelection(.enabled)
                            .padding(13)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    } else {
                        Button {
                            placing = true
                            Task {
                                result = await onApprove(review)
                                placing = false
                            }
                        } label: {
                            HStack {
                                if placing { ProgressView().tint(.white) }
                                Label("Approve and place order · \(review.totalDescription)",
                                      systemImage: "checkmark.shield.fill")
                            }
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(10)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.cyan)
                        .disabled(!allowed || placing)
                        Button("Not now") { dismiss() }
                            .frame(maxWidth: .infinity)
                            .buttonStyle(.bordered)
                    }
                    Text("ASSistant cannot guarantee Amazon accepts automated checkout. If confirmation is unclear, it records an unverified submission and will never retry automatically. Inspect Your Orders before attempting another purchase.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding()
            }
            .navigationTitle("Purchase approval")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.disabled(placing)
                }
            }
        }
    }
}
