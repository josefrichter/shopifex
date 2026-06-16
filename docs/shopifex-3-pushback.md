# Pushback: issues in `josefrichter/shopifex@modern-shopifex`

Findings from reviewing the `modern-shopifex` branch against Stock Sorted's
needs (see `docs/shopifex-3-migration.md`). Each was verified by reading the
fork source directly. Line numbers are from the branch as of this review;
re-confirm before editing.

Ordered by severity. Items **B1–B3** should block adoption of the affected
code paths until resolved.

## Resolution status

All items addressed on `modern-shopifex` (see `CHANGELOG.md`). Code fixes ship
with regression tests; the rest are documentation or recorded decisions.

| Item | Status | What was done |
|---|---|---|
| **B1** charge-id key mismatch | ✅ **Fixed** | `RedirectAfterAgent.set/2` + `get/1` now coerce the key consistently; `test/shopifex/redirect_after_agent_test.exs` locks the round-trip. |
| **B2** in-memory Agent / multi-node | 📝 **Documented** | Moduledoc warns about the single-node limitation; swap via `config :shopifex, :redirect_after_agent`. |
| **B3** no per-exchange callback | ✅ **Fixed** | Added `Shopifex.ManagedInstall.Callbacks.after_exchange/2` (fires on install **and** refresh, with `new?`); tested on both paths. |
| **B4** synchronous callback blocks request | 📝 **Documented** | Callbacks moduledoc states they run synchronously — spawn a `Task` for slow work. |
| **S1** tokens in LV session | ✅ **Fixed** | `LiveSession.put_shop_in_session/1` serializes only the shop URL; `on_mount` reloads server-side. Test asserts no token in the session. |
| **M1** webhooks reconciled every re-exchange | 📝 **Documented** | `ManagedInstall` moduledoc explains the cadence/cost (idempotent, ≤ every 50 min, never on the hot path). |
| **M2** proxy: no shop load, 90s window | 📝 **Documented** | `ValidateHmac` moduledoc notes it verifies the signature only (no shop assign) and the configurable tolerance. |
| **Q1** no cookieless `auth_token` bridge | 📝 **Decision documented** | Deliberately removed — App Bridge supplies a fresh `id_token` per load; apps with their own signed redirect keep it as a custom plug clause. |
| **Q2** GDPR `defoverridable` footgun | ✅ **Acknowledged** | Already documented (moduledoc + tutorial + skill); left as-is. |

---

## B1 — `RedirectAfterAgent` set/get key types don't match → billing flow broken

**Severity: blocker (fork bug). The macro billing path fails as shipped.**

**Files:**
- `lib/shopifex/redirect_after_agent.ex:21` (`get/1` coerces binary → integer)
- `lib/shopifex/redirect_after_agent.ex:31-34` (`set/2` stores the key as-is, no coercion)
- `lib/shopifex_web/controllers/payment_controller.ex:90` (`set(charge["id"], …)`)
- `lib/shopifex_web/controllers/payment_controller.ex:224-237` (`unwrap_charge/3`)
- `lib/shopifex_web/controllers/payment_controller.ex:259-260` (`get(charge_id)`)

**What happens:**
1. `unwrap_charge/3` returns the charge id as a **string**:
   `%{"id" => List.last(String.split(gid, "/"))}` → e.g. `"4019552312"`.
2. `select_plan/2` calls `redirect_after_agent.set(charge["id"], redirect_after)`,
   so the Agent map is keyed by the **string** `"4019552312"`. `set/2` does no
   coercion.
3. Shopify redirects to `complete_payment/2` with `charge_id` as a URL param
   (a string), which calls `redirect_after_agent.get(charge_id)`.
4. `get/1` has `get(charge_id) when is_binary(charge_id), do: get(String.to_integer(charge_id))`
   — it looks up the **integer** `4019552312`.
5. `Map.get(%{"4019552312" => url}, 4019552312)` → **`nil`**. `complete_payment`
   then falls to `{:error, :forbidden}` and **the grant is never created**.

The `@callback set` typespec already declares `charge_id :: pos_integer()`, but
the only caller (`select_plan/2`) passes a string, so the contract is violated
at the call site and the two functions disagree on key type.

**Suggested fix:** normalize the key to a single type in **both** `set/2` and
`get/1` (and ideally enforce it in the typespec). Cleanest: coerce binary →
integer in `set/2` as well, matching `get/1` and the integer `grants.charge_id`
column. Alternatively keep everything as strings and drop the `String.to_integer`
in `get/1`. Either way, set and get must agree.

**How to verify:** end-to-end test of `select_plan` → `complete_payment` for a
recurring plan (`appSubscriptionCreate`), asserting a `Grant` row is created and
`after_payment/5` redirects. A unit test on `RedirectAfterAgent` that `set`s with
the value `unwrap_charge` actually produces and `get`s it back is enough to lock
the regression.

---

## B2 — `RedirectAfterAgent` is an in-memory `Agent` → not cross-node safe

**Severity: blocker for multi-node deploys (Stock Sorted runs on Fly.io).**

**File:** `lib/shopifex/redirect_after_agent.ex` (whole module — `use Agent`, local `name: __MODULE__`).

**What happens:** `select_plan/2` writes the redirect-after entry into a
node-local `Agent`. Shopify's confirmation redirect to `/payment/complete` can
land on a **different node** than the one that handled `select_plan`. That node's
Agent has no entry → `get/1` returns `nil` → `{:error, :forbidden}`, grant never
created. Intermittent and load-balancer-dependent, so it will pass in dev/single-node
and fail in production.

**Suggested fix:** persist the charge→redirect association somewhere shared
(a `charges` table keyed by `charge_id`, or reuse the grant row created up front,
or a distributed store). At minimum, document the single-node limitation loudly
so apps know the macro billing path is unsafe behind a multi-node load balancer.

**How to verify:** simulate `set` on one process and `get` on another with no
shared Agent state (or document the constraint and the recommended persistent
alternative).

---

## B3 — No post-exchange callback; `ManagedInstall` only exposes install-time hooks

**Severity: high — silently changes behavior for apps with per-load side effects.**

**File:** `lib/shopifex/plug/managed_install.ex:200-219` (`persist_shop/3`).

**What happens:** `ManagedInstall` exposes exactly two app hooks via
`Shopifex.ManagedInstall.Callbacks`: `insert_shop/1` and `after_install/1`. Both
run **only on first install** (`persist_shop(true, …)` at line 200-206). The
refresh path (`persist_shop(false, …)` at line 215-219) runs only
`update_shop` + `configure_webhooks` — **there is no app callback on token
re-exchange**.

Stock Sorted currently runs a side effect on *every* exchange (install **and**
the 50-minute refresh) — `enqueue_checkout_protection_sync/1`, outside the
install-only guard. The fork gives no clean extension point for that; folding it
into `after_install/1` would silently stop it firing on refreshes.

**Suggested fix:** add an `after_exchange(shop, new?)` (or `after_refresh/1`)
callback to `Shopifex.ManagedInstall.Callbacks`, invoked on both branches of
`persist_shop/3`, with a no-op default. This lets apps run per-exchange logic
without re-implementing the plug or stacking a second custom plug clause.

**How to verify:** a callback test asserting the new hook fires on both first
install and a forced-stale re-exchange.

---

## B4 — `after_install/1` runs synchronously inside the plug

**Severity: high — blocks the embedded page request on slow work.**

**File:** `lib/shopifex/plug/managed_install.ex:204` (`callbacks.after_install(shop)` in the request path).

**What happens:** `after_install/1` is called synchronously during `call/2`, so
any slow side effect (profile fetch, snapshot, analytics, external sync) blocks
the merchant's first page load. The moduledoc says side effects "belong in your
AuthController / shop-creation path," but the only hook the plug offers runs
in-line in the plug.

**Suggested fix:** either run `after_install/1` (and the proposed `after_exchange`)
inside a supervised `Task`, or document explicitly that callbacks **must not
block** and apps are responsible for spawning their own async work. Stock Sorted
already wraps these in `InventoryPool.Async.run/1`; that pattern should be the
documented contract, or the library should own it.

---

## S1 — `LiveSession` serializes the whole shop struct (incl. tokens) into the LV session

**Severity: high (security / token exposure).**

**File:** `lib/shopifex_web/live_session.ex:32-36` (`put_shop_in_session/1`) and `:79-87` (`on_mount(:embedded, …)`).

**What happens:** `put_shop_in_session/1` puts the entire `current_shop` struct
into the LiveView session map:

```elixir
%{"session_token" => session_token, "current_shop" => current_shop}
```

The LiveView session is **signed but not encrypted** by default, so its contents
(including `access_token` and `refresh_token`) are readable client-side from the
serialized session payload embedded in the page. Both `:assign_shop_to_socket`
and `:embedded` hooks carry the full struct.

Stock Sorted's own `ShopifyLiveAuth` deliberately stores only the shop id/url and
reloads the struct server-side to avoid exactly this. (This is why the migration
plan keeps the app's hook — but the fork default is a footgun for any app that
adopts it.)

**Suggested fix:** serialize only a shop identifier (id and/or url) in
`put_shop_in_session/1` and reload the shop in `on_mount`, so secrets never reach
the client. If the full struct is kept for performance, document the exposure
prominently and recommend encrypting the LV session.

**How to verify:** assert the serialized session map contains no `access_token` /
`refresh_token`.

---

## M1 — `configure_webhooks/1` runs on every 50-minute re-exchange

**Severity: medium (API-volume / rate-limit pressure). Confirm intent.**

**File:** `lib/shopifex/plug/managed_install.ex:217` (refresh branch calls `Shopifex.Shops.configure_webhooks(shop)`).

**What happens:** webhook reconciliation runs not just at install but on every
stale-token re-exchange (≤ every 50 min per active shop). It's idempotent (a
list query + creates for missing topics only), but it adds Admin API calls on a
cadence tied to merchant activity. For a busy shop that's a recurring `1 query +
N creates`-shaped probe.

**Suggested fix:** confirm this is intentional self-healing. If so, document the
cost. Optionally gate it (e.g. only reconcile if a configured signal says topics
may be stale, or throttle to once per shop per day) so it isn't paid on every
re-exchange.

---

## M2 — `ValidateHmac` doesn't load the shop and has a tight 90s window for app-proxy

**Severity: medium. Affects storefront / app-proxy consumers.**

**File:** `lib/shopifex/plug/validate_hmac.ex:19` (90s default), `:38-44` (validates HMAC only, no shop assign), `:53-66` (reads `query_params["timestamp"]`).

**What happens:**
1. The `:shopify_proxy` pipeline verifies the HMAC but **does not load the shop
   into `conn.assigns`**. Stock Sorted's `StorefrontAvailabilityController` reads
   the shop, so the app must keep its own `VerifyAppProxy` (or a thin shop-loading
   addition).
2. The timestamp tolerance defaults to **90s** (`:hmac_timestamp_tolerance_seconds`),
   vs the app's current 600s. Storefront requests that lag past 90s would 401.
3. It reads `query_params["timestamp"]` (the signed value), not merged `params` —
   this is *correct/stricter*, but app-proxy requests that don't carry timestamp
   in the query will skip the check entirely.

**Suggested fix:** consider an app-proxy-specific pipeline (or plug option) that
loads the shop into assigns, and document the 90s default + how to widen it.
This is partly a "keep the app's plug" item, but the missing shop-load is a
real capability gap for proxy consumers.

---

## Q1 — No cookieless `auth_token` redirect bridge; was it intentionally dropped?

**Severity: needs a decision.**

**Context:** the app relies on a `Phoenix.Token` (salt `"shop_auth"`, `max_age 60`)
to bridge auth across a redirect without cookies (third-party-cookie blocking in
the iframe) — see Stock Sorted `lib/inventory_pool_web/plugs/ensure_shop.ex:48-64`
and `AuthController.auth/2`. The fork's `ManagedInstall` has **no equivalent**
branch.

**Question for the fork:** is this flow now fully covered by App Bridge supplying
a fresh `id_token` on every load (making the bridge unnecessary), or was the
cookieless redirect bridge dropped without a replacement? If it's expected to be
unnecessary, please document why; if not, consider re-adding a first-class
cookieless redirect helper. The app needs a deliberate answer before deleting
its branch.

---

## Q2 — `handle_topic/3` `defoverridable` replaces *all* GDPR defaults (documented footgun)

**Severity: low (documented, but easy to trip).**

**File:** `lib/shopifex_web/controllers/webhook_controller.ex:42-73` (`__using__` ships `customers/data_request`, `customers/redact`, `shop/redact` defaults + `defoverridable handle_topic: 3`).

**What happens:** an app defining *any* `handle_topic/3` clause replaces **all**
of them, including the App-Store-required GDPR handlers, unless it adds a
`super`/fallthrough. There's an inline comment warning about this, so it's not a
bug — but it's a silent compliance risk (an app can ship without GDPR handlers
and only find out at review).

**Suggested fix (optional):** keep the GDPR handlers on a separate, non-overridable
code path (e.g. a `before`-style dispatch the app can't accidentally shadow), or
make the warning impossible to miss. Lower priority than the above; flagging for
awareness.

---

## Confirmed correct (no action — included so the implementer knows what was checked)

- `Shopifex.API.graphql/3` — proactive `ensure_fresh_token`, reactive 401
  refresh-once-retry, errors-precedence on HTTP 200, default `"2026-04"`, reads
  `config :shopifex, :req_options`. **No 429/5xx/backoff retry** (apps needing it
  must keep their own).
- `Shopifex.SessionToken` — `verify/1` + `verify/2`, `:old_secret` rotation
  fallback, distinct `:expired` error, strict HS256.
- `Shopifex.Plug.EnsureScopes` — raises by default; `:redirect` opt-in via plug
  option or `:ensure_scopes_on_missing`. (Deliberate; just confirm it's the
  desired default for managed-install apps.)
- `guardian` / `neuron` / `httpoison` fully removed from deps (only doc-comment
  mentions remain).
- `Shopifex.Shops` context is swappable via `:shops_context_client` and defaults
  cleanly over a configured `shop_schema`/`repo`.
