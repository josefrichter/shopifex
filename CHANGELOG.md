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
- `Shopifex.Plug.ManagedInstall`: verifies `id_token`, requests **expiring**
  tokens (`expiring=1`), persists the full token lifecycle, re-exchanges on a
  50-minute staleness window, and bridges the cookie-less auth redirect via a
  signed `Phoenix.Token`.
- Default GDPR webhook handlers in `ShopifexWeb.WebhookController`
  (`customers/data_request`, `customers/redact`, `shop/redact`), overridable.
- `appPurchaseOneTimeCreate` support for one-time charges; `@idempotent` on all
  billing mutations (required as of 2026-04). `create_charge/2` is now public
  and overridable.
- `jose` is now an explicit dependency.

### Changed

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
