<img width="350" src="https://github.com/ericdude4/shopifex/raw/master/guides/images/logo.png" alt="Shopifex">

---

A simple boilerplate package for creating Shopify embedded apps with the Elixir Phoenix framework.

> **This is a fork** of [ericdude4/shopifex](https://github.com/ericdude4/shopifex) (v2.4.0). See [Why this fork exists](#why-this-fork-exists) below.

## Installation (fork)

```elixir
def deps do
  [
    {:shopifex, github: "josefrichter/shopifex"}
  ]
end
```

If you want the original upstream package from Hex instead, use `{:shopifex, "~> 2.4"}`.

## Why this fork exists

**Forked in March 2026** to add support for Shopify's modern embedded app architecture.

### The problem

Shopify has moved to **managed app installation** and **session tokens** as the default for all embedded apps. The key changes:

- **Managed installation** — Shopify sends an `id_token` JWT on app load instead of the traditional OAuth authorization code redirect. The app must exchange this token for an offline access token via [RFC 8693 token exchange](https://shopify.dev/docs/apps/build/authentication-authorization/access-tokens/token-exchange).
- **Session tokens** — Embedded apps run in an iframe where browsers block third-party cookies. Auth must work without cookies. Shopify's App Bridge provides session tokens via `shopify.idToken()`.
- **No more OAuth redirects in iframes** — The old OAuth install flow (redirect to Shopify → approve scopes → redirect back) breaks inside iframes. Managed installation handles this transparently.

Upstream Shopifex (v2.4.0) only supports the traditional OAuth code exchange flow and passes Guardian JWT tokens in URL parameters for session management. This doesn't work for new Shopify apps that use managed installation.

### What this fork adds

| Feature | Description |
|---|---|
| **`Shopifex.Plug.ManagedInstall`** | New plug that intercepts `id_token` from Shopify, exchanges it for an offline access token, and creates the shop record. Drop it into your pipeline before `ShopifySession`. |
| **`:embedded` LiveView on_mount** | `ShopifexWeb.LiveSession` now has an `:embedded` hook that reads the shop from the Phoenix session without requiring tokens in URLs or LiveSocket connect params. |
| **`:managed_install` pipeline** | Available via `ShopifexWeb.Routes.pipelines/0` for easy router setup. |
| **HTTPoison → Req** | All HTTP calls replaced with [Req](https://hex.pm/packages/req) (modern Elixir HTTP client). |

### Why not upstream?

Upstream Shopifex is sparsely maintained — roughly one commit every few months since 2023, single maintainer. A [PR for Shopify CLI compatibility](https://github.com/ericdude4/shopifex/pull/81) has been open since March 2025. The changes needed here are fundamental (new auth flow, new plug, dependency swap), not small patches, and waiting for upstream review wasn't viable.

### Why not other Elixir Shopify libraries?

We evaluated every Shopify-related Elixir package on Hex and GitHub (as of March 2026):

| Library | What it is | Why it didn't work |
|---|---|---|
| **[shopifex](https://github.com/ericdude4/shopifex)** (upstream) | Full framework — OAuth, webhooks, billing, session management | Only supports traditional OAuth, not managed installation. This fork fixes that. |
| **[shopify_graphql](https://github.com/malomohq/shopify-graphql-elixir)** | GraphQL API client | API client only — no auth, no webhooks, no app framework. Complementary, not a replacement. |
| **[shopify](https://github.com/nsweeting/shopify)** (nsweeting) | REST API client | Abandoned since 2019. Uses HTTPoison + Poison. No GraphQL. |
| **[exshopify](https://github.com/sticksnleaves/exshopify)** | REST API client with OAuth | Inactive since 2021. |
| **[ex_shopify_app](https://hex.pm/packages/ex_shopify_app)** | Framework attempt | 0 stars, 7 commits, GPL licensed, no documentation. |
| **[ueberauth_shopify](https://hex.pm/packages/ueberauth_shopify)** | Ueberauth OAuth strategy | Traditional OAuth only — exactly what Shopify is moving away from. |
| **[plug_shopify_jwt](https://hex.pm/packages/plug_shopify_jwt)** | JWT validation plug | Tiny, last updated 2021. |

**Shopifex is the only viable full framework for Shopify apps in Elixir.** The ecosystem is thin compared to Node.js (official `@shopify/shopify-app-js`) or Ruby (official `shopify_api` gem). Forking was the only practical path.

### Existing shopifex forks

We also checked all active forks of upstream shopifex. None had implemented managed installation or replaced the Guardian JWT auth flow:

- **briansage/shopifex** — Phoenix 1.7+ compat fixes, CSP improvements. Still uses Guardian JWT.
- **NexPB/shopifex** — Shopify CLI webhook management (PR #81). Traditional OAuth, not token exchange.
- **helording/shopifex**, **pepicrft/shopifex** — minor variations of NexPB's changes.

---

## Learning resources

- **[Getting Started tutorial](https://josefrichter.github.io/shopifex/)** — a
  beginner-friendly walkthrough (source: [`docs/index.html`](docs/index.html)) that
  builds a live "Bestsellers" LiveView dashboard (auth, Admin GraphQL, webhooks +
  PubSub, billing, App Bridge/Polaris).
- **[Parity matrix](docs/parity-matrix.md)** — how Shopifex compares to Shopify's
  official JS and Ruby libraries.

## Claude Code plugin

This repo doubles as a [Claude Code](https://docs.claude.com/en/docs/claude-code)
plugin marketplace. The bundled `shopifex` skill teaches Claude the library's
conventions and gotchas so it scaffolds Shopifex features correctly (managed-install
auth, `Shopifex.API.graphql/3`, webhooks, billing, testing, App Bridge/Polaris UI).

```
/plugin marketplace add josefrichter/shopifex
/plugin install shopifex@shopifex
```

The skill lives in `skills/shopifex/` (`SKILL.md` + `reference.md`) and auto-activates
when you work in a Phoenix app that uses Shopifex.

---

## Original Installation

The package can be installed
by adding `shopifex` to your list of dependencies in `mix.exs`: (note, OTP 22 or greater required)

```elixir
def deps do
  [
    {:shopifex, "~> 2.2"}
  ]
end
```
## Quickstart
#### Run the install script
This will install all of the supported Shopifex features.
```
mix shopifex.install
```
Follow the output `config.ex` and `router.ex` instructions from the install script.
#### Run migrations
```
mix ecto.migrate
```
#### Update Shopify app details
With **managed installation** (the default for new embedded apps), Shopify loads
your app with a fresh `id_token` on every page load and the `:managed_install`
pipeline exchanges it for an offline access token — no OAuth redirect URLs are
required. Declare your access scopes in `shopify.app.toml` (`[access_scopes]`).

Replace the tunnel URL with your own where applicable.
- Set "App URL" to `https://my-app.ngrok.io/auth`
- Add your Shopify app's API key and API secret key to
  `config :shopifex, api_key: "your-api-key", secret: "your-api-secret"`

> **Legacy OAuth (compatibility only):** if you still rely on the authorization-code
> OAuth flow, also add `https://my-app.ngrok.io/auth/install` and
> `https://my-app.ngrok.io/auth/update` to your app's "Allowed redirection URL(s)"
> and set `redirect_uri` / `reinstall_uri` in config (see below). New apps should
> not need these.

## Manual Installation
Create the shop schema where the installation data will be stored. Include the
token-lifecycle columns so Shopify's **expiring** offline tokens (required for
public apps from April 1, 2026) can be refreshed in the background:
```
mix phx.gen.schema Shop shops url:string access_token:string scope:string \
  token_expires_at:utc_datetime refresh_token:string refresh_token_expires_at:utc_datetime
mix ecto.migrate
```
The four token columns are nullable — legacy/non-expiring installs round-trip with
`nil` expiry values. (`mix shopifex.install` generates this schema for you.)

Add the `:shopifex` config settings to your `config.ex`. More config details [here](https://hexdocs.pm/shopifex)

```elixir
config :shopifex,
  app_name: "MyApp",
  shop_schema: MyApp.Shop,
  web_module: MyAppWeb,
  repo: MyApp.Repo,
  webhook_uri: "https://myapp.ngrok.io/webhook",
  scopes: "read_inventory,write_inventory,read_products,write_products,read_orders",
  api_key: "shopifyapikey123",
  secret: "shopifyapisecret456",
  api_version: "2026-04", # Admin GraphQL API version used by Shopifex.API
  webhook_topics: ["app/uninstalled"], # These are automatically subscribed on a store upon install
  shops_context_client: Shopifex.ShopsContextClient # Optional. Overridable context module which Shopifex uses to fetch and manage common app state

# Optional managed-install hooks (customise shop creation / post-install side effects):
#   managed_install_callbacks: MyApp.ManagedInstallCallbacks

# Legacy OAuth fallback only — not needed for managed installation:
#   redirect_uri: "https://myapp.ngrok.io/auth/install",
#   reinstall_uri: "https://myapp.ngrok.io/auth/update",
```

> **Webhooks — choose one mechanism, not both.** `:webhook_topics` registers
> webhook subscriptions imperatively via the GraphQL Admin API, on install and
> on every token re-exchange. If you instead declare webhooks declaratively in
> `shopify.app.toml` (`[webhooks]`, Shopify's modern recommended path), **set
> `webhook_topics: []`**. Otherwise Shopifex reconciles against Shopify's
> `webhookSubscriptions` query — which returns only shop-scoped (API-created)
> subscriptions, *not* your TOML/app-config ones — so each TOML topic looks
> unregistered and gets a duplicate API subscription, and the store can receive
> every event twice.

Update your `endpoint.ex` to include the custom body parser. This is necessary for HMAC validation to work.

```elixir
plug Plug.Parsers,
  parsers: [:urlencoded, :multipart, :json],
  pass: ["*/*"],
  body_reader: {ShopifexWeb.CacheBodyReader, :read_body, []},
  json_decoder: Phoenix.json_library()
```

Add this line near the top of `router.ex` to include the Shopifex pipelines

```elixir
require ShopifexWeb.Routes
ShopifexWeb.Routes.pipelines()
```
Now the following pipelines are accessible:

- `:managed_install` -> Runs `Shopifex.Plug.ManagedInstall`: verifies Shopify's `id_token`, exchanges it for an expiring offline access token, and builds the session. Already included in `auth_routes/1` before `:shopify_session`.
- `:shopify_session` -> Verifies the App Bridge `id_token` (or the legacy HMAC), and makes session information available via `Shopifex.Plug` API. No-ops when `:managed_install` already loaded the shop. Also removes iFrame blocking headers so app can render in Shopify admin.
- `:shopify_webhook` -> Validates Shopify webhook request HMAC (Base64, constant-time) and makes session information available via `Shopifex.Plug` API.
- `:shopify_admin_link` -> Validates Shopify admin link & bulk action link requests and makes session information available via `Shopifex.Plug` API.
- `:shopify_api` -> Ensures that a valid Shopify session token is present in the `Authorization` header. Useful for async requests between your SPA front end and Shopifex backend.
- `:shopifex_browser` -> Same as your normal `:browser` pipeline, except it calls `Shopifex.Plug.LoadInIframe`.

Now add this basic example of these plugs in action in `router.ex`. These endpoints need to be added to your Shopify app whitelist

### Routing
```elixir
# Include all auth (managed installation, plus legacy OAuth install/update) routes.
# The generated `/auth` route runs the `:managed_install` pipeline before
# `:shopify_session`, so token exchange happens automatically on app load.
ShopifexWeb.Routes.auth_routes(MyAppWeb.AuthController)

# Endpoints accessible within the Shopify admin panel iFrame.
# Don't include this scope block if you are creating a SPA.
scope "/", MyAppWeb do
  pipe_through [:shopifex_browser, :shopify_session]

  get "/", PageController, :index
end

# Make your webhook endpoint look like this
scope "/webhook", MyAppWeb do
  pipe_through [:shopify_webhook]

  post "/", WebhookController, :action
end

# Place your admin link endpoints in here
scope "/admin-links", MyAppWeb do
  pipe_through [:shopify_admin_link]

  get "/do-a-thing", AdminLinkController, :do_a_thing
end
```

Create a new controller called `auth_controller.ex` to handle the initial iFrame load and installation

```elixir
defmodule MyAppWeb.AuthController do
  use MyAppWeb, :controller
  use ShopifexWeb.AuthController

  # Thats it! Validation, installation are now handled for you :)
  
  # Optionally, override the `after_install` callback
  def after_install(conn, shop, oauth_state) do
    # TODO: send yourself an e-mail
    # follow default behaviour.
    super(conn, shop, oauth_state)
  end
end
```
Setting up your application as a SPA? Read this before continuing [Single Page Applications](#single-page-applications)

create another controller called `webhook_controller.ex` to handle incoming Shopify webhooks (optional)

```elixir
defmodule MyAppWeb.WebhookController do
  use MyAppWeb, :controller
  use ShopifexWeb.WebhookController

  # add as many handle_topic/3 functions here as you like! This basic one handles app uninstallation
  def handle_topic(conn, shop, "app/uninstalled") do
    Shopifex.Shops.delete_shop(shop)

    conn
    |> send_resp(200, "success")
  end

  # Mandatory Shopify shop data erasure GDPR webhook. Simply delete the shop record
  def handle_topic(conn, shop, "shop/redact") do
    Shopifex.Shops.delete_shop(shop)

    conn
    |> send_resp(204, "")
  end

  # Mandatory Shopify customer data erasure GDPR webhook. Simply delete the shop (customer) record
  def handle_topic(conn, shop, "customers/redact") do
    # If you store customer data you can delete it here.

    conn
    |> send_resp(204, "")
  end

  # Mandatory Shopify customer data request GDPR webhook.
  def handle_topic(conn, _shop, "customers/data_request") do
    # Send an email of the shop data to the customer.
    conn
    |> send_resp(202, "Accepted")
  end
end
```
## Maintaining session between page loads for server-rendered applications
With managed installation you no longer pass tokens around yourself. Shopify's
App Bridge appends a fresh `id_token` to every embedded page load (and sends it as
an `Authorization: Bearer` token on authenticated fetches). The `:managed_install`
and `:shopify_session` pipelines verify that token and load the shop, so a plain
link to another `:shopify_session` route just works:

```heex
<.link navigate={~p"/"}>home</.link>
```

`Shopifex.Plug.current_shop(conn)` is available in any request that passes through
a `:shopify_session`, `:managed_install`, or `:shopify_proxy` pipeline. (For
`:shopify_proxy`, `Shopifex.Plug.LoadProxyShop` resolves the shop from the signed
`shop` param once the HMAC is verified; it is `nil` if that shop isn't in your
database — see [App proxy](#app-proxy).) For LiveView, use the
`shopifex_live_session` macro below.

> **Legacy (v2) token-in-URL pattern.** Older apps threaded
> `Shopifex.Plug.session_token(conn)` through a `token` query parameter on every
> link/form. This still works (`session_token/1` reads `id_token`, `token`, and the
> `Bearer` header), but it is no longer necessary for managed-install apps and is
> kept only for backward compatibility.

## App proxy

[App proxy](https://shopify.dev/docs/apps/build/online-store/display-dynamic-data)
requests are signed with a `signature` param (not the admin `hmac`). The
`:shopify_proxy` pipeline verifies that signature and loads the shop:

```elixir
scope "/proxy", MyAppWeb do
  pipe_through [:shopify_proxy]

  get "/", ProxyController, :show
end
```

In the controller the shop resolved from the signed `shop` param is available as
`Shopifex.Plug.current_shop(conn)` (`nil` if that shop isn't in your database).
`Shopifex.Plug.LoadProxyShop` does this right after `Shopifex.Plug.ValidateHmac`;
pass `on_missing: :halt` to reject unknown shops with a `401` instead of passing
through. The built-in `:shopify_proxy` pipeline passes
`ValidateHmac, require_timestamp: true`, so a signed proxy URL without a
`timestamp` is rejected rather than replayable forever.

Storefront / proxy requests can legitimately lag past the default 90s HMAC
`timestamp` tolerance. Relax it for the proxy pipeline **only** (without widening
the admin-load replay window) with a per-plug option — build your own pipeline.
Keep `require_timestamp: true` so you don't lose the replay protection:

```elixir
pipeline :shopify_proxy_relaxed do
  plug :fetch_session
  plug Shopifex.Plug.FetchFlash
  plug Shopifex.Plug.ValidateHmac, timestamp_tolerance_seconds: 600, require_timestamp: true
  plug Shopifex.Plug.LoadProxyShop
end
```

## Using LiveView in your embedded app
There are two special considerations to using LiveView in your embedded app.

First, you'll need to get the LiveView socket configured to work in the Shopify iframe. This [elixir](https://elixirforum.com/t/how-to-embed-a-liveview-via-iframe/65066) post gives some excellent tips.

Second, you'll need to copy the `current_shop` and `session_token` from the Plug connection to the socket and make them available in your assigns on_mount. The `@current_shop` will be your authenticated Shop resource, and `@session_token` can be used when you navigate between live views similar to the template links above.  The `shopifex_live_session` macro is a drop-in replacement fom `live_session` to handle this.

```
scope "/", ShoplensWeb do
  pipe_through [:shopifex_browser, :shopify_session]

  ShopifexWeb.Routes.shopifex_live_session :embedded, layout: {MyApp.Layouts, :embedded} do
    live "/", MyAppLive
    ...
  end

  # If you need more control, you can still use `live_session` like this:
  #  live_session :embedded, 
  #    session: {ShopifexWeb.LiveSession, :put_shop_in_session, []}, 
  #    on_mount: {ShopifexWeb.LiveSession, :assign_shop_to_socket} do
  #       ...
  #   end
end
```

## Update app permissions

With managed installation, **change your access scopes in `shopify.app.toml`**
(`[access_scopes]`) and deploy your app config — Shopify re-grants the scopes the
next time the merchant loads the app, and `:managed_install` re-exchanges the
token. `Shopifex.Plug.EnsureScopes` raises an actionable error if a shop is missing
a required scope, so you find config drift fast.

> **Legacy OAuth scope update (compatibility only).** If you opt into the OAuth
> fallback (`plug Shopifex.Plug.EnsureScopes, on_missing_scopes: :redirect`), add
> `your-redirect-url.com/auth/update` to Shopify's whitelist and redirect the
> merchant to re-authorize:
>
> ```
> https://{shop-name}.myshopify.com/admin/oauth/request_grant?client_id=API_KEY&redirect_uri={YOUR_REINSTALL_URL}/auth/update&scope={YOUR_SCOPES},read_customers
> ```

## Add payment guards to routes
This system allows you to use the `Shopifex.Plug.PaymentGuard` plug. If the merchant does not have an active grant associated with the named guard, it will redirect them to a plan selection page, allow them to pay, and handle the payment callback all automatically. I am working on the admin panel where you can register Plan objects which grant `premium_plan` (for example) - but for now these need to be entered manually into the database.

Generate the schemas

`mix phx.gen.schema Shops.Plan plans name:string price:string features:array:string grants:array:string test:boolean usages:integer type:string`

`mix phx.gen.schema Shops.Grant grants shop_id:references:shops charge_id:integer grants:array:string remaining_usages:integer total_usages:integer`

Add the config options:
```elixir
config :my_app,
  payment_guard: MyApp.Shops.PaymentGuard,
  grant_schema: MyApp.Shops.Grant,
  plan_schema: MyApp.Shops.Plan,
  payment_redirect_uri: "https://myapp.ngrok.io/payment/complete"
```
> The plan-selection page renders with Polaris web components loaded from
> Shopify's CDN, so there are no Shopifex static assets to serve (the old
> `Plug.Static, at: "/shopifex-assets"` step is no longer needed as of 3.0).

Create the payment guard module:
```elixir
defmodule MyApp.Shops.PaymentGuard do
  use Shopifex.PaymentGuard
end
```
Create a new payment controller:
```elixir
defmodule MyAppWeb.PaymentController do
  use MyAppWeb, :controller
  use ShopifexWeb.PaymentController
end
```
Add payment routes to `router.ex`:
```elixir
ShopifexWeb.Routes.payment_routes(MyAppWeb.PaymentController)
```

> ⚠️ **Multi-node deploys (Fly.io, etc.):** use `Shopifex.RedirectAfter.Ecto`, not
> the in-memory default. The billing flow stores a `charge_id → redirect_after`
> entry at `/payment/select-plan` and reads it back at `/payment/complete`. The
> default `Shopifex.RedirectAfterAgent` keeps that in a **node-local** `Agent`, so
> when Shopify's confirmation returns to a *different* node the lookup misses —
> `complete_payment/2` returns `{:error, :forbidden}` **and the grant is never
> created** (the merchant is still charged). The shipped, DB-backed
> `Shopifex.RedirectAfter.Ecto` is safe across nodes:
>
> ```elixir
> config :shopifex, :redirect_after_agent, Shopifex.RedirectAfter.Ecto
> ```
>
> Add its backing table (`mix shopifex.install` generates both the config and this
> migration for new apps):
>
> ```elixir
> create table(:shopifex_charge_redirects, primary_key: false) do
>   add :charge_id, :bigint, primary_key: true
>   add :redirect_after, :text, null: false
>   add :inserted_at, :utc_datetime, null: false
> end
> ```
>
> On a single node the in-memory default is fine. Either way, a missed lookup now
> logs an actionable `Logger.error` instead of failing silently.

To manage plans, I recommend using [kaffy admin package](https://github.com/aesmail/kaffy)

Now you can protect routes or controller actions with the `Shopifex.Plug.PaymentGuard` plug. Here is an example of it in action on an admin link
```elixir
defmodule MyAppWeb.AdminLinkController do
  use MyAppWeb, :controller
  require Logger

  plug Shopifex.Plug.PaymentGuard, "premium_plan" when action in [:premium_function]
  
  def premium_function(conn, _params) do
    shop = Shopifex.Plug.current_shop(conn)
    
    # Wow, much premium.
    conn
    |> send_resp(200, "Hi there, #{shop.url}!")
  end
end
```
### Single Page Applications
SPA Shopify applications are also supported with Shopifex for developers who wish to host their front-end application separately from the back-end. This approach takes advantage of [Shopify session tokens](https://shopify.dev/concepts/apps/building-embedded-apps-using-session-tokens).

Adjust your `router.ex` file. You may notice some routes are no longer necessary compared to the quick-start guide.
```elixir
ShopifexWeb.Routes.pipelines()

# These routes will take care of installation/update
ShopifexWeb.Routes.auth_routes(ShopifyAppWeb)

# API routes for your SPA to hit with the axios instance
scope "/api", MyAppWeb do
  pipe_through [:shopify_api]
  
  # An endpoint which your SPA can call on load to get whatever initialization data your app needs.
  # The options macro is required to allow CORS requests on the route.
  options "/initialize", AuthController, :initialize
  get "/initialize", AuthController, :initialize
  
  # Add authenticated routes here as needed.
end
```
And for that `/initialize` endpoint, consider this adjustment to `MyAppWeb.AuthController` and update based on your needs. Perhaps you also want to serialize and return some more information needed by your SPA at startup.
```elixir
defmodule MyAppWeb.AuthController do
  use MyAppWeb, :controller
  use ShopifexWeb.AuthController
  
  def initialize(conn, _params) do
    # Guardian is no longer used — the `:shopify_api` pipeline verifies the
    # App Bridge session token and loads the shop.
    shop = Shopifex.Plug.current_shop(conn)

    render(conn, "initialize.json", %{shop: shop})
  end
end
```
Load [App Bridge](https://shopify.dev/docs/api/app-bridge-library) from Shopify's
CDN with your API key in a meta tag. App Bridge auto-initializes and exposes a
global `shopify` object, and automatically attaches a fresh session token as the
`Authorization: Bearer` header on same-origin `fetch` calls — which is exactly
what the `:shopify_api` pipeline (`Shopifex.Plug.ShopifyApiAuth`) verifies.

```html
<meta name="shopify-api-key" content="MY_SHOPIFY_API_KEY" />
<script src="https://cdn.shopify.com/shopifycloud/app-bridge.js"></script>
```
```javascript
// App Bridge attaches the Bearer token automatically — no axios interceptor needed.
const res = await fetch('/api/initialize');
const sessionData = await res.json();

// If you need the raw token (e.g. for a WebSocket), ask App Bridge for one:
const token = await shopify.idToken();
```

> The old `import createApp from '@shopify/app-bridge'` / `createApp({ apiKey, shopOrigin })`
> flow (and the axios session-token tutorial) is the deprecated App Bridge v2/v3 API
> and no longer applies — the CDN App Bridge above is the current path.
