# Shopifex reference

Deep detail for building apps with Shopifex. The `SKILL.md` has the essentials; this
file is the lookup. (Shopifex 3.0.)

## Authentication model (managed installation)

On every embedded page load Shopify's App Bridge supplies a short-lived (~1 min) signed
JWT, the **session token / `id_token`**. It *proves identity* (which shop/user) but is
**not** an API credential. Your backend swaps it for an **access token** via OAuth 2.0
token exchange (RFC 8693). Access tokens are **offline** (shop-scoped, background-capable)
for embedded apps and, as of 2026, **expire** (~1h) with a 90-day refresh token. Shopifex
stores and rotates all of it.

Flow on `/auth` (pipeline `[:shopifex_browser, :managed_install, :shopify_session]`):
1. `Shopifex.Plug.ManagedInstall` verifies the `id_token` (`Shopifex.SessionToken`, strict
   HS256, checks `aud`/`dest`/`iss`/`exp`/`nbf`).
2. New shop → token exchange (`expiring=1`), persists `access_token`, `token_expires_at`,
   `refresh_token`, `refresh_token_expires_at`, `scope`; configures webhooks; runs the
   managed-install callback. Existing stale shop (>50 min) → re-exchange + webhook reconcile.
   Fresh shop → builds session directly.
3. `Shopifex.Plug.ShopifySession` no-ops when a shop is already loaded; otherwise verifies
   the session token / legacy HMAC, then runs `EnsureScopes`.

Background/API freshness: `Shopifex.Auth.ensure_fresh_token/1` proactively refreshes within
a 5-min window; `Shopifex.API.graphql/3` reactively refreshes once on a 401 and retries.
Refresh is serialized cross-node with a `SELECT … FOR UPDATE` row lock.

`Shopifex.Plug.session_token(conn)` reads the token from `id_token` / `token` query params
or the `Authorization: Bearer` header.

### Managed-install extensibility
New shops are persisted through `Shopifex.ManagedInstall.Callbacks`:
```elixir
config :shopifex, managed_install_callbacks: MyApp.ManagedInstallCallbacks

defmodule MyApp.ManagedInstallCallbacks do
  use Shopifex.ManagedInstall.Callbacks
  @impl true
  def insert_shop(attrs), do: Shopifex.Shops.create_shop(attrs)   # customise persistence
  @impl true
  def after_install(shop), do: :ok                                # side effects on first install
end
```
Token refreshes of an existing shop do NOT run these. The legacy
`ShopifexWeb.AuthController` callbacks (`after_install/3`, `after_update/3`, `insert_shop/1`)
apply only to the **OAuth** controller flow, not managed install.

## Admin API
`Shopifex.API.graphql(shop, query, variables \\ %{}) :: {:ok, map} | {:error, term}`.
Returns the unwrapped `data` map on success. On HTTP 200 **with** a GraphQL `errors` array
it returns `{:error, errors}` (errors take precedence — a partial `data` is dropped). On a
401 it refreshes once and retries. API version: `config :shopifex, :api_version` (default
`"2026-04"`), single source of truth.

Example context function:
```elixir
def top_products(shop) do
  query = "query { products(first: 10, sortKey: ...) { edges { node { title } } } }"
  case Shopifex.API.graphql(shop, query) do
    {:ok, data} -> {:ok, data["products"]["edges"]}
    {:error, reason} -> {:error, reason}
  end
end
```

## Webhooks
`use ShopifexWeb.WebhookController` provides `action/2` (dispatches by the
`x-shopify-topic` header) and overridable `handle_topic/3` with default GDPR clauses:
- `shop/redact` → deletes the shop, 200
- `customers/redact`, `customers/data_request` → 200

Defining your own `handle_topic/3` is `defoverridable` and **replaces all** clauses; keep a
`def handle_topic(conn, shop, topic), do: super(conn, shop, topic)` catch-all.

Subscription management (GraphQL): `Shopifex.Shops.configure_webhooks/1` (idempotent — only
creates missing), `get_current_webhooks/1`, `delete_webhook/2`. Topics come from
`config :shopifex, :webhook_topics` (REST-style strings, e.g. `"orders/create"`). Configured
on first install and reconciled on every re-exchange (self-healing). Webhook HMAC: Base64,
constant-time, case-sensitive (`Shopifex.Plug.ShopifyWebhook`). Unknown shop → 200 (stops
retries); bad HMAC → 401; missing/duplicate `x-shopify-topic` header → 400 (fails closed).

For slow handlers, enqueue Oban and return 200 immediately (avoid Shopify's webhook timeout).

## Billing
- `payment_routes/2` adds `/payment/show-plans`, `/payment/select-plan`, `/payment/complete`,
  and API variants. Pass `shopify_embedded: false` to opt out of the CSP-embedded pipeline.
- `MyApp.Shops.PaymentGuard` `use Shopifex.PaymentGuard` — overridable callbacks:
  `grant_for_guard/2`, `grants_for_shop/1`, `use_grant/2`, `create_grant/3`, `get_plan/1`,
  `list_available_plans_for_guard/2`. Defaults query the Grant schema.
- `plug Shopifex.Plug.PaymentGuard, "guard_name"` — redirects to the plan picker when the
  shop has no grant unlocking `"guard_name"`; on payment a Grant is created.
- **Multi-node billing:** the billing flow stores `charge_id → redirect_after` at
  `/payment/select-plan` and reads it at `/payment/complete`. The default
  `Shopifex.RedirectAfterAgent` keeps that in a node-local `Agent`, so on multi-node
  deploys (Fly.io, …) the confirmation can land on a different node → cache miss →
  `complete_payment/2` responds **403** (a `Plug.Conn`, logged at `:error`) and **no
  Grant is created**.
  Use the shipped, DB-backed store instead:
  `config :shopifex, :redirect_after_agent, Shopifex.RedirectAfter.Ecto` (table
  `shopifex_charge_redirects`: `charge_id` bigint PK, `redirect_after` text,
  `inserted_at`; `mix shopifex.install` generates the config + migration). A missed
  lookup now logs `Logger.error` instead of failing silently.
- **Plan** schema: `name`, `price`, `type` (`"recurring_application_charge"` |
  `"application_charge"`), `test`, `grants` (array of guard strings), `features`, `usages`
  (nil = unlimited; integer = usage-limited grant), `annual`, `trial_days`.
- `ShopifexWeb.PaymentController.create_charge/2` is public + overridable. Recurring uses
  `appSubscriptionCreate` (monthly default, `annual: true` → ANNUAL), one-time uses
  `appPurchaseOneTimeCreate`. **No `@idempotent`.** `lineItems` is a `$lineItems` variable.
  Optional plan keys: `replacement_behavior`, `discount`, `currency_code` (default USD),
  `line_items` (full override → multiple items / `appUsagePricingDetails` usage pricing).
- `test: true` shows Shopify's approval screen but never charges — use on dev stores.

## Scopes
`config :shopifex, :scopes` (comma string) must mirror `shopify.app.toml` `[access_scopes]`.
`Shopifex.Plug.EnsureScopes` (in `:shopify_session` and `:shopify_admin_link`) compares them
and on a mismatch:
- default `:raise` — raises `Shopifex.RuntimeError` with an actionable message (reconcile in
  app config; `shopify app deploy`).
- `:redirect` (opt-in, legacy) — renders an OAuth-update redirect. Set via the plug option
  `on_missing_scopes: :redirect` or `config :shopifex, :ensure_scopes_on_missing, :redirect`.
A nil/empty stored scope is treated as no scopes (raises, doesn't crash).

## Config keys
| Key | Purpose |
|---|---|
| `app_name`, `web_module`, `repo`, `shop_schema` | core |
| `api_key`, `secret` | Shopify app credentials |
| `old_secret` | accepted during a secret rotation (HMAC + token verify) |
| `scopes` | EnsureScopes check (mirror the TOML) |
| `api_version` | Admin API version (default `2026-04`) |
| `webhook_topics`, `webhook_uri` | webhook subscription |
| `managed_install_callbacks` | `insert_shop/1` + `after_install/1` hooks |
| `payment_guard`, `plan_schema`, `grant_schema`, `payment_redirect_uri` | billing |
| `path_prefix` | mount under a sub-path |
| `hmac_timestamp_tolerance_seconds` | query-HMAC freshness window (default 90) |
| `ensure_scopes_on_missing` | `:raise` (default) or `:redirect` |
| `req_options` | (test) inject `plug: {Req.Test, Stub}` |
| `default_locale` | gettext fallback |

## Security
- HMAC compared in constant time (`Plug.Crypto.secure_compare/2`) everywhere; computed
  HMACs never logged. Webhook HMACs Base64 (case-sensitive); query/app-proxy HMACs hex,
  params sorted alphabetically, with a 90s `timestamp` tolerance. The `:shopify_proxy`
  pipeline passes `ValidateHmac, require_timestamp: true`, so app-proxy requests without a
  `timestamp` are rejected (no indefinitely-replayable signed URLs); admin-load / bulk-action
  links still allow a missing timestamp.
- **Secret rotation:** set `config :shopifex, :old_secret` so both the current and previous
  secret are accepted while you roll the credential.
- `ShopifexWeb.CacheBodyReader` must be the `Plug.Parsers` `body_reader` (raw body for HMAC).

## Testing (`Shopifex.Test`)
Ships in the package; `import Shopifex.Test` in your tests.
- `sign_session_token(shop_url, opts)` — opts: `:secret`, `:api_key`, `:expires_in`,
  `:user_id`, `:claims`.
- `put_shopify_session(conn, shop, opts)` — loads `current_shop` + a Bearer `id_token`.
- `sign_webhook(raw_body, opts)` / `put_webhook_hmac(conn, raw_body, opts)` — webhook HMAC.
- `sign_query_hmac(params, opts)` — query/app-proxy HMAC (opts `:joiner` `"&"`/`""`).

Stub Shopify HTTP: `config :shopifex, :req_options, plug: {Req.Test, MyStub}` and
`Req.Test.stub(MyStub, fn conn -> Req.Test.json(conn, %{...}) end)`.

## UI (App Bridge + Polaris web components)
Polaris React is deprecated; use **Polaris web components** (framework-agnostic, work in
HEEx). In the embedded layout `<head>`:
```html
<meta name="shopify-api-key" content={api_key} />
<script src="https://cdn.shopify.com/shopifycloud/app-bridge.js"></script>
<script src="https://cdn.shopify.com/shopifycloud/polaris.js"></script>
```
App Bridge auto-initializes and exposes the global `shopify` object, and auto-attaches the
session token as a Bearer header to same-origin `fetch`. Components: `<s-page heading>` (the
admin title bar, `slot="primary-action"`), `<s-section>`, `<s-button>`, `<s-text-field>`,
`<s-banner>`, `<s-modal>` (declarative via `commandFor`/`command`). Imperative APIs from a
LiveView JS hook: `shopify.toast.show(msg)`, `shopify.resourcePicker({type})`,
`await shopify.idToken()`. Element names are `s-*` (older `ui-*` names are superseded).

## Deliberate limitations / parity notes
- **Offline tokens only.** No online/per-user (`sub`) sessions or `AssociatedUser`. Fine for
  background/single-merchant-action apps; not for "act as this user".
- **Legacy OAuth fallback** (`/auth/install`, `/auth/update`) exists but does **not** validate
  a `state`/nonce — keep those routes non-public, or add validation, if you rely on them.
- Webhooks are registered via GraphQL at install (not declared in `shopify.app.toml`).
- See `docs/parity-matrix.md` in the shopifex repo for the full Shopifex vs Shopify JS/Ruby
  comparison.
