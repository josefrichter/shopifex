# Shopifex 3.0 Readiness Implementation Plan

## Summary

Bring 3.0.0 in line with Shopify's current embedded-app model: managed installation and token exchange must be the default path for new apps, billing GraphQL must match Shopify's schema, HMAC handling should match official security practices, and docs/tests should stop teaching legacy OAuth as the primary flow.

Keep legacy OAuth available only as a clearly marked compatibility path.

## Audit Findings To Address

- `ShopifexWeb.Routes` defines a `:managed_install` pipeline but `auth_routes/1` does not use it. The generated `/auth` route currently runs only `[:shopifex_browser, :shopify_session]`, so new apps following the macro never run token exchange.
- `mix shopifex.install` and the dummy router repeat the same old route shape, so generated apps and integration tests do not represent the intended 3.0 managed-install path.
- `Shopifex.Plug.ManagedInstall` can build a session, but `Shopifex.Plug.ShopifySession` does not respect a shop already placed in `conn.private`. If both plugs run in sequence, `ShopifySession` can re-authenticate and fail.
- `Shopifex.Plug.session_token/1` reads `token` and `Authorization: Bearer`, but not the `id_token` query parameter that `ManagedInstall` expects.
- `ManagedInstall` documents an `auth_token` Phoenix.Token redirect bridge, but the audit found only verification code, not issuance.
- `ManagedInstall` directly calls `Shopifex.Shops.create_shop/update_shop`, bypassing the documented `AuthController.insert_shop/1` and `after_install/3` customization points.
- Billing mutations include `@idempotent` on `appSubscriptionCreate` and `appPurchaseOneTimeCreate`, but Shopify's current docs for those mutations do not list that directive, and the official JS billing implementation omits it.
- `ValidateHmac` and `ShopifyWebhook` still use plain equality for HMAC comparison and log computed HMACs. `ShopifySession` was partially fixed to use `Plug.Crypto.secure_compare/2`, but still logs the expected HMAC.
- Webhook HMAC handling lowercases the received header. That is unsafe for Base64 webhook signatures and diverges from Shopify JS/Ruby behavior.
- Query-HMAC validation lacks explicit parameter sorting and timestamp freshness checks. Shopify's JS library sorts params and enforces a timestamp tolerance for query-HMAC flows.
- `EnsureScopes` still redirects to OAuth update. That is a legacy compatibility behavior, not the right default for managed-install apps where scopes are configured through Shopify app config.
- README and docs still contain v2-era guidance: OAuth redirect URLs as primary setup, manual shop schema without token lifecycle columns, Guardian references, and token-in-URL session maintenance.
- The test suite has good lower-level coverage for `SessionToken`, `Auth`, `API`, and billing strings, but no direct `ManagedInstall` tests. This allowed the default route/pipeline bug to pass while `mix test` remained green.

## Key Changes

### Default Embedded Auth Flow

- Update `auth_routes/1`, install-task router output, dummy router, README examples, and moduledocs so `/auth` uses `[:shopifex_browser, :managed_install, :shopify_session]`.
- Update `Shopifex.Plug.session_token/1` to accept `id_token` as well as `token` and `Authorization: Bearer`.
- Update `Shopifex.Plug.ShopifySession` to no-op when `Shopifex.Plug.current_shop(conn)` is already set by `Shopifex.Plug.ManagedInstall`, instead of re-authenticating and failing.
- Implement the documented `auth_token` bridge issuance only if an auth-controller redirect still needs to carry shop identity without cookies. Otherwise, remove the bridge claims from docs/moduledocs and delete the dead verification branch.

### Managed Install Extensibility

- Add managed-install callbacks or config hooks equivalent to `after_install` / `insert_shop`, and invoke them when token exchange creates a new shop.
- Preserve webhook configuration on first install.
- Document that legacy `AuthController.after_install/3` only applies to OAuth unless bridged into the managed-install hook.

### Billing GraphQL

- Remove `@idempotent` from `appSubscriptionCreate` and `appPurchaseOneTimeCreate`.
- Update changelog/docs/tests that currently claim idempotency is required.
- Keep the existing simple plan API, but structure recurring billing variables closer to Shopify's official shape: pass `lineItems` as a variable instead of interpolating the whole line item into the mutation.
- Add optional support for `replacementBehavior`, multiple subscription line items, usage pricing, and discounts where plan data supplies them.
- Preserve existing monthly/annual one-line-item behavior as the default.

Use these references while implementing:

- Shopify billing docs: `appSubscriptionCreate` args are `lineItems`, `name`, `replacementBehavior`, `returnUrl`, `test`, and `trialDays`; no `@idempotent` directive is documented.
- Shopify billing docs: `appPurchaseOneTimeCreate` args are `name`, `price`, `returnUrl`, and `test`; no `@idempotent` directive is documented.
- Official JS billing uses `$lineItems` variables and supports usage pricing, discounts, replacement behavior, and multiple line items.

### HMAC And Legacy Compatibility

- Use `Plug.Crypto.secure_compare/2` for all HMAC comparisons, guarding missing/mismatched binaries.
- Stop logging computed HMAC values.
- Do not lowercase Base64 webhook HMACs; compare them exactly.
- Sort query params explicitly before signing.
- Add timestamp freshness validation for query-HMAC flows with a 90-second default tolerance, configurable for tests.
- Keep legacy OAuth routes, but mark them compatibility-only and add state/nonce validation if they remain public.

Use these references while implementing:

- Official Shopify JS uses safe compare, sorts admin/app-proxy query params, validates query timestamps with a 90-second tolerance, and compares webhook HMACs as Base64.
- Official Shopify Ruby uses `OpenSSL.secure_compare`.
- Shopify app-proxy docs require signature inputs to be sorted alphabetically.

### Scope And Documentation Alignment

- Do not present `EnsureScopes` OAuth redirects as the default for new apps.
- Document scope changes through Shopify app config / managed installation.
- Either make `EnsureScopes` opt-in legacy behavior or change its managed-install behavior to fail with an actionable message rather than redirecting to OAuth.
- Rewrite README quickstart to remove v2-era schema examples, Guardian references, token-in-URL navigation, and OAuth redirect URL setup as the primary path.

## Coverage And Parity

### Managed Install Tests

- Add direct `Shopifex.Plug.ManagedInstall` tests.
- Cover a new-shop request with a valid `id_token`: token exchange succeeds, access/refresh/expiry fields are persisted, webhooks are configured, session is built, and the managed-install callback is invoked.
- Cover an existing fresh shop: session is built without token exchange.
- Cover an existing stale shop: token exchange refreshes lifecycle fields.
- Cover invalid and expired `id_token` behavior according to the documented fallback/failure policy.
- Add an integration test through the generated dummy router for `/auth?id_token=...&shop=...`.

### Billing Tests

- Assert billing mutations do not include `@idempotent`.
- Assert recurring and one-time mutations match Shopify's documented GraphQL shape.
- Add cases for annual interval, trial days, replacement behavior, usage line items, multiple line items, discounts, and `userErrors`.

### HMAC And Security Tests

- Add valid and invalid webhook HMAC tests using exact Base64 case.
- Add query-HMAC tests that reject stale timestamps and accept timestamps inside tolerance.
- Add query-HMAC tests proving params are signed in deterministic sorted order.
- Add log-capture tests proving HMAC failures do not log computed secrets.

### JS/Ruby Parity Checks

- Use Shopify's official JS and Ruby libraries as behavioral references for token exchange default behavior, HMAC compare/sorting/timestamp handling, OAuth state validation, billing mutation shape, and token migration from non-expiring to expiring tokens.
- Add a lightweight markdown parity matrix covering managed install, session token verification, token refresh, webhook auth/registration, billing features, OAuth fallback, and token migration.

The parity matrix should explicitly compare Shopifex against:

- Shopify JS: default token-exchange strategy for embedded App Store / single-merchant apps, HMAC utility behavior, billing request shape, and migrate-to-expiring-token helper.
- Shopify Ruby: token exchange, `migrate_to_expiring_token`, OAuth state validation, and secure HMAC comparison.

## Verification

- Run `mix format --check-formatted`.
- Run `mix compile --warnings-as-errors`.
- Run full `mix test`.
- Run `mix docs` and `mix hex.build` if this is release-bound.
- Manually inspect generated install output to confirm a new Phoenix app gets the managed-install router path and token lifecycle columns by default.

## Assumptions

- 3.0 is optimized for new embedded Shopify apps; legacy OAuth remains only for compatibility.
- API version stays `2026-04` for now.
- The implementation should prefer Shopify official JS/Ruby behavior where this library lacks a strong Elixir-specific reason to differ.
- No public module namespace rename is planned for this pass.
