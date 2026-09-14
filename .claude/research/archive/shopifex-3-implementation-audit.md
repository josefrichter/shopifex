# Shopifex 3 Implementation Audit

Date: 2026-06-16
Branch reviewed: `modern-shopifex`

This audit is for the implementation agent that will address the remaining
issues found while reviewing the `modern-shopifex` implementation against
`/Users/josefrichter/code/elixir/StockSorted/docs/shopifex-3-pushback.md`.

The explicit B1/B3/S1 fixes look correctly implemented and covered by focused
tests. The remaining work is concentrated in two areas:

1. Managed-install token refresh uses the wrong freshness source.
2. The billing redirect cache is still node-local, while the pushback doc says
   the issue is addressed.

## Resolution (2026-06-16) — both addressed on `modern-shopifex`

- **Fix 1 (token expiry):** ✅ **Done.** `ManagedInstall.token_stale?/1` now measures
  against `token_expires_at` (re-exchange when within ~10 min of expiry, or expired),
  not `updated_at`. A nil `token_expires_at` is treated as a non-expiring token (fresh),
  consistent with `Shopifex.Auth.ensure_fresh_token/1`. The fresh/stale tests were
  rewritten to prove expiry drives the decision (an old `updated_at` no longer triggers
  re-exchange; an expired token with a recent `updated_at` does) — both fail against the
  old implementation and pass now.
- **Fix 2 (multi-node billing, B2):** ✅ **Done — Option A (persistent store)
  implemented**, after the re-escalation in `docs/b2-multinode-billing-bug.md`.
  `Shopifex.RedirectAfter.Ecto` (`lib/shopifex/redirect_after/ecto.ex`) is a shipped,
  DB-backed implementation of the `Shopifex.RedirectAfterAgent` behaviour
  (`shopifex_charge_redirects` table; `set/2` upserts, `get/1` is a one-shot
  delete-and-return; charge-id coercion consistent with B1). `mix shopifex.install`
  generates that config + migration so **new apps are multi-node-safe by default**;
  the library's zero-config code default stays the in-memory agent (so existing apps
  don't crash on a missing table) but `complete_payment/2` now **fails loud**
  (`Logger.error`) on a cache miss instead of a silent `{:error, :forbidden}`. Tests:
  `test/shopifex/redirect_after/ecto_test.exs` (incl. cross-process recovery) and
  `test/shopifex_web/controllers/payment_controller_complete_test.exs` (loud-fail +
  full `select_plan → complete_payment` grant creation). README, getting-started
  tutorial, skill, and moduledoc updated; the pushback resolution table and the Stock
  Sorted migration doc (Step 6) now mark B2 fixed and configure the Ecto store.

## Required Fix 1: Use token expiry, not `updated_at`, for managed-install refresh

Severity: high

Files:

- `lib/shopifex/plug/managed_install.ex`
- `test/plug/managed_install_test.exs`

Current behavior:

- `Shopifex.Plug.ManagedInstall.token_stale?/1` checks `shop.updated_at`.
- If any unrelated update touches the shop row, an expired access token can look
  fresh.
- In that case the plug skips token exchange, builds a session with a stale
  access token, skips webhook reconciliation, and does not fire
  `after_exchange/2`.

Why this matters:

- The branch now persists explicit token lifecycle fields:
  `token_expires_at`, `refresh_token`, and `refresh_token_expires_at`.
- `Shopifex.Auth.ensure_fresh_token/1` already treats `token_expires_at` as the
  source of truth for background/API paths.
- Managed install should do the same for embedded page loads.

Implementation guidance:

- Replace the `updated_at` based check in `token_stale?/1`.
- Prefer `token_expires_at` with a safety window. For example, re-exchange when
  `token_expires_at` is nil or within the existing 50-minute managed-install
  threshold.
- Keep legacy/non-expiring behavior deliberate. If `token_expires_at == nil`
  should force re-exchange on embedded load, document that. If it should be
  treated as legacy/fresh, explain why; the current managed-install comments
  imply an embedded load should populate the new fields.
- Preserve support for `DateTime` values. `NaiveDateTime` support is optional
  only if the schema can actually store that type; otherwise avoid adding more
  datetime variants than needed.

Regression test to add:

- Existing shop has:
  - `token_expires_at` in the past.
  - current/recent `updated_at`.
  - stale `access_token`.
  - valid `refresh_token`.
- Call `ManagedInstall.call/2` with a valid `id_token`.
- Assert token exchange occurs.
- Assert the persisted shop gets the new token lifecycle fields.
- Assert `after_exchange(shop, false)` fires.
- Assert the conn session uses the refreshed token.

Also keep the existing backdated-`updated_at` test, or rewrite it so it proves
the intended expiry behavior directly rather than implementation detail.

Acceptance criteria:

- No branch in `ManagedInstall` can skip refresh solely because `updated_at` was
  touched.
- Tests fail against the current implementation and pass after the fix.
- Existing managed-install callback tests still pass.

## Required Fix 2: Resolve or accurately reclassify the multi-node billing redirect issue

Severity: high for StockSorted/Fly.io if the default billing macro path is used

Files:

- `lib/shopifex/redirect_after_agent.ex`
- `lib/shopifex_web/controllers/payment_controller.ex`
- `test/shopifex/redirect_after_agent_test.exs`
- `docs/shopifex-3-pushback.md` if this repo keeps a copy
- `/Users/josefrichter/code/elixir/StockSorted/docs/shopifex-3-pushback.md` if
  the consumer-side doc is updated separately

Current behavior:

- B1 is fixed: string charge IDs now round-trip through `set/2` and `get/1`.
- B2 is not fixed: the default implementation is still an in-memory, node-local
  `Agent`.
- The pushback doc says all items were addressed, but B2 was only documented.

Why this matters:

- In a multi-node deployment, Shopify can return to `/payment/complete` on a
  different node than the one that handled `/payment/select-plan`.
- That node has no redirect cache entry.
- `complete_payment/2` returns `{:error, :forbidden}` and no grant is created.

Choose one of these outcomes:

### Option A: Implement a persistent redirect-after store

Use this if StockSorted or the library default should support macro billing on
multi-node deployments.

Implementation guidance:

- Add a persistent storage mechanism for `charge_id -> redirect_after`.
- Reasonable options:
  - A small charges/payment_redirects table.
  - Reusing a grant/pending-grant row created before Shopify confirmation.
  - A consumer-provided persistent `redirect_after_agent` module configured via
    `config :shopifex, :redirect_after_agent`.
- Preserve the one-shot semantics of `get/1`: return the URL and consume/delete
  the entry.
- Keep charge ID normalization consistent with the B1 fix.

Regression test to add:

- Exercise `set/2` on one process/module instance and `get/1` through the
  configured persistent implementation without relying on the same in-memory
  Agent state.
- Add a controller-level test for `select_plan -> complete_payment` that proves
  a grant is created when using the persistent implementation.

Acceptance criteria:

- The default or configured StockSorted path works across nodes.
- The audit/pushback doc can honestly mark B2 fixed.

### Option B: Keep the in-memory default, but document it as an accepted limitation

Use this only if StockSorted will not use the library default billing macro path,
or if a persistent implementation will be supplied by the app later.

Implementation guidance:

- Do not call B2 fixed.
- Update the resolution table to say "Documented / accepted limitation".
- Add an explicit migration note for StockSorted:
  - "Do not use the default `Shopifex.RedirectAfterAgent` on Fly.io multi-node
    deployments."
  - "Configure a persistent `:redirect_after_agent` before enabling macro
    billing."
- Ensure the library docs make the limitation visible wherever billing setup is
  described, not only in the module docs.

Acceptance criteria:

- No document implies the default billing path is production-safe on multi-node
  Fly.io.
- There is a clear next action for StockSorted before adopting the affected path.

## Verification Commands

Run the focused pushback suite:

```sh
mix test test/plug/managed_install_test.exs \
  test/shopifex/redirect_after_agent_test.exs \
  test/shopifex_web/live_session_test.exs \
  test/shopifex_web/controllers/payment_controller_charge_test.exs
```

Then run the broader relevant suites:

```sh
mix test test/shopifex/auth_test.exs test/shopifex/api_test.exs
mix test
```

If the persistent billing fix touches schemas or migrations, also run the app's
database setup/migration path before the full test suite.

## Notes From Review

- B1 charge-id coercion is correctly covered by
  `test/shopifex/redirect_after_agent_test.exs`.
- B3 `after_exchange/2` is added and tested on first install and refresh.
- B4 was intentionally handled as documentation: callbacks run synchronously, and
  slow work should be moved into the app's own supervised async path.
- S1 LiveSession no longer serializes the full shop struct. It stores `shop_url`
  and reloads server-side.
- M1/M2/Q1/Q2 are documentation or explicit adoption-decision items; no code fix
  is required for them unless StockSorted decides to adopt the library defaults
  for those paths.
