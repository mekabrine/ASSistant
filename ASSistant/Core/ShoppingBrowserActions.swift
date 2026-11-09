import Foundation
import WebKit

enum ShoppingBrowserError: LocalizedError {
    case unsupportedMerchant, missingProduct, missingVariant, cartUnverified
    case notCheckout, missingTotal, missingOrderButton, priceChanged
    case alreadySubmitted, forbiddenAction, missingApproval, invalidResponse

    var errorDescription: String? {
        switch self {
        case .unsupportedMerchant: return "Automatic shopping currently supports Amazon.com only. Use the browser handoff on other stores."
        case .missingProduct: return "Open an Amazon product detail page first."
        case .missingVariant: return "The requested color or size is not selectable or could not be verified."
        case .cartUnverified: return "Cart change was not verified. Check the cart manually before attempting it again."
        case .notCheckout: return "Open Amazon's final order review page before placing an order."
        case .missingTotal: return "Could not verify an exact USD order total. Finish checkout manually."
        case .missingOrderButton: return "No recognized Amazon Place Order button was found. Finish checkout manually."
        case .priceChanged: return "The order total or review page changed. Recheck and approve the new total."
        case .alreadySubmitted: return "Order submission was already attempted on this page. Check Your Orders instead of retrying."
        case .forbiddenAction: return "This browser action is outside the selected shopping autonomy level."
        case .missingApproval: return "The order requires your explicit approval of the merchant and exact total."
        case .invalidResponse: return "The website did not provide a verifiable response."
        }
    }
}

struct CheckoutSnapshot: Identifiable, Equatable {
    let id: UUID
    let tabID: UUID
    let checkoutURL: String
    let productURL: String
    let productName: String
    let productDescription: String
    let variant: String
    let quantity: Int
    let currency: String
    let totalCents: Int
    let orderButtonSelector: String
    let capturedAt: Date

    var totalDescription: String {
        ShoppingPolicy.currency(totalCents, code: currency)
    }
}

struct PurchaseSubmissionResult {
    let status: String
    let orderID: String?
    let orderURL: String?
    let explanation: String
}

@MainActor
extension BrowserSession {
    private func requireAmazon() throws {
        guard ShoppingPolicy.amazonHost(web.url) else { throw ShoppingBrowserError.unsupportedMerchant }
        guard !userControl else { throw BrowserFailure.userTookControl }
    }

    private func shoppingDictionary(_ source: String) async throws -> [String: Any] {
        let value = try await web.evaluateJavaScript(source)
        guard let dict = value as? [String: Any] else { throw ShoppingBrowserError.invalidResponse }
        return dict
    }

    /// Select an actual Amazon variation control rather than asking the model
    /// to emit arbitrary JavaScript, CSS selectors, or form field values.
    func selectVariant(category: String, value: String) async throws -> String {
        try requireAmazon()
        guard isAmazonProductPage else { throw ShoppingBrowserError.missingProduct }
        let key = category.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let choice = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["color", "size", "style", "quantity"].contains(key), !choice.isEmpty,
              choice.count <= 60, !choice.contains("<") else {
            throw ShoppingBrowserError.missingVariant
        }
        let args = try String(decoding: JSONSerialization.data(withJSONObject: [
            "key": key, "value": choice
        ]), as: UTF8.self)
        let js = #"""
        args => {
          const key=args.key, wanted=args.value.toLowerCase().trim();
          const root=key==='quantity'
            ?document.querySelector('#quantity,#quantityDropdown')
            :document.querySelector('#variation_'+key+'_name');
          if(!root)return {ok:false,reason:'Variation widget not found'};
          const visible=e=>!!(e.getClientRects().length);
          const select=root.matches('select')?root:root.querySelector('select');
          window.__assistantAutomation=true;
          try {
            if(select) {
              const option=[...select.options].find(o=>
                o.textContent.toLowerCase().trim()===wanted ||
                o.textContent.toLowerCase().includes(wanted));
              if(!option)return {ok:false,reason:'Option not found'};
              select.value=option.value;
              select.dispatchEvent(new Event('input',{bubbles:true}));
              select.dispatchEvent(new Event('change',{bubbles:true}));
              return {ok:true,kind:'select'};
            }
            const cells=[...root.querySelectorAll('li,[role="option"],button,label')].filter(visible);
            const match=cells.find(el=>{
              const label=[el.getAttribute('title'),el.getAttribute('aria-label'),
                el.textContent,el.querySelector('img')?.getAttribute('alt')]
                .filter(Boolean).join(' ').toLowerCase().trim();
              return label===wanted || label.includes(wanted);
            });
            if(!match)return {ok:false,reason:'Variation not available'};
            const action=match.querySelector('button,input[type="radio"],a')||match;
            action.click();
            return {ok:true,kind:'swatch'};
          } finally {window.__assistantAutomation=false}
        }
        """#
        let result = try await shoppingDictionary("(" + js + ")(" + args + ")")
        guard result["ok"] as? Bool == true else { throw ShoppingBrowserError.missingVariant }
        try Task.checkCancellation()
        try await Task.sleep(nanoseconds: 1_350_000_000)
        let check = #"""
        args => {
          const root=args.key==='quantity'
            ?document.querySelector('#quantity,#quantityDropdown')
            :document.querySelector('#variation_'+args.key+'_name');
          if(!root)return {verified:false};
          const select=root.matches('select')?root:root.querySelector('select');
          const selected=select?.selectedOptions?.[0] ||
            root.querySelector('.a-button-selected,li.selected,[aria-selected="true"]');
          const label=[selected?.getAttribute('title'),selected?.getAttribute('aria-label'),
            selected?.textContent,selected?.querySelector('img')?.getAttribute('alt')]
            .filter(Boolean).join(' ').toLowerCase();
          return {verified:label.includes(args.value.toLowerCase().trim())};
        }
        """#
        let verified = try await shoppingDictionary("(" + check + ")(" + args + ")")
        guard verified["verified"] as? Bool == true else {
            throw ShoppingBrowserError.missingVariant
        }
        selectedVariants[key] = choice
        let observation = try await read()
        return "Verified selected \(key): \(choice).\n" + observation
    }

    /// Only Amazon's Add to Cart control, never Buy Now or Place Order.
    func addToCart() async throws -> String {
        try requireAmazon()
        guard isAmazonProductPage else { throw ShoppingBrowserError.missingProduct }
        let js = #"""
        (() => {
          const selectors=['#add-to-cart-button','#add-to-cart-button-ubb',
            'input[name="submit.add-to-cart"]'];
          const element=selectors.map(s=>document.querySelector(s)).find(e=>
            e && e.getClientRects().length && !e.disabled);
          if(!element)return {ok:false};
          window.__assistantAutomation=true;
          try {element.click()} finally {window.__assistantAutomation=false}
          return {ok:true};
        })()
        """#
        let clicked = try await shoppingDictionary(js)
        guard clicked["ok"] as? Bool == true else { throw ShoppingBrowserError.cartUnverified }
        try await Task.sleep(nanoseconds: 1_600_000_000)
        let verified = try await shoppingDictionary(#"""
        (() => {
          const text=(document.body?.innerText||'').toLowerCase();
          const marker=document.querySelector(
            '#huc-v2-order-row-confirm-text,#sw-atc-confirmation,' +
            '#NATC_SMART_WAGON_CONF_MSG_SUCCESS,#attachDisplayAddBaseAlert');
          return {ok:!!(marker && marker.getClientRects().length) ||
            /added to (your |the )?cart|item added to cart/.test(text.slice(0,6000))};
        })()
        """#)
        if verified["ok"] as? Bool == true {
            addedToCart = true
            return "Amazon displayed an Add to Cart confirmation. " +
                ((try? await read()) ?? "The item was added.")
        }
        // Do not retry automatically: the click may have already succeeded.
        return "Clicked Add to Cart but the website did not show a recognizable confirmation. " +
               "Do NOT click it again automatically; inspect the cart or ask the user."
    }

    func prepareCheckout() async throws -> String {
        try requireAmazon()
        if !(web.url?.path.lowercased().contains("/checkout") == true ||
             web.url?.path.lowercased().contains("/gp/buy/") == true) {
            _ = try await navigate("https://www.amazon.com/gp/cart/view.html")
        }
        let js = #"""
        (() => {
          const path=location.pathname.toLowerCase();
          if(path.includes('/checkout') || path.includes('/gp/buy/'))
            return {ok:true,already:true};
          const selectors=['#sc-buy-box-ptc-button input',
            '#sc-buy-box-ptc-button button','#sc-buy-box-ptc-button',
            'input[name="proceedToRetailCheckout"]'];
          const btn=selectors.map(s=>document.querySelector(s)).find(e=>
            e && e.getClientRects().length && !e.disabled);
          if(!btn)return {ok:false};
          const text=(btn.value||btn.innerText||btn.closest('span')?.innerText||'').toLowerCase();
          if(!text.includes('checkout') && !text.includes('proceed')) return {ok:false};
          window.__assistantAutomation=true;
          try {btn.click()} finally {window.__assistantAutomation=false}
          return {ok:true,already:false};
        })()
        """#
        let result = try await shoppingDictionary(js)
        guard result["ok"] as? Bool == true else {
            requestHuman("Amazon's checkout entry button was not available. Continue checkout in this browser, then return control to ASSistant.")
            return "Human assistance needed to open Amazon checkout."
        }
        if result["already"] as? Bool != true {
            try await Task.sleep(nanoseconds: 1_500_000_000)
        }
        return "Opened Amazon checkout (not submitted). " +
            ((try? await read()) ?? "Review the live browser to continue.")
    }

    /// Only visible checkout information. NEVER read payment credentials,
    /// shipping addresses, saved cards, names, passwords, or input field values.
    func inspectCheckout() async throws -> CheckoutSnapshot {
        try requireAmazon()
        let js = #"""
        (() => {
          const path=location.pathname.toLowerCase();
          if(!path.includes('/checkout') && !path.includes('/gp/buy/'))return {ok:false,why:'notCheckout'};
          const selectors=[
            'input[name="placeYourOrder1"]',
            '#submitOrderButtonId input',
            '#submitOrderButtonId .a-button-input',
            '#bottomSubmitOrderButtonId input',
            '#placeYourOrder',
            '[data-testid="place-order-button"]'
          ];
          let selector='';
          for(const sel of selectors){
            const candidate=document.querySelector(sel);
            if(candidate && candidate.getClientRects().length && !candidate.disabled) {
              const label=(candidate.value||candidate.getAttribute('aria-label')||
                candidate.closest('span')?.innerText||candidate.innerText||'').toLowerCase();
              if(label.includes('place') && label.includes('order') ||
                 label.includes('buy now')){selector=sel;break;}
            }
          }
          if(!selector) {
            // Some Amazon checkout layouts render a semantic button without
            // one of the historical IDs. Limit fallback to explicitly named,
            // visible submit controls on the verified checkout page.
            const candidates=[...document.querySelectorAll(
              'button,input[type="submit"],[role="button"]'
            )];
            const found=candidates.find(e=>{
              if(!e.getClientRects().length || e.disabled)return false;
              const label=(e.value||e.getAttribute('aria-label')||
                e.innerText||'').trim().toLowerCase();
              return /^(place (your |the )?order|buy now)(\b|\s)/i.test(label);
            });
            if(found){
              found.setAttribute('data-assistant-order-submit','true');
              selector='[data-assistant-order-submit="true"]';
            }
          }
          if(!selector)return {ok:false,why:'missingButton'};
          const sources=[...document.querySelectorAll(
            '#subtotals-marketplace-table,.grand-total-price,#orderSummary,'+
            '[data-testid="order-summary"],#order-summary,[class*="grand-total"]'
          )].map(e=>e.innerText||'');
          sources.push(document.body?.innerText?.slice(0,24000)||'');
          let total='';
          for(const source of sources){
            const match=source.match(/(?:order\s*total|grand\s*total)\s*:?\s*(?:USD\s*)?(\$\s*[\d,]+\.\d{2})/i);
            if(match){total=match[1];break;}
          }
          const item=document.querySelector('a[href*="/dp/"],a[href*="/gp/product/"]');
          const product=item?.href||'';
          const name=(document.querySelector('#spc-orders')?.innerText||
            document.querySelector('#order-summary')?.innerText||
            document.title||'').slice(0,160);
          return {ok:!!total,why:total?'':'missingTotal',total:total,
            button:selector,product:product,name:name};
        })()
        """#
        let result = try await shoppingDictionary(js)
        if result["why"] as? String == "notCheckout" { throw ShoppingBrowserError.notCheckout }
        if result["why"] as? String == "missingButton" { throw ShoppingBrowserError.missingOrderButton }
        guard result["ok"] as? Bool == true,
              let formatted = result["total"] as? String else { throw ShoppingBrowserError.missingTotal }
        let digits = formatted.replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let decimal = Decimal(string: digits, locale: Locale(identifier: "en_US_POSIX")),
              decimal > 0 else { throw ShoppingBrowserError.missingTotal }
        let number = NSDecimalNumber(decimal: decimal)
        let cents = number.multiplying(by: 100).intValue
        guard cents > 0 else { throw ShoppingBrowserError.missingTotal }
        let rawProduct = result["product"] as? String ?? ""
        let productCandidate = Self.safeURL(lastProductURL) ??
            Self.safeURL(rawProduct)
        guard let product = productCandidate,
              ShoppingPolicy.amazonHost(product) else {
            throw ShoppingBrowserError.missingProduct
        }
        let productURL = product.absoluteString
        let variant = selectedVariants.keys.sorted().compactMap { key in
            selectedVariants[key].map { "\(key): \($0)" }
        }.joined(separator: ", ")
        let button = result["button"] as? String ?? ""
        guard !button.isEmpty else { throw ShoppingBrowserError.missingOrderButton }
        return CheckoutSnapshot(
            id: UUID(), tabID: id, checkoutURL: web.url?.absoluteString ?? "",
            productURL: productURL, productName: String((lastProductTitle.isEmpty
                ? (result["name"] as? String ?? title) : lastProductTitle).prefix(160)),
            productDescription: String(lastProductDescription.prefix(450)),
            variant: variant,
            quantity: Int(selectedVariants["quantity"] ?? "1") ?? 1,
            currency: "USD", totalCents: cents,
            orderButtonSelector: button, capturedAt: .now
        )
    }

    /// Called only from a deliberate human approval gesture for the exact
    /// displayed order. Revalidates merchant, page URL and total immediately.
    /// Click happens once; ambiguous outcomes must never be auto-retried.
    func submitApprovedOrder(_ approved: CheckoutSnapshot) async throws -> PurchaseSubmissionResult {
        try requireAmazon()
        guard ShoppingPolicy.level == 4,
              approved.totalCents > 0,
              approved.totalCents <= ShoppingPolicy.maxOrderCents else {
            throw ShoppingBrowserError.forbiddenAction
        }
        guard !orderSubmissionAttempted else { throw ShoppingBrowserError.alreadySubmitted }
        guard approved.tabID == id,
              Date().timeIntervalSince(approved.capturedAt) < 300,
              !approved.checkoutURL.isEmpty else { throw ShoppingBrowserError.missingApproval }
        let current = try await inspectCheckout()
        guard current.checkoutURL == approved.checkoutURL,
              current.totalCents == approved.totalCents,
              current.currency == approved.currency,
              current.productURL == approved.productURL,
              current.orderButtonSelector == approved.orderButtonSelector else {
            throw ShoppingBrowserError.priceChanged
        }
        let selector = approved.orderButtonSelector
        let allowed = ["input[name=\"placeYourOrder1\"]", "#submitOrderButtonId input",
            "#submitOrderButtonId .a-button-input", "#bottomSubmitOrderButtonId input",
            "#placeYourOrder", "[data-testid=\"place-order-button\"]",
            "[data-assistant-order-submit=\"true\"]"]
        guard allowed.contains(selector) else { throw ShoppingBrowserError.missingOrderButton }
        let encoded = String(decoding: try JSONEncoder().encode(selector), as: UTF8.self)
        orderSubmissionAttempted = true
        orderSubmissionRequested = true
        let js = #"""
        selector => {
          const button=document.querySelector(selector);
          if(!button || !button.getClientRects().length || button.disabled)return false;
          window.__assistantAutomation=true;
          try {button.click()}finally{window.__assistantAutomation=false}
          return true;
        }
        """#
        let clicked: Bool
        do {
            clicked = (try await web.evaluateJavaScript("(" + js + ")(" + encoded + ")")) as? Bool == true
        } catch {
            // JavaScript can throw *after* submitting due to navigation.
            // Treat this as unverified rather than retrying a possibly placed order.
            return PurchaseSubmissionResult(status: "submissionUnverified", orderID: nil,
                orderURL: nil, explanation:
                "Order action may have been submitted but verification failed. Check Amazon Your Orders before doing anything else.")
        }
        guard clicked else {
            orderSubmissionAttempted = false
            orderSubmissionRequested = false
            throw ShoppingBrowserError.missingOrderButton
        }
        for _ in 0..<4 {
            // A canceled task after a payment click must still return an
            // unverified outcome; it must not erase the attempted order log.
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            if Task.isCancelled { break }
            let observation = try? await shoppingDictionary(#"""
            (() => {
              const text=(document.body?.innerText||'').slice(0,12000);
              const href=location.href;
              const confirmed=/your order has been placed|thank you for your order|order confirmed|order placed successfully/i.test(text) ||
                /\/thankyou|\/order-confirmation/.test(location.pathname.toLowerCase());
              const order=(text.match(/\b\d{3}-\d{7}-\d{7}\b/)||[])[0]||'';
              const link=[...document.querySelectorAll('a[href]')].find(a=>
                a.href.includes('order-details') && a.href.startsWith('https://'));
              return {confirmed,order,orderURL:link?.href||'',url:href};
            })()
            """#)
            if observation?["confirmed"] as? Bool == true {
                let orderID = observation?["order"] as? String
                let orderURL = Self.safeURL(observation?["orderURL"] as? String ?? "")?.absoluteString ??
                    "https://www.amazon.com/gp/your-account/order-history"
                return PurchaseSubmissionResult(status: "confirmed",
                    orderID: orderID?.isEmpty == true ? nil : orderID, orderURL: orderURL,
                    explanation: "Amazon displayed an order confirmation. Review Your Orders to manage delivery or cancellation.")
            }
        }
        return PurchaseSubmissionResult(status: "submissionUnverified", orderID: nil,
            orderURL: "https://www.amazon.com/gp/your-account/order-history",
            explanation: "The Place Order control was pressed, but no final confirmation was observed. Check Your Orders before retrying.")
    }
}
