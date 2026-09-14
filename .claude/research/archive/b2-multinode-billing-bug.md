# B2 follow-up: multi-node billing redirect is a real bug, not just a limitation

> **Resolution (2026-06-16) — fixed on `modern-shopifex`.** Implemented Suggested
> fix **#1 (ship a persistent default)** and **#2 (fail loud)** together, plus the
> #3 docs:
>
> - **`Shopifex.RedirectAfter.Ecto`** (`lib/shopifex/redirect_after/ecto.ex`) — a
>   shipped, DB-backed implementation of the `Shopifex.RedirectAfterAgent`
>   behaviour, keyed by `charge_id` in a `shopifex_charge_redirects` table
>   (`charge_id` bigint PK, `redirect_after` text, `inserted_at`). `set/2` upserts;
>   `get/1` is one-shot (single delete-and-return statement); binary charge ids are
>   coerced to the integer key, consistent with the B1 fix.
> - **`mix shopifex.install`** now generates `config :shopifex,
>   :redirect_after_agent, Shopifex.RedirectAfter.Ecto` and prints the backing
>   migration, so new apps are multi-node-safe out of the box. (The library's
>   zero-config code default stays the in-memory agent so existing apps don't crash
>   on a missing table — but it now fails loud, see below.)
> - **`complete_payment/2` fails loud:** a redirect-cache miss now logs an
>   actionable `Logger.error` (naming the node-local-cache-on-multi-node cause and
>   pointing at the Ecto store) instead of returning a silent `{:error,
>   :forbidden}`. Dropped grants are observable.
> - **Tests:** `test/shopifex/redirect_after/ecto_test.exs` (round-trip, one-shot,
>   string/int coercion, **cross-process** recovery, upsert) and
>   `test/shopifex_web/controllers/payment_controller_complete_test.exs` (loud-fail
>   on miss; full `select_plan → complete_payment` creates the `Grant` with the
>   Ecto store). Full suite green (145 tests).
> - **Stock Sorted:** configured to use `Shopifex.RedirectAfter.Ecto` (see
>   `StockSorted/docs/shopifex-3-migration.md`, Step 6).
>
> The rest of this document is the original escalation, kept for context.

---

This is a re-escalation of **B2** from `docs/shopifex-3-pushback.md`. The
implementation audit (`docs/shopifex-3-implementation-audit.md`) resolved B2 as
**Option B — "accepted limitation, documented only."** New information from the
first real consumer (Stock Sorted) shows that's not sufficient: the default
billing path is **actively broken** for that app's production topology.

## What's wrong

`Shopifex.RedirectAfterAgent` (`lib/shopifex/redirect_after_agent.ex`) is an
in-memory `Agent` with a node-local `name: __MODULE__` registration.

The billing flow spans two separate HTTP requests that can hit different nodes:

1. `PaymentController.select_plan/2` (or an app's custom charge action) calls
   `redirect_after_agent.set(charge_id, redirect_after)` — writes to the Agent on
   **node A**.
2. Shopify redirects the merchant's browser to `/payment/complete` as a fresh
   top-level navigation. Behind a load balancer this is routed to **either node**.
3. `PaymentController.complete_payment/2` calls
   `redirect_after_agent.get(charge_id)`. If it ran on **node B**, that Agent has
   no entry → `get/1` returns `nil` → the `with` falls through to
   `{:error, :forbidden}` → **the `Grant` is never created.**

Net effect: **the merchant is charged by Shopify but the app never records the
grant / unlocks the plan.** It is intermittent (≈ `1/N` success on N nodes),
invisible in single-node dev, and load-balancer-dependent.

## Why "documented limitation" isn't enough

The first consumer, **Stock Sorted**, runs **2 machines on Fly.io for
redundancy** (confirmed by the app owner). Shopify's `/payment/complete`
redirect is a fresh navigation with no Fly session affinity, so it lands on the
"wrong" node roughly half the time. That means the library's *default* billing
path — the one a new app gets out of the box — drops grants ~50% of the time on
any standard redundant deploy. A library default that fails on a 2-machine setup
is a bug, not an edge case.

Note this is **independent of the B1 fix** (B1 is correctly fixed; the string
charge id now round-trips). B2 is a separate, architectural problem.

## Reproduction

- Deploy any Shopifex app on ≥2 nodes with no sticky/affinity routing (Fly.io
  default, multiple `kubernetes` pods, etc.).
- Start a charge so `select_plan` runs `set/2` on node A.
- Force/await Shopify's `/payment/complete` redirect to node B (or simulate:
  call `set/2` against one Agent instance and `get/1` against a second instance
  with separate state).
- Observe `complete_payment/2` returns `{:error, :forbidden}` and no `Grant` row
  is created, despite a successful Shopify charge.

## Suggested fix (library side)

The config seam already exists —
`Application.get_env(:shopifex, :redirect_after_agent, Shopifex.RedirectAfterAgent)`
— so the behaviour is swappable. The gap is that the **default** is unsafe and
there is no persistent implementation shipped.

Pick one, in rough order of preference:

1. **Ship a persistent default** keyed by charge id (a small `charges` table:
   `charge_id` PK, `redirect_after`, `inserted_at`; `set` inserts, `get`
   deletes-and-returns). Add the migration to the generator/installer so the
   default is multi-node-safe out of the box. This makes the macro billing path
   correct for everyone.
2. **Keep the in-memory default but fail loud:** if the app is configured for
   multi-node (or always), `complete_payment/2` should distinguish "charge id
   unknown to this node" from a genuine forbidden request, and log/raise an
   actionable error instead of a silent `:forbidden`. At minimum emit a telemetry
   event / `Logger.error` on the miss so dropped grants are observable rather than
   silent.
3. **At the very least**, make the multi-node caveat impossible to miss in the
   billing setup docs and the `payment_routes` macro docs — not only in the
   `RedirectAfterAgent` moduledoc — and provide a copy-pasteable persistent
   implementation in the docs (the audit's "Option A" sketch, fleshed out and
   tested).

## How to verify the fix

- Two-instance integration test (or two Agent processes with separate state):
  `set/2` on instance 1, `get/1` on instance 2 must still recover the redirect —
  and a recurring-plan `select_plan → complete_payment` flow must create the
  `Grant`.
- Confirm the shipped persistent default round-trips the **string** charge id
  that `PaymentController` produces from the Shopify GID (keep it consistent with
  the B1 coercion).

## Consumer-side note (Stock Sorted)

Stock Sorted already depends on the in-memory agent today (its custom
`issue_charge_for_plan/2` calls `set/2`, and `/payment/complete` uses the bundled
`complete_payment/2` which calls `get/1`). So this app can self-mitigate by
configuring its own persistent `:redirect_after_agent` regardless of what the
library does — but the library default should still be fixed so the next app
doesn't inherit a billing path that silently drops grants on a redundant deploy.
