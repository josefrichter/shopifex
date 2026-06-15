# Shopifex Parity Matrix

This document compares the **Shopifex** Elixir library against Shopify's two
official libraries — **Shopify JS** (`@shopify/shopify-app-js` /
`@shopify/shopify-api`) and **Shopify Ruby** (`shopify_api` gem) — for the
capabilities an embedded Shopify app needs in the current (2026) embedded-app
model: managed installation, token exchange, expiring offline access tokens,
session-token verification, HMAC/webhook security, and billing.

The **Shopifex** column is grounded in the actual code at the time of writing
(branch `modern-shopifex`, target release `3.0.0`, Admin API `2026-04`), not in
aspiration. Where Shopifex differs from the official libraries or only partially
covers a capability, it is marked honestly. This is a reference, not marketing.

Legend: ✅ supported / on par · ⚠️ partial or deliberately different · ❌ not
provided.

## Matrix

| # | Capability | Shopify JS | Shopify Ruby | Shopifex | Notes |
|---|------------|------------|--------------|----------|-------|
| 1 | Default install strategy for embedded App Store / single-merchant apps (token exchange via managed installation) | ✅ Token exchange is the default; `unstable_apiClient` / `authenticate.admin` run managed install | ✅ `ShopifyAPI::Auth::TokenExchange` is the recommended path; OAuth is legacy | ✅ `Shopifex.Plug.ManagedInstall` is the default pipeline plug; verifies `id_token` then exchanges/loads the shop | Shopifex pipeline is `[:shopifex_browser, :managed_install, :shopify_session]`; `ManagedInstall` no-ops (falls through to legacy OAuth) only when no valid `id_token` is present. |
| 2 | Session token (`id_token`) verification — algorithm, claims checked | ✅ HS256, verifies `aud`, `dest`/`iss`, `exp`/`nbf`/`iat` | ✅ `JWTPayload` validates signature, `aud`, `dest`, `exp`, `nbf` | ✅ `Shopifex.SessionToken.verify/2`: strict HS256 only (no alg confusion), checks `aud` == api_key, `dest` is `*.myshopify.com` (and matches expected shop), `iss` == `\#{dest}/admin`, `exp` (10s skew), `nbf` | Shopifex returns `:expired` as a **distinct** error so routine bfcache/clock-skew expiries log at `:info` while signature/audience failures stay `:warning`. ~10s allowed clock skew. |
| 3 | Token exchange to OFFLINE expiring access token (RFC 8693, `expiring=1`) | ✅ Requests offline tokens; sends `expiring` per Apr 2026 requirement | ✅ `TokenExchange` requests offline access tokens | ✅ `ManagedInstall.exchange_token_and_upsert_shop/5` POSTs RFC 8693 token-exchange grant with `requested_token_type=...offline-access-token` and `expiring=1` | Persists all four lifecycle fields from the response: `access_token`, `token_expires_at` (from `expires_in`, ~1h), `refresh_token`, `refresh_token_expires_at` (from `refresh_token_expires_in`, ~90d). `expiring=1` is required for public apps created on/after 2026-04-01. |
| 4 | Token refresh — proactive (background), reactive (on 401), concurrency safety | ✅ Refreshes proactively and on 401 | ✅ Refresh-token grant; documented proactive + reactive | ✅ `Shopifex.Auth.ensure_fresh_token/1` (proactive, 5-min safety window) + reactive single refresh-and-retry on 401 in `Shopifex.API.graphql/3`; concurrency-safe via `SELECT … FOR UPDATE` row lock in a `repo().transaction` | Row lock serializes per-shop refresh cross-node (Postgres) without a Registry/DynamicSupervisor; double-check after acquiring the lock avoids clobbering a concurrent refresh. Refresh tokens are one-time-use. |
| 5 | Migrate non-expiring → expiring offline tokens | ✅ Handles transition; recommends token exchange to obtain expiring tokens | ✅ Explicit helper `migrate_to_expiring_token` (`ShopifyAPI::Auth`) | ⚠️ No explicit one-shot migration helper. Legacy/non-expiring shops have nil expiry columns; `ensure_fresh_token/1` treats nil expiry as non-expiring (no background refresh), reactive-401 still works, and the next embedded `id_token` load re-exchanges via `ManagedInstall` and back-fills the expiring fields | Deliberate: migration is implicit and event-driven (next page load) rather than a callable batch helper. Shops that never re-open the embedded app stay non-expiring until they do. |
| 6 | Webhook HMAC verification (Base64, constant-time compare) | ✅ Base64 compare, `safeCompare` | ✅ `OpenSSL.secure_compare`, Base64 | ✅ `Shopifex.Plug.ShopifyWebhook`: `build_hmac/1` computes `:crypto.mac` → `Base.encode64`, compared **case-sensitively** with `Plug.Crypto.secure_compare/2`; the `x-shopify-hmac-sha256` header is used verbatim (not downcased) | POST/webhook body HMAC is never lowercased (Base64 is case-significant). Unknown shop → `200` (so Shopify stops retrying); bad HMAC → `401`, failure category logged but never the computed/expected HMAC. |
| 7 | Webhook registration (GraphQL `webhookSubscriptionCreate` vs config/TOML topics) | ⚠️ Both: app-config (`shopify.app.toml`) topics are the modern path; GraphQL/REST registration also available | ⚠️ Both: TOML topics or `Webhook::Registry` GraphQL registration | ⚠️ `Shopifex.Shops.configure_webhooks/1` registers via GraphQL through `Shopifex.API.graphql/3` on **first install only** (in `ManagedInstall` and legacy `install`/`update`) | Shopifex registers imperatively via GraphQL at install time; it does not read/declare TOML `[webhooks]` topics. Shopify's modern recommendation is declaring webhook topics in app config — treat Shopifex's GraphQL registration as the app-managed alternative. |
| 8 | Query / app-proxy HMAC — param sorting + timestamp tolerance | ✅ Sorts params, validates timestamp tolerance | ✅ Sorted params, `secure_compare` | ✅ `Shopifex.Plug.build_hmac/1` sorts params with `Enum.sort/1` before signing (hex, lowercase, `secure_compare`); `Shopifex.Plug.ValidateHmac` enforces a **90s** `timestamp` tolerance (configurable) and constant-time compare | Handles `hmac` (admin load, `&`-joined), `signature` (app-proxy, no joiner per Shopify docs), and the `ids=[...]` quoting quirk for bulk-action links. Timestamp check is skipped when no `timestamp` param is present. Query HMACs are hex (lowercased on receipt); webhook HMACs are Base64 (case-preserved) — handled separately. |
| 9 | Billing — `appSubscriptionCreate` / `appPurchaseOneTimeCreate` request shape | ✅ `$lineItems` variable, no `@idempotent`; usage/discounts/replacementBehavior/multi-item | ⚠️ Billing helpers exist (`ShopifyAPI` billing); GraphQL shape via app code | ✅ `PaymentController.create_charge/2` (a `ShopifexWeb.PaymentController` macro callback): `appSubscriptionCreate` passes `lineItems` as a `$lineItems` variable (not interpolated), **no `@idempotent`** directive; supports optional `replacementBehavior`, `discount`, `usage` and multiple line items via `:line_items`; `appPurchaseOneTimeCreate` for one-time | Defaults to a single recurring line item (`EVERY_30_DAYS`, or `ANNUAL` when `plan.annual`); trial days, currency code, and test-charge flag supported. No `@idempotent` is sent because Shopify does not document one for these mutations. |
| 10 | OAuth fallback (authorization code grant) + state/nonce validation | ✅ Full OAuth with `state`/nonce cookie validation | ✅ Full OAuth with `state` (`Auth::Oauth`) validation | ⚠️ Legacy OAuth fallback exists (`ShopifexWeb.AuthController` — `initialize_installation/2`, `install/2`, `update/2`), but the `state` param is **passed through, not validated** against a stored nonce | Honest gap: the authorization-code grant works as a compatibility path, but Shopifex does not generate/persist/verify an anti-CSRF `state` nonce the way Shopify JS/Ruby do. The primary, secure path is managed install + token exchange (row 1), which has no OAuth redirect and no state to validate. Add nonce validation if you keep OAuth routes public. |
| 11 | Scope enforcement on mismatch (managed-install config vs OAuth re-auth redirect) | ⚠️ Scopes declared in app config; mismatch handled via re-grant on install/update | ⚠️ Scope handling via app config / OAuth | ✅ `Shopifex.Plug.EnsureScopes` **raises an actionable error by default** (`:raise`) telling you to reconcile scopes in `shopify.app.toml` `[access_scopes]`; legacy OAuth-update redirect is opt-in via `on_missing_scopes: :redirect` | Deliberately diverges from v2: managed-install apps get scopes from Shopify app config, so redirecting merchants into OAuth re-auth is the wrong default. Diff is `required_scopes -- shop_scopes`. |

## References

Official Shopify libraries:

- Shopify JS — `@shopify/shopify-app-js`: https://github.com/Shopify/shopify-app-js
- Shopify JS — `@shopify/shopify-api`: https://github.com/Shopify/shopify-api-js
- Shopify Ruby — `shopify_api` gem: https://github.com/Shopify/shopify_api

Relevant `shopify.dev` documentation:

- Token exchange: https://shopify.dev/docs/apps/build/authentication-authorization/access-tokens/token-exchange
- Offline access tokens: https://shopify.dev/docs/apps/build/authentication-authorization/access-tokens/offline-access-tokens
- Offline access tokens now support expiry and refresh: https://shopify.dev/changelog/offline-access-tokens-now-support-expiry-and-refresh
- Expiring offline access tokens required for public apps (April 1, 2026): https://shopify.dev/changelog/expiring-offline-access-tokens-required-for-public-apps-april-1-2026
- Session tokens (App Bridge `id_token`): https://shopify.dev/docs/apps/build/authentication-authorization/session-tokens
- App proxy signature verification: https://shopify.dev/docs/apps/build/online-store/display-dynamic-data#calculate-a-digital-signature
- Webhook HMAC verification: https://shopify.dev/docs/apps/build/webhooks/subscribe/verify-webhook
- Billing — `appSubscriptionCreate`: https://shopify.dev/docs/api/admin-graphql/latest/mutations/appSubscriptionCreate
- Billing — `appPurchaseOneTimeCreate`: https://shopify.dev/docs/api/admin-graphql/latest/mutations/appPurchaseOneTimeCreate

## Known gaps / deliberate differences

- **No explicit `migrate_to_expiring_token` helper (row 5).** Shopify Ruby
  ships a callable migration helper; Shopifex migrates implicitly on the next
  embedded `id_token` load. Shops that never re-open the embedded app remain on
  non-expiring tokens. There is no batch/CLI command to force-migrate all shops.

- **OAuth `state`/nonce is not validated (row 10).** The legacy
  authorization-code grant in `ShopifexWeb.AuthController` accepts `state` and
  forwards it but does not generate, persist, or verify it against a stored
  nonce. This is acceptable only because managed install (the default) has no
  OAuth redirect. If you expose the legacy OAuth routes publicly, add anti-CSRF
  `state` validation to match Shopify JS/Ruby.

- **Webhook topics are registered via GraphQL, not declared in TOML (row 7).**
  Shopifex registers subscriptions imperatively at install time
  (`configure_webhooks/1`) rather than reading `[webhooks]` topics from
  `shopify.app.toml`. This is the app-managed alternative to Shopify's modern
  config-file approach; both are valid, but they are not the same mechanism.

- **Scope mismatch raises by default instead of redirecting (row 11).** A
  deliberate change from v2 behavior. `EnsureScopes` fails with an actionable
  message pointing at `shopify.app.toml` `[access_scopes]`; the OAuth-update
  redirect is available only via `on_missing_scopes: :redirect`.

- **Transport scope is intentionally narrow.** `Shopifex.API` ships only the
  GraphQL Admin transport (with token refresh) — it does not wrap the full REST
  surface or every Admin object the official SDKs expose. App-specific
  queries/mutations live in your application and call `Shopifex.API.graphql/3`.
