# Shopifex 3 dogfooding findings (from migrating Stock Sorted)

Real-world findings from migrating a production app (Stock Sorted — embedded
Phoenix/LiveView Shopify app, managed install, custom billing, app proxy,
multi-node on Fly) from the pre-3.0 Guardian-based Shopifex to
`modern-shopifex`.

The migration plan deliberately **does not work around** Shopifex gaps — each is
recorded here for a library fix. Severity: 🔴 blocker · 🟠 friction · 🟡 polish.

Status legend: **OPEN** (needs a library decision/fix) · **NOTED** (works, but
the ergonomics are worth a look).

---

## Step 3 — Managed install

### F1 🟠 OPEN — No cookieless cross-redirect auth bridge
Stock Sorted's app URL is `/auth`; Shopify always loads `/auth?id_token=…`, and
`AuthController.auth/2` then **server-redirects** the merchant to `/dashboard`.
That redirect is a new top-level request inside the iframe, so it carries **no
cookie** (third-party cookies blocked) and **no `id_token`** (the 302 `Location`
is app-controlled). Pre-3.0 Shopifex had an `auth_token` bridge for this; 3.0
removed it with no replacement.

The app had to keep a bespoke `Phoenix.Token` bridge plug
(`InventoryPoolWeb.Plugs.AuthTokenBridge`) in front of
`Shopifex.Plug.ManagedInstall` to carry identity across the redirect.

**Question for the library:** what's the blessed managed-install pattern for an
app whose app-URL route differs from its landing route? Options worth shipping or
documenting:
- A helper to forward the still-valid `id_token` through an internal redirect
  (it's short-lived but valid for the instant hop), so `ManagedInstall` re-runs
  cleanly — removing the need for any app-issued token.
- Or a first-class signed cookieless redirect bridge (what the app reinvented).
- Or guidance to set the app URL directly to the landing route and skip the
  redirect entirely.
Without one of these, every multi-route embedded app re-implements this.

### F2 🟡 NOTED — `scope: ""` is silently converted to `nil` by a normal changeset
`ManagedInstall.build_shop_attrs/2` sets `scope: body["scope"] || ""` with the
stated intent to "never persist a nil scope." But a vanilla Ecto changeset uses
`empty_values: [""]` by default, so `cast/3` turns `""` back into `nil` before
insert. The app therefore stores `nil`, defeating the guarantee.

Harmless for Stock Sorted (the column is nullable and `EnsureScopes` reads
`get_scope(shop) || ""`), but the "never nil" intent doesn't survive a standard
changeset. Either document that apps must handle nil scope anyway, or drop the
`|| ""` (since it doesn't achieve what the comment claims for normal schemas).

## Step 5 — Webhooks

### F4 🟠 OPEN — `ManagedInstall` force-registers webhooks via API, with no opt-out, overlapping toml-managed webhooks
`ManagedInstall.persist_shop/3` calls `Shopifex.Shops.configure_webhooks/1`
unconditionally — on first install **and every ~50-min re-exchange** — with no
config flag to disable it.

Stock Sorted (like most modern apps) declares its webhooks **declaratively in
`shopify.app.toml`** (`[webhooks]` + `[[webhooks.subscriptions]]`, api_version
`2026-04`), which is Shopify's recommended, versioned approach. With 3.0 the app
now gets **both** mechanisms:

- **Best case:** Shopify's managed (toml) subscriptions appear in the
  `webhookSubscriptions` query, so `configure_webhooks` finds every topic present
  and only burns a query per stale load (the M1 cost). Redundant but safe.
- **Risk case (needs real-store verification):** if managed/toml subscriptions are
  **not** returned by `webhookSubscriptions`, `configure_webhooks` will think the
  topics are missing and `webhookSubscriptionCreate` a **second** subscription per
  topic. If its `callbackUrl` (`config :shopifex, :webhook_uri`) resolves to a
  different address than the toml `uri`, that's **double webhook delivery** with
  distinct webhook-ids (so per-webhook-id idempotency won't dedupe them).

**Ask:** add `config :shopifex, :configure_webhooks_on_exchange?` (default true)
or similar so apps using toml-managed webhooks can turn the API path off. At
minimum, document that an app must choose **one** of toml-managed *or*
Shopifex-managed webhooks, not both, and explain how managed subscriptions
interact with `configure_webhooks`'s `webhookSubscriptions` query.

Stock Sorted kept the toml declaration (versioned/declarative) and is accepting
the redundant query for now, pending verification on a real store.

### F5 🟢 NOTED — GDPR override composed cleanly
The `defoverridable handle_topic: 3` + "define your own → you replace ALL"
contract worked exactly as documented. Stock Sorted defines explicit clauses for
all three GDPR topics plus `app/uninstalled` and a catch-all, so it never relies
on (and never accidentally drops) the fork defaults. No `super` needed. The
inline warning comment in `__using__` is good and was sufficient to get this
right.

## Step 6 — Billing

### F6 🔴 OPEN — `complete_payment/2` returns a bare `{:error, :forbidden}` → 500, not a clean response
On a redirect-cache miss (and any other failure of its `with`), the bundled
`ShopifexWeb.PaymentController.complete_payment/2` returns `{:error, :forbidden}`.
A Phoenix controller action **must return a `Plug.Conn`**, so unless the app
defines an `action_fallback` that maps `{:error, :forbidden}` to a response, this
raises:

```
** (RuntimeError) expected action/2 to return a Plug.Conn, all plugs must
   receive a connection (conn) and return a connection, got: {:error, :forbidden}
```

So the nice "fail loud" `Logger.error` added for B2 is immediately followed by a
confusing **500** instead of the intended 403/redirect. Reproduced in Stock
Sorted by hitting `/payment/complete` with an unknown `charge_id` (no
`action_fallback` configured).

**Fix (library):** have `complete_payment/2` `send_resp/3` (or redirect) directly
on the failure path instead of returning a tuple — e.g. a 403 with the
fail-loud message, or a redirect to the plans page. If returning `{:error, _}` is
intended, the payment setup docs must tell apps to add an `action_fallback` (and
ideally `payment_routes`/generators should scaffold one).

This is the one finding that produced a hard 500 rather than degraded/awkward
behavior. With the Ecto store in place misses are rare, but a charge-complete
that 500s is exactly when you least want a 500.

## Step 7 — App proxy

### F7 🟠 OPEN — `ValidateHmac` doesn't load the shop, so proxy controllers can't use `current_shop`
Stock Sorted's storefront app-proxy controller needs the shop in
`conn.assigns`. The fork's `:shopify_proxy` / `ValidateHmac` only verifies the
HMAC; it never loads the shop. So the app had to **keep its own
`VerifyAppProxy`** plug (HMAC verify **plus** `assign(:current_shop, shop)`),
which also uses a 600s timestamp window vs the fork's 90s default.

**Ask:** offer an app-proxy pipeline (or a `ValidateHmac` option) that resolves
and assigns the shop from the signed `shop` param — the overwhelmingly common
need for proxy endpoints. Today every proxy app re-implements the plug.

## Step 9 — Deleting superseded app modules (drop-in conformance)

### F8 🟢 NOTED — `Shopifex.Auth` and `Shopifex.SessionToken` are clean drop-ins
Deleted Stock Sorted's bespoke `InventoryPool.Auth` and
`InventoryPool.ShopifySessionToken` and repointed their (substantial) existing
test suites at `Shopifex.Auth` / `Shopifex.SessionToken` as conformance tests —
**they passed unchanged**, including:
- the one-time-use refresh_token **`SELECT FOR UPDATE` serialization** (second
  concurrent `refresh!/1` observes the first's write, no second HTTP call),
- refresh error shapes (`:no_refresh_token`, `{:refresh_failed, status}`,
  `{:refresh_request_failed, _}`),
- session-token accept/reject (valid / wrong shop / expired / bad audience).

This is the migration working as intended: real app code deleted, behavior
preserved by the library. Good result — no action needed.

### F3 🟡 NOTED — Token-field persistence regression coverage now lives library-side
Stock Sorted's most important install test guarded against dropping
`expires_in` / `refresh_token` from the token-exchange response (the bug that
took down `cookie-store-8660` for 65+ hours). That extraction+persistence now
lives entirely in `ManagedInstall.build_shop_attrs/2`. The fork should carry an
explicit test that all four token-lifecycle fields survive a token exchange, so
the regression can't reappear in the library the way it did in the app.

