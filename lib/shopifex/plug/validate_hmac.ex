defmodule Shopifex.Plug.ValidateHmac do
  @moduledoc """
  Ensures the current request carries a valid Shopify query / app-proxy HMAC
  signature and, when present, a fresh `timestamp`.

  Security properties:

    * HMACs are compared in constant time with `Plug.Crypto.secure_compare/2`.
    * Computed HMAC values are never logged.
    * When the request includes a `timestamp` parameter (Shopify always sends one
      for admin-load and app-proxy flows) it must be within
      `config :shopifex, :hmac_timestamp_tolerance_seconds` (default `90`) of now,
      closing the replay window. (A request that carries no `timestamp` skips the
      freshness check, unless `:require_timestamp` is set — see below.)

  ## Requiring a timestamp

  Some signed flows (e.g. bulk-action links) legitimately omit `timestamp`, so by
  default a missing timestamp is allowed. App-proxy requests, however, *always*
  carry one, and without it the signed URL is replayable forever. Pass
  `require_timestamp: true` to reject any request that lacks a `timestamp`:

      plug Shopifex.Plug.ValidateHmac, require_timestamp: true

  The `:shopify_proxy` pipeline sets this by default.

  ## Per-pipeline tolerance

  The `config :shopifex, :hmac_timestamp_tolerance_seconds` default is global. App
  proxy / storefront requests can legitimately lag past 90s, but widening the
  global value also widens the admin-load replay window. Pass a `plug` option to
  relax the tolerance for one pipeline only, without touching the global default:

      plug Shopifex.Plug.ValidateHmac, timestamp_tolerance_seconds: 600

  This plug **only verifies the signature** — it does not load the shop into
  `conn.assigns`. The `:shopify_proxy` pipeline pairs it with
  `Shopifex.Plug.LoadProxyShop` so app-proxy consumers get `current_shop/1`.
  """
  import Plug.Conn
  require Logger

  @default_tolerance_seconds 90

  def init(options), do: options

  def call(conn, options) do
    with :ok <- validate_timestamp(conn, options),
         :ok <- validate_signature(conn) do
      conn
    else
      {:error, reason} ->
        # Log the failure category only — never the expected/received HMAC.
        Logger.info("Rejecting request with invalid HMAC (#{reason})")

        conn
        |> send_resp(401, "invalid hmac signature")
        |> halt()
    end
  end

  defp validate_signature(conn) do
    if Shopifex.Plug.hmac_matches?(conn, Shopifex.Plug.get_hmac(conn)) do
      :ok
    else
      {:error, "signature mismatch"}
    end
  end

  # Shopify includes a Unix-second `timestamp` on signed query/app-proxy
  # requests. Reject stale or unparseable timestamps; skip the check when none is
  # present (e.g. bulk-action links that omit it).
  #
  # Read from `query_params` — the values the HMAC actually covers — not the
  # merged `params`, so an unsigned POST body `timestamp` can't shadow the signed
  # query value and defeat the replay window.
  defp validate_timestamp(conn, options) do
    case conn.query_params["timestamp"] do
      nil ->
        if Keyword.get(options, :require_timestamp, false) do
          {:error, "missing timestamp"}
        else
          :ok
        end

      timestamp ->
        with {seconds, _} <- Integer.parse(to_string(timestamp)),
             true <- abs(System.system_time(:second) - seconds) <= tolerance_seconds(options) do
          :ok
        else
          _ -> {:error, "stale timestamp"}
        end
    end
  end

  # A per-plug `:timestamp_tolerance_seconds` option (set in a pipeline) overrides
  # the global config, so one pipeline (e.g. app proxy) can allow more lag without
  # widening the admin-load replay window.
  defp tolerance_seconds(options) do
    Keyword.get(options, :timestamp_tolerance_seconds) ||
      Application.get_env(
        :shopifex,
        :hmac_timestamp_tolerance_seconds,
        @default_tolerance_seconds
      )
  end
end
