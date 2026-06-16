# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

## [3.0.0]

Modernization release: Shopify 2026 compliance, a Guardian-free embedded auth
model, and a Phoenix 1.8 / function-component baseline.

Verified on Elixir 1.20 / OTP 29, Phoenix 1.8.8, Phoenix LiveView 1.2.1
(minimum supported: Elixir 1.15, Phoenix 1.8).

### Breaking changes

- **Minimum Elixir 1.15 and Phoenix 1.8.** Dropped `phoenix_view`,
  `phoenix_html_helpers`, and `plug_cowboy` — the library no longer pins a web
  server (Bandit is the Phoenix 1.8 default) or the legacy view stack.
- **View layer is function components.** `Phoenix.View` modules + `.eex`
  templates were replaced by `*HTML` modules with co-located `.heex`
  templates. If you rendered Shopifex views directly, update to
  `put_view(ShopifexWeb.PaymentHTML)` / `render("show_plans.html", ...)`.
- **Guardian removed.** Embedded auth no longer mints an app JWT. Session
  tokens (`id_token`) are verified directly by `Shopifex.SessionToken`.
  `Shopifex.Plug.build_session/4` no longer sets a Guardian token; the
  `:shopify_api` / `:shopifex_api` pipelines now use
  `Shopifex.Plug.ShopifyApiAuth`. `AuthController.auth/2` and
  `PaymentController` redirect to the app root instead of appending `?token=`.
- **Webhooks and billing are GraphQL.** REST webhook (`webhooks.json`) and
  charge (`recurring_application_charges` / `application_charges`) endpoints
  were removed, along with the `neuron` dependency. Topics returned by
  `Shopifex.Shops.get_current_webhooks/1` are now GraphQL enums.
- **Embedded payment routes are the default.** `payment_routes/2` defaults to
  the CSP-protected embedded pipeline; pass `shopify_embedded: false` to opt
  out.

### Added

- `Shopifex.Auth` — background offline-token refresh (proactive 5-minute
  window, reactive-on-401, `SELECT … FOR UPDATE` per-shop concurrency lock).
- `Shopifex.API` — single GraphQL Admin API transport with a configurable
  `api_version` (default `2026-04`) and errors-take-precedence handling.
- `Shopifex.SessionToken` — strict HS256 verification of App Bridge session
  tokens, with `:expired` distinct from other errors.
- `Shopifex.Plug.ShopifyApiAuth` — session-token auth for the API pipelines.
- Token-lifecycle columns on the shop schema (`token_expires_at`,
  `refresh_token`, `refresh_token_expires_at`; `scope` now nullable), all
  additive and nullable so legacy / non-expiring installs round-trip.
- **Managed installation is the default embedded auth flow.** `auth_routes/1`
  now pipes `/auth` through `[:shopifex_browser, :managed_install,
  :shopify_session]`, so generated apps run token exchange out of the box.
  `Shopifex.Plug.ManagedInstall` verifies `id_token`, requests **expiring**
  tokens (`expiring=1`), persists the full token lifecycle, and re-exchanges on
  a 50-minute staleness window.
- `Shopifex.ManagedInstall.Callbacks` — configurable `insert_shop/1`,
  `after_install/1` (first install only), and `after_exchange/2` (every exchange —
  install **and** refresh, with a `new?` flag) hooks for the managed-install path
  (`config :shopifex, managed_install_callbacks: MyApp.Callbacks`). Callbacks run
  synchronously in the request — spawn a `Task` for slow work. The legacy
  `AuthController.after_install/3` / `insert_shop/1` callbacks apply only to the
  OAuth controller flow.
- `Shopifex.Plug.session_token/1` now also reads the `id_token` query parameter
  (in addition to `token` and `Authorization: Bearer`), and
  `Shopifex.Plug.ShopifySession` yields to a shop already loaded by
  `ManagedInstall` instead of re-authenticating.
- Default GDPR webhook handlers in `ShopifexWeb.WebhookController`
  (`customers/data_request`, `customers/redact`, `shop/redact`), overridable.
- `appPurchaseOneTimeCreate` support for one-time charges. `create_charge/2` is
  now public and overridable, and the recurring mutation accepts optional
  `replacement_behavior`, `discount`, `currency_code`, and `line_items`
  (multiple items / usage pricing) from plan data.
- `docs/parity-matrix.md` — behavior parity matrix vs Shopify JS and Ruby.
- `Shopifex.Test` — public test helpers (ships in the package) for forging the
  tokens/HMACs Shopifex verifies: `sign_session_token/2`, `put_shopify_session/3`,
  `sign_webhook/2`, `put_webhook_hmac/3`, `sign_query_hmac/2`. Lets consuming apps
  test controllers/LiveViews behind the `:shopify_*` pipelines without Shopify.
- `Shopifex.Plug.ShopifyApiAuth` now sets `x-shopify-retry-invalid-session-request: 1`
  on its `401`, so App Bridge's `authenticatedFetch` transparently retries with a
  fresh `id_token` (embedded tokens live ~60s) instead of surfacing the error.
- `jose` is now an explicit dependency.

### Security

- HMAC comparisons use constant-time `Plug.Crypto.secure_compare/2` everywhere
  (`ValidateHmac`, `ShopifyWebhook`, `ShopifySession`), and computed HMAC values
  are no longer logged on failure.
- Webhook Base64 HMACs are compared case-sensitively (no longer lowercased),
  matching Shopify JS/Ruby.
- Query / app-proxy HMAC parameters are signed in explicit alphabetical order.
- Query / app-proxy requests with a `timestamp` are rejected outside a 90-second
  tolerance (`config :shopifex, :hmac_timestamp_tolerance_seconds`).
- **Secret rotation.** Set `config :shopifex, :old_secret` to have webhook /
  app-proxy / session HMAC verification and session-token (`id_token`)
  verification accept the previous secret as well, so rotating the app secret
  doesn't drop in-flight webhooks or sessions.
- **LiveView session no longer carries the shop's tokens.**
  `ShopifexWeb.LiveSession.put_shop_in_session/1` now serializes only the shop
  **URL** (not the `current_shop` struct), and `on_mount` reloads the shop
  server-side. The LV session is signed but not encrypted (readable client-side),
  so the old behavior exposed `access_token` / `refresh_token`.

### Fixed

- **Macro billing flow now creates the grant.** `Shopifex.RedirectAfterAgent`
  `set/2` and `get/1` disagreed on key type (string vs integer), so the
  charge-id keyed lookup in `complete_payment/2` missed and the `Grant` was never
  created. Both now coerce the key consistently. (Documented limitation: the
  default `RedirectAfterAgent` is an in-memory, single-node `Agent` — swap it via
  `config :shopifex, :redirect_after_agent` for multi-node deploys.)

### Changed

- **Billing mutations no longer send `@idempotent`.** Shopify does not document
  the directive for `appSubscriptionCreate` / `appPurchaseOneTimeCreate`, and the
  official JS/Ruby libraries omit it. Recurring line items are passed as a
  `$lineItems` GraphQL variable rather than interpolated into the query.
- **`Shopifex.Plug.EnsureScopes` no longer redirects to OAuth by default.** On a
  scope mismatch it now raises an actionable error pointing at managed-install
  app config. Opt back into the legacy redirect with
  `plug Shopifex.Plug.EnsureScopes, on_missing_scopes: :redirect` (or
  `config :shopifex, :ensure_scopes_on_missing, :redirect`).
- **Webhook subscriptions self-heal.** `Shopifex.Plug.ManagedInstall` now
  reconciles webhooks (idempotent `configure_webhooks/1`) on existing-shop token
  re-exchanges, not just first install — recovering from a registration that
  failed at install or topics added to `:webhook_topics` later. It runs at the
  token-exchange cadence (≤ the 50-minute staleness window), never on the hot
  per-load path.
- **Built-in pages use the Shopify-hosted App Bridge + Polaris web components.**
  The auth / payment / redirect pages now load App Bridge and Polaris from
  `cdn.shopify.com` with a `<meta name="shopify-api-key">` tag, and are rendered
  with Polaris web components (`s-page`, `s-section`, …) — no React. The vendored
  `@shopify/app-bridge@3` + Polaris 4/7 bundle (`assets/`, `priv/static/`) was
  removed, so apps **no longer need** the `Plug.Static at: "/shopifex-assets"`
  endpoint entry. The `mix shopifex.install` task no longer prints it.
- Tests use `Req.Test` stubs; `exvcr` and its cassettes were removed.

## [2.0.1] - 2021-08-25

### Added

- Ensure that the current shop scopes in the session are up-to-date based on config :shopifex, :scopes when the request is passed through :shopify_session or :shopify_admin_link pipelines.
- Add Shopifex.Plug.EnsureScopes plug which redirects to Shopify OAuth update if current shop scopes are not up-to-date

### Changed

## [2.0.0] - 2021-08-17

### Added

### Changed

- Move `show_plans` optional callback from `Shopifex.PaymentGuard` behaviour to `render_plans` in `ShopifexWeb.PaymentController` behavour

[unreleased]: https://github.com/ericdude4/shopifex/compare/v2.0.1...HEAD
[2.0.1]: https://github.com/ericdude4/shopifex/compare/v2.0.0...v2.0.1
[2.0.0]: https://github.com/ericdude4/shopifex/compare/v1.1.1...v2.0.0
