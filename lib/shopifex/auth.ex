defmodule Shopifex.Auth do
  @moduledoc """
  Shopify access-token lifecycle for background / non-embedded paths.

  ## Why this module exists

  Shopify expiring offline access tokens have a 1-hour TTL. The embedded
  flow refreshes them via `Shopifex.Plug.ManagedInstall` (id_token →
  access_token exchange on every page load past a threshold). But
  background paths — schedulers, webhook handlers — don't have an
  id_token. They refresh independently using the stored `refresh_token`
  (90-day TTL, one-time use).

  This module is that refresh path. It is the background-equivalent of the
  embedded re-exchange, and `Shopifex.API.graphql/3` calls into it both
  proactively (before a request) and reactively (after a 401).

  ## Shopify's recommended strategy

  > "Proactively refresh tokens a few minutes before they expire, and
  > when you receive a 401 response."
  > -- https://shopify.dev/changelog/offline-access-tokens-now-support-expiry-and-refresh

  - **Proactive:** `ensure_fresh_token/1` checks `token_expires_at` and
    refreshes if it's within the safety window (5 minutes).
  - **Reactive:** `Shopifex.API.graphql/3` catches 401 responses and calls
    `refresh!/1` once before retrying.

  ## Concurrency

  Refresh tokens are one-time use — using a refresh_token invalidates it
  immediately and the response includes a fresh refresh_token to use next
  time. If two callers refresh in parallel, the second one will get
  `invalid_grant` from Shopify and clobber the new refresh_token.

  To prevent that, `refresh!/1` acquires a cross-node lease in the dedicated
  `shopifex_token_refresh_leases` table. The Shopify request runs without a
  transaction or lock on the consumer's shop row. After Shopify responds, a
  short transaction locks and re-checks the shop before persisting, so a
  concurrent managed-install exchange is never overwritten.

  ## Caveats

  - **Legacy installs have `refresh_token = nil`** — they were installed
    with the non-expiring offline token flow. For these shops,
    `ensure_fresh_token/1` is a no-op; the only way to populate the new
    fields is for a merchant to open the embedded app (which hits
    `Shopifex.Plug.ManagedInstall` and re-exchanges via id_token).

  - **If the refresh_token itself expires** (after 90 days of no refresh),
    Shopify returns 400 with `invalid_grant`. `refresh!/1` returns
    `{:error, ...}`. The next embedded page load fixes it via fresh token
    exchange.

  ## Configuration

  Uses the existing Shopifex configuration:

      config :shopifex,
        api_key: "your_api_key",
        secret: "your_api_secret"

  Tests can inject Req options (e.g. a `Req.Test` plug) via:

      config :shopifex, :req_options, plug: {Req.Test, Shopifex.Auth}

  Refresh coordination can be tuned when necessary:

      config :shopifex,
        token_refresh_lease_ttl_ms: 120_000,
        token_refresh_wait_timeout_ms: 15_000,
        token_refresh_poll_interval_ms: 100

  ## References

  - About offline access tokens:
    https://shopify.dev/docs/apps/build/authentication-authorization/access-tokens/offline-access-tokens
  - Expiry & refresh changelog:
    https://shopify.dev/changelog/offline-access-tokens-now-support-expiry-and-refresh
  - April 2026 requirement:
    https://shopify.dev/changelog/expiring-offline-access-tokens-required-for-public-apps-april-1-2026
  """

  require Logger
  import Ecto.Query

  alias Shopifex.TokenRefreshLease

  # Refresh proactively when the token is within this window of expiring.
  # Tuned to be longer than a typical Shopify API call so we don't race the
  # expiry while a request is in flight.
  @safety_window_seconds 5 * 60

  defp repo, do: Shopifex.Shops.repo()
  defp shop_schema, do: Shopifex.Shops.shop_schema()

  @doc """
  Returns a shop whose `access_token` is guaranteed fresh enough to make at
  least one Shopify API call against.

  Strategy:
  - Token expiry is unknown (`nil`) → return the shop as-is. The caller is
    responsible for invoking `refresh!/1` reactively on 401. This covers
    legacy shops that pre-date the expiry columns.
  - Token expires within the safety window → refresh and return the updated
    shop.
  - Otherwise → return the shop as-is.
  """
  @spec ensure_fresh_token(struct()) :: struct()
  def ensure_fresh_token(shop) do
    cond do
      is_nil(Map.get(shop, :token_expires_at)) ->
        shop

      expires_within_safety_window?(shop) ->
        case refresh!(shop) do
          {:ok, refreshed} ->
            refreshed

          # On refresh failure, return the (now-stale) shop. The caller will
          # likely 401; Shopifex.API's reactive path handles that by retrying
          # the refresh, and if that fails too the error surfaces. We don't
          # want to crash background workers on transient refresh issues.
          {:error, _reason} ->
            shop
        end

      true ->
        shop
    end
  end

  @doc """
  Force-refresh the shop's access_token by exchanging its stored
  `refresh_token` for a new access + refresh token pair.

  Uses a cross-node database lease so concurrent callers don't both invalidate
  the same refresh token. The outbound Shopify request does not hold a lock on
  the shop row; only the final compare-and-persist step uses a short row lock.

  Returns `{:ok, refreshed_shop}` on success or `{:error, reason}` if Shopify
  rejects the refresh (most commonly `invalid_grant` when the refresh_token
  itself has expired) or the shop has no refresh_token.

  A caller that cannot acquire or observe completion of the lease before the
  configured wait deadline receives `{:error, :refresh_in_progress}`.
  """
  @spec refresh!(struct()) :: {:ok, struct()} | {:error, term()}
  def refresh!(shop) do
    deadline = System.monotonic_time(:millisecond) + TokenRefreshLease.wait_timeout_ms()
    refresh_with_lease(shop, deadline)
  end

  defp refresh_with_lease(original_shop, deadline) do
    case reload_shop(original_shop) do
      nil ->
        {:error, :shop_not_found}

      current_shop ->
        cond do
          already_refreshed?(current_shop, original_shop) ->
            {:ok, current_shop}

          is_nil(Map.get(current_shop, :refresh_token)) ->
            {:error, :no_refresh_token}

          true ->
            acquire_or_wait(current_shop, original_shop, deadline)
        end
    end
  end

  defp acquire_or_wait(current_shop, original_shop, deadline) do
    shop_url = Shopifex.Shops.get_url(current_shop)

    case TokenRefreshLease.acquire(shop_url) do
      {:ok, owner} ->
        try do
          refresh_as_owner(original_shop)
        after
          TokenRefreshLease.release(shop_url, owner)
        end

      :busy ->
        wait_for_refresh(original_shop, deadline)
    end
  end

  defp wait_for_refresh(original_shop, deadline) do
    remaining_ms = deadline - System.monotonic_time(:millisecond)

    if remaining_ms <= 0 do
      {:error, :refresh_in_progress}
    else
      poll_ms = min(TokenRefreshLease.poll_interval_ms(), remaining_ms)

      receive do
      after
        poll_ms -> refresh_with_lease(original_shop, deadline)
      end
    end
  end

  defp refresh_as_owner(original_shop) do
    case reload_shop(original_shop) do
      nil ->
        {:error, :shop_not_found}

      current_shop ->
        cond do
          already_refreshed?(current_shop, original_shop) ->
            {:ok, current_shop}

          is_nil(Map.get(current_shop, :refresh_token)) ->
            {:error, :no_refresh_token}

          true ->
            with {:ok, response_body} <- request_refresh(current_shop),
                 {:ok, refreshed_shop} <- persist_refreshed_shop(current_shop, response_body) do
              Logger.info(
                "[Shopifex.Auth] Refresh token grant successful for #{Shopifex.Shops.get_url(refreshed_shop)}"
              )

              {:ok, refreshed_shop}
            end
        end
    end
  end

  defp request_refresh(shop) do
    api_key = Application.fetch_env!(:shopifex, :api_key)
    api_secret = Application.fetch_env!(:shopifex, :secret)
    url = Shopifex.Shops.get_url(shop)

    body =
      URI.encode_query(%{
        "client_id" => api_key,
        "client_secret" => api_secret,
        "grant_type" => "refresh_token",
        "refresh_token" => Map.get(shop, :refresh_token)
      })

    req_opts =
      [
        body: body,
        headers: [{"content-type", "application/x-www-form-urlencoded"}]
      ] ++ Application.get_env(:shopifex, :req_options, [])

    case Req.post("https://#{url}/admin/oauth/access_token", req_opts) do
      {:ok, %{status: 200, body: response_body}} when is_map(response_body) ->
        {:ok, response_body}

      {:ok, %{status: status, body: response_body}} ->
        Logger.error(
          "[Shopifex.Auth] Refresh token grant failed for #{url}: #{status} - #{inspect(response_body)}"
        )

        {:error, {:refresh_failed, status}}

      {:error, error} ->
        Logger.error("[Shopifex.Auth] Refresh token request failed for #{url}: #{inspect(error)}")
        {:error, {:refresh_request_failed, error}}
    end
  end

  defp persist_refreshed_shop(shop, body) do
    schema = shop_schema()

    repo().transaction(fn ->
      locked_shop =
        repo().one(from(s in schema, where: s.id == ^shop.id, lock: "FOR UPDATE"))

      cond do
        is_nil(locked_shop) ->
          repo().rollback(:shop_not_found)

        token_state_changed?(locked_shop, shop) ->
          locked_shop

        true ->
          now = DateTime.utc_now() |> DateTime.truncate(:second)
          scope_field = Shopifex.Shops.get_scope_field()

          attrs =
            %{
              access_token: body["access_token"],
              token_expires_at: expires_at(now, body["expires_in"]),
              refresh_token: body["refresh_token"],
              refresh_token_expires_at: expires_at(now, body["refresh_token_expires_in"])
            }
            |> Map.put(scope_field, body["scope"] || Shopifex.Shops.get_scope(locked_shop))

          case locked_shop |> schema.changeset(attrs) |> repo().update() do
            {:ok, refreshed_shop} -> refreshed_shop
            {:error, changeset} -> repo().rollback(changeset)
          end
      end
    end)
  end

  defp reload_shop(shop), do: repo().get(shop_schema(), Map.fetch!(shop, :id))

  defp already_refreshed?(current_shop, original_shop) do
    not expires_within_safety_window?(current_shop) and
      token_state_changed?(current_shop, original_shop)
  end

  defp token_state_changed?(current_shop, refreshed_snapshot) do
    Enum.any?(
      [:access_token, :token_expires_at, :refresh_token, :refresh_token_expires_at],
      &(Map.get(current_shop, &1) != Map.get(refreshed_snapshot, &1))
    )
  end

  defp expires_within_safety_window?(shop) do
    case Map.get(shop, :token_expires_at) do
      nil ->
        false

      %DateTime{} = expires_at ->
        DateTime.diff(expires_at, DateTime.utc_now(), :second) <= @safety_window_seconds
    end
  end

  defp expires_at(_now, nil), do: nil

  defp expires_at(now, seconds) when is_integer(seconds) do
    DateTime.add(now, seconds, :second)
  end
end
