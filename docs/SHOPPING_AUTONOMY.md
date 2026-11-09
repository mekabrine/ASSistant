# Shopping autonomy, Amazon checkout and purchase ledger

This document describes source implemented on \`main\`. A new manual GitHub Actions run and real-device tests are still required before treating the checkout path as verified.

## Settings → Agent autonomy and shopping

The five-level slider is **enforced in the agent tool dispatcher**:

| Level | Agent may do automatically |
| --- | --- |
| 0 · Research only | Read public websites, search, open pages, compare products |
| 1 · Pick product options | Level 0 plus supported Amazon color/size/style/quantity selections |
| 2 · Manage the cart | Level 1 plus supported Add to Cart controls |
| 3 · Prepare checkout | Level 2 plus Amazon cart → checkout and read-only final-order total |
| 4 · Purchase with approval | Level 3 plus request a one-time **human confirmation** of the verified Amazon checkout total |

**No slider setting authorizes silent spending.** Even Level 4 requires the user to approve a specific merchant, product and live final total. The browser compares the total, product URL, button, and checkout URL again immediately before submission. A new price or page requires a new review; a CAPTCHA or login requires user handoff. Existing payment details stay inside the website and are not copied into the model's context.

The user can configure per-order and monthly caps (USD). Confirmed and *unverified* submitted-order attempts both count against the monthly budget until the user has resolved them. Purchases outside a supported merchant/site or outside enabled web permissions are blocked, regardless of model instructions.

The user must expressly request cart/checkout/purchase actions. Merely asking for comparisons never authorizes checkout.

## Browser completeness and early-stop fix

- Real task end-state checks distinguish finding a search result from actually opening a product, selecting a color/size, adding to cart, and requesting an order review.
- When the assistant answers too early, it has bounded correction turns to complete missing actions. The maximum agent action budget is configurable up to 40.
- Only genuine user interaction events trigger human takeover. Agent-driven programmatic link navigation should no longer be treated automatically as a user tap.
- Amazon searches open Amazon.com directly first. If CAPTCHA/search blocking occurs, fallback attempts Google, Bing and DuckDuckGo before requesting the human to solve a challenge.
- Amazon selection, cart, checkout and order controls are narrow DOM allowlists, not arbitrary model-generated JavaScript or account-form filling. Storefront changes may require selector updates.

Example end-to-end test prompt:

> Open Amazon.com, search for a pink phone case, open a specific product page, select the pink option, add it to my cart, and prepare checkout.

At Level 3 the agent should proceed through checkout review **without spending**. At Level 4, if the user explicitly asks to buy it and Amazon's live review is readable, the app should show a purchase-approval sheet.

## Settings → Purchases

Each purchase attempt is saved in the app's existing Core Data record store with:

- Exact total in integer cents and currency, quantity, product title, public product description and product URL
- Chat ID, date/time, retailer, verified variation(s)
- Status: confirmed, submitted but unverified, not submitted, or user-reported canceled
- Observed order ID and order-details URL when the site provides them

A log entry is written **before the authorized submission** to avoid disappearing entirely if the app terminates during checkout. Only an observed retailer confirmation may mark an entry confirmed; pressing Place Order is not sufficient. Unverified outcomes should not be retried automatically. First inspect the retailer's **Your Orders** page to prevent accidental duplicate charges.

The **Cancel / Return** button opens the relevant order details (when known), otherwise Amazon Your Orders, inside ASSistant's signed-in WebKit browser. It does not imply a cancellation has happened. Amazon controls eligibility, cancellation acceptance, returns and refunds. Marking an entry canceled manually labels it **user reported**, not retailer verified.

Purchase records may sync with iCloud when the app's existing optional CloudKit setting is enabled. No credit card numbers, account tokens, passwords, PINs, shipping addresses, or verification codes are deliberately saved to purchase records or transmitted as shopping observations.

## Required QA before relying on it

- [ ] Fresh manual workflow build and simulator tests; no Actions run is triggered by the code change.
- [ ] Verify the slider gates **the actual tool execution** for all five levels, not just agent prompts.
- [ ] Test a request that previously stopped one action early: Amazon search → product detail page → pink variation. Confirm the last action executes and is verified.
- [ ] Confirm manually clicking links takes control, while an agent-driven variation click does not.
- [ ] Test wrong variant, unavailable option, failed Add to Cart confirmation, missing checkout entry button and interrupted navigation.
- [ ] Test storefront changes, dynamic checkout pages, CAPTCHA, login/2FA and automatic search fallbacks.
- [ ] At level 4, verify the final total and merchant appear in approval UI, that a changed price rejects the approval, and that a refusal does not press any checkout button.
- [ ] Use an authorized low-value real order **only after consenting to a real charge**, and verify confirmation/order ID and purchase ledger. Don't test Place Order on a real site without intending to buy.
- [ ] Simulate an ambiguous confirmation, background termination and network loss; confirm status remains unverified and no automatic retry occurs.
- [ ] Check that per-order and monthly limits block exceeding orders and that canceled/unverified statuses are clearly distinguished.
- [ ] Open Cancel / Return to the logged-in order page. Confirm that only the retailer can actually cancel or return the order.
- [ ] Run the app on iPhone (WebKit may show mobile-specific Amazon markup) and iPad. Amazon controls change without notice.

## What is not claimed

This is best-effort in-app browser automation, **not** an official Amazon buyer-order API. It does not guarantee current prices, availability, reliable checkout success, cancellation, or compatibility with every Amazon layout. Unsupported merchants, protected page actions, CAPTCHA, payment authentication, and missing order totals require human handling. The iOS app cannot continuously browse or transact in the background.
