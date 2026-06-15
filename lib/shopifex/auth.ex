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

  To prevent that, `refresh!/1` runs inside a `repo().transaction` and
  takes a `SELECT … FOR UPDATE` row lock on the shop. The lock serializes
  refreshes per-shop without needing a Registry/DynamicSupervisor process
  tree, and is cross-node-safe via Postgres.

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

  Wraps the refresh in a `SELECT FOR UPDATE` transaction so concurrent
  callers don't both invalidate the same refresh_token.

  Returns `{:ok, refreshed_shop}` on success or `{:error, reason}` if Shopify
  rejects the refresh (most commonly `invalid_grant` when the refresh_token
  itself has expired) or the shop has no refresh_token.
  """
  @spec refresh!(struct()) :: {:ok, struct()} | {:error, term()}
  def refresh!(shop) do
    schema = shop_schema()

    repo().transaction(fn ->
      locked_shop =
        repo().one(from(s in schema, where: s.id == ^shop.id, lock: "FOR UPDATE"))

      cond do
        is_nil(locked_shop) ->
          repo().rollback(:shop_not_found)

        # Another caller already refreshed while we were waiting for the row
        # lock. Use whatever they wrote.
        not expires_within_safety_window?(locked_shop) and
            locked_shop.access_token != shop.access_token ->
          locked_shop

        is_nil(Map.get(locked_shop, :refresh_token)) ->
          repo().rollback(:no_refresh_token)

        true ->
          case do_refresh(locked_shop) do
            {:ok, refreshed} -> refreshed
            {:error, reason} -> repo().rollback(reason)
          end
      end
    end)
  end

  defp do_refresh(shop) do
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
        Logger.info("[Shopifex.Auth] Refresh token grant successful for #{url}")
        persist_refreshed_shop(shop, response_body)

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
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    scope_field = Shopifex.Shops.get_scope_field()

    attrs =
      %{
        access_token: body["access_token"],
        token_expires_at: expires_at(now, body["expires_in"]),
        refresh_token: body["refresh_token"],
        refresh_token_expires_at: expires_at(now, body["refresh_token_expires_in"])
      }
      |> Map.put(scope_field, body["scope"] || Shopifex.Shops.get_scope(shop))

    shop
    |> shop_schema().changeset(attrs)
    |> repo().update()
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
