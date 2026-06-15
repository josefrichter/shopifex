---
name: shopifex
description: Build or extend a Shopify embedded app in Elixir/Phoenix using the Shopifex library. Use whenever working in a Phoenix app that depends on `shopifex` (or that has `Shopifex.*`/`ShopifexWeb.*` modules, a `config :shopifex`, or `auth_routes`/`payment_routes`/`shopifex_live_session` in its router) — for routing/pipelines, authentication (managed installation, session tokens, `current_shop`), calling the Admin GraphQL API via `Shopifex.API.graphql/3`, webhooks, billing (`PaymentGuard`), LiveView, App Bridge/Polaris UI, and testing with `Shopifex.Test`. Encodes the conventions and gotchas so you never reach for legacy OAuth or the wrong API.
license: Apache-2.0
metadata:
  author: Josef Richter
  version: "0.1.0"
---

# Building Shopify apps with Shopifex

Shopifex is a Phoenix library for **embedded** Shopify apps (apps that render in an
`<iframe>` inside the Shopify admin). It handles authentication, token lifecycle,
webhooks, billing, and HMAC security so the app code is mostly normal Phoenix.

**Default auth is managed installation + token exchange — NOT legacy OAuth.** On
every embedded load Shopify supplies a short-lived `id_token` (App Bridge); Shopifex
verifies it and exchanges it for an expiring offline access token, which it stores
and refreshes for you. Never build a cookie session or an OAuth-redirect-first flow
for new apps.

For exhaustive detail (full config table, function signatures, billing options, UI),
read `reference.md` in this skill directory.

## The mental model
- `Shopifex.Plug.current_shop(conn)` (or `@current_shop` in LiveView) is "the logged-in
  shop". Every Shopify API call runs **as** that shop.
- `Shopifex.API.graphql(shop, query, variables \\ %{})` is the **single** entrypoint for
  the Admin GraphQL API. It keeps the access token fresh. Returns `{:ok, data}` or
  `{:error, reason}` (a GraphQL `errors` list, a `{status, body}` tuple, or a transport
  error). App-specific queries/mutations live in your app and call this.
- The library ships only the transport + framework; you write your features.

## Router / pipelines
```elixir
require ShopifexWeb.Routes

ShopifexWeb.Routes.pipelines()
ShopifexWeb.Routes.auth_routes(MyAppWeb.AuthController)        # /auth (managed install) + legacy OAuth
ShopifexWeb.Routes.payment_routes(MyAppWeb.PaymentController)  # billing flow (optional)

scope "/webhook", MyAppWeb do
  pipe_through [:shopify_webhook]
  post "/", WebhookController, :action
end

scope "/", MyAppWeb do
  pipe_through [:shopifex_browser, :shopify_session]

  # @current_shop is assigned inside the block
  ShopifexWeb.Routes.shopifex_live_session :embedded do
    live "/", DashboardLive
  end
end
```
Pipelines: `:shopifex_browser`, `:managed_install`, `:shopify_session` (verifies the
session token / legacy HMAC; **includes `EnsureScopes`**), `:shopify_webhook`,
`:shopify_admin_link`, `:shopify_api` (Bearer token, for SPA/XHR), `:shopify_embedded`
(CSP), `:shopify_proxy`, `:validate_install_hmac`. `auth_routes/1` already wires
`:managed_install` before `:shopify_session`.

The two controllers are usually empty — `use ShopifexWeb.AuthController` and
`use ShopifexWeb.WebhookController` do the work.

## LiveView
Inside `shopifex_live_session`, `@current_shop` and `@session_token` are assigned. In
`mount/3`, read `socket.assigns.current_shop` and call your context, which calls
`Shopifex.API.graphql/3`. For real-time, broadcast from a webhook handler over
`Phoenix.PubSub` and `subscribe` in `mount` (only when `connected?(socket)`).

## Webhooks
```elixir
defmodule MyAppWeb.WebhookController do
  use MyAppWeb, :controller
  use ShopifexWeb.WebhookController

  def handle_topic(conn, shop, "orders/create") do
    # ... do work (enqueue Oban for slow work and 200 immediately) ...
    send_resp(conn, 200, "ok")
  end

  # CRITICAL: keep Shopifex's mandatory GDPR handlers.
  def handle_topic(conn, shop, topic), do: super(conn, shop, topic)
end
```
Topics are subscribed on install from `config :shopifex, :webhook_topics` (always keep
`"app/uninstalled"`). Webhook HMAC is verified for you. Subscriptions self-heal on the
next token re-exchange.

## Billing (PaymentGuard)
Guard a route; unpaid shops get bounced to a plan picker, charged, then let back in.
```elixir
pipeline :require_pro do
  plug Shopifex.Plug.PaymentGuard, "pro"
end
```
Config `payment_guard`, `plan_schema`, `grant_schema`, `payment_redirect_uri`; a
`MyApp.Shops.PaymentGuard` that `use Shopifex.PaymentGuard`; a `PaymentController` that
`use ShopifexWeb.PaymentController`. A **Plan** is a DB row that `grants` a named string;
create with `Shopifex.Shops.create_plan/1` (use `test: true` on dev stores). Override
`create_charge/2` for custom pricing (recurring/one-time/usage/discounts).

## Config (minimum)
```elixir
config :shopifex,
  app_name: "MyApp",
  shop_schema: MyApp.Shop,
  repo: MyApp.Repo,
  web_module: MyAppWeb,
  scopes: "read_orders,read_products",          # MUST mirror shopify.app.toml [access_scopes]
  webhook_topics: ["app/uninstalled", "orders/create"],
  webhook_uri: "https://your-tunnel/webhook",
  api_version: "2026-04",
  api_key: System.get_env("SHOPIFY_API_KEY"),
  secret: System.get_env("SHOPIFY_API_SECRET")
```
Shop schema needs the token-lifecycle columns (`token_expires_at`, `refresh_token`,
`refresh_token_expires_at`; nullable `scope`). `mix shopifex.install` generates them.
The endpoint's `Plug.Parsers` must use `body_reader: {ShopifexWeb.CacheBodyReader, :read_body, []}`
or webhook HMAC verification breaks.

## Testing
```elixir
import Shopifex.Test
conn = put_shopify_session(conn, shop)          # loads current_shop + a valid Bearer id_token
# also: sign_session_token/2, sign_webhook/2, put_webhook_hmac/3, sign_query_hmac/2
```
Stub Shopify HTTP with `Req.Test` via `config :shopifex, :req_options, plug: {Req.Test, MyStub}`.

## UI
Embedded apps use Shopify's CDN App Bridge + **Polaris web components** (no React):
add `<meta name="shopify-api-key">` + `app-bridge.js` + `polaris.js`, then use `<s-page>`,
`<s-section>`, `<s-button>` in HEEx. The global `shopify` object gives `shopify.toast`,
`shopify.resourcePicker`, `shopify.idToken()` (call from a small JS hook).

## Gotchas (read before writing code)
1. **`:scopes` config must match `shopify.app.toml` `[access_scopes]`** — `EnsureScopes`
   (in `:shopify_session`) **raises** by default on a mismatch, on every load. Editing the
   TOML needs `shopify app deploy` to take effect.
2. **Custom `handle_topic/3` replaces ALL clauses** — add the `super(conn, shop, topic)`
   catch-all or you drop the mandatory GDPR webhooks and fail app review.
3. **`EnsureScopes` raises by default**, it does not OAuth-redirect. Opt into the legacy
   redirect with `on_missing_scopes: :redirect`.
4. **`read_orders`/order data is protected customer data** — works on dev stores, needs
   Shopify approval before reading live orders in production.
5. **`Shopifex.API.graphql` returns `{:error, errors}` even on HTTP 200** when the GraphQL
   response has partial `errors` (errors take precedence) — handle it.
6. **Never cache the access token** — Shopifex refreshes expiring offline tokens; always
   go through `Shopifex.API.graphql/3`.
7. **`shopify app dev` doesn't fit Phoenix** (it expects a Node project). Run
   `mix phx.server` + your own tunnel (`ngrok http 4000`); use `shopify app deploy` to push
   scopes/config.
8. **Don't reach for legacy OAuth** for new apps — managed install is the default and the
   `/auth` route handles it.
