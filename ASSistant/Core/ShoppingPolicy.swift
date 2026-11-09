import Foundation

/// The slider controls which supported website actions the assistant may
/// attempt. Every order submission still needs approval of that exact total.
enum ShoppingPolicy {
    static var level: Int {
        max(0, min(4, UserDefaults.standard.object(forKey: "shoppingAutonomyLevel") as? Int ?? 1))
    }

    static var maxOrderCents: Int {
        let dollars = UserDefaults.standard.object(forKey: "shoppingOrderCap") as? Double ?? 250
        return Int((max(1, min(100_000, dollars)) * 100).rounded())
    }

    static var monthlyCapCents: Int {
        let dollars = UserDefaults.standard.object(forKey: "shoppingMonthlyCap") as? Double ?? 500
        return Int((max(1, min(100_000, dollars)) * 100).rounded())
    }

    static let levelNames = [
        "Research only",
        "Pick product options",
        "Manage the cart",
        "Prepare checkout",
        "Purchase with approval"
    ]

    static func requiredLevel(for tool: String) -> Int {
        switch tool {
        case "browser_select_variant": return 1
        case "browser_add_to_cart": return 2
        case "browser_prepare_checkout", "browser_checkout_review": return 3
        case "browser_place_order": return 4
        default: return 0
        }
    }

    static func canRun(_ tool: String) -> Bool {
        level >= requiredLevel(for: tool)
    }

    static func amazonHost(_ url: URL?) -> Bool {
        guard let host = url?.host?.lowercased() else { return false }
        return host == "amazon.com" || host == "www.amazon.com"
    }

    static func explicitIntent(_ tool: String, prompt: String) -> Bool {
        let p = prompt.lowercased()
        let buying = ["buy ", "buy now", "purchase ", "make a purchase",
                      "order ", "place order", "checkout", "check out", "pay for "]
            .contains(where: p.contains)
        switch tool {
        case "browser_select_variant":
            return buying || ["select ", "choose ", "pick ", "color ", "colour ",
                              "size ", "variation ", "variant "].contains(where: p.contains)
        case "browser_add_to_cart":
            return buying || ["add to cart", "put in cart", "add it to my cart",
                              "cart it"].contains(where: p.contains)
        case "browser_prepare_checkout", "browser_checkout_review", "browser_place_order":
            return buying
        default: return true
        }
    }

    static func monthSpentCents(_ records: [PurchaseRecord]) -> Int {
        let start = Calendar.current.dateInterval(of: .month, for: .now)?.start ?? .distantPast
        return records.filter {
            $0.createdAt >= start && ["confirmed", "submissionUnverified"].contains($0.status)
        }.reduce(0) { $0 + max(0, $1.totalCents) }
    }

    static func canApprove(totalCents: Int, records: [PurchaseRecord]) -> Bool {
        guard level == 4, totalCents > 0, totalCents <= maxOrderCents else { return false }
        return monthSpentCents(records) + totalCents <= monthlyCapCents
    }

    static func currency(_ cents: Int, code: String = "USD") -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = Locale(identifier: "en_US")
        formatter.currencyCode = code
        return formatter.string(from: NSNumber(value: Double(cents) / 100)) ??
            "\(code) \(Double(cents) / 100)"
    }

    /// For now automated commerce is explicitly limited to Amazon US.
    /// Other merchants use the existing human-control handoff.
    static func supportedMerchant(_ url: URL?) -> Bool {
        amazonHost(url)
    }
}

/// A stable browser goal checked after each model response. The browser must
/// actually reach requested end states, not simply produce a plausible answer.
struct ShoppingGoal {
    let needsProductPage: Bool
    let color: String?
    let size: String?
    let needsCart: Bool
    let needsCheckout: Bool

    init(prompt: String) {
        let p = prompt.lowercased()
        needsProductPage = ["open the product", "open its page", "open the page",
                            "open a product", "product page", "go to the listing",
                            "open the listing"].contains(where: p.contains)
        func requested(_ labels: [String]) -> String? {
            guard let word = labels.first(where: { p.contains($0) }) else { return nil }
            let remaining = p.components(separatedBy: word).dropFirst().first ?? ""
            let clean = remaining.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
                .prefix(3).map(String.init)
            return clean.first(where: { !["the", "a", "to", "as", "option", "named"].contains($0) })
        }
        color = requested(["color ", "colour "])
        size = requested(["size "])
        needsCart = ["add to cart", "add it to cart", "put in cart", "put it in my cart"]
            .contains(where: p.contains)
        needsCheckout = ["place order", "place the order", "buy it", "buy now",
                         "buy me", "purchase it",
                         "purchase the", "purchase me", "buy the ", "buy a ",
                         "order the ", "order me", "checkout for",
                         "check out and buy"].contains(where: p.contains)
    }

    @MainActor
    func missing(in tab: BrowserSession) -> [String] {
        var result: [String] = []
        if needsProductPage && !tab.isAmazonProductPage {
            result.append("Open and verify the product detail page.")
        }
        if let color, tab.selectedVariants["color"]?.lowercased() != color {
            result.append("Select and verify color \(color).")
        }
        if let size, tab.selectedVariants["size"]?.lowercased() != size {
            result.append("Select and verify size \(size).")
        }
        if needsCart && !tab.addedToCart {
            result.append("Add the selected product to the cart and verify that it was added.")
        }
        if needsCheckout && !tab.orderSubmissionRequested {
            result.append("Prepare checkout, obtain a verified total, then request order approval.")
        }
        return result
    }

    var hasShoppingObjectives: Bool {
        needsProductPage || color != nil || size != nil || needsCart || needsCheckout
    }
}
