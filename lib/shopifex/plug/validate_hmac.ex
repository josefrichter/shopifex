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
      closing the replay window. Configure a larger tolerance only if you have a
      specific reason to.
  """
  import Plug.Conn
  require Logger

  @default_tolerance_seconds 90

  def init(options), do: options

  def call(conn, _) do
    with :ok <- validate_timestamp(conn),
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
  defp validate_timestamp(conn) do
    case conn.query_params["timestamp"] do
      nil ->
        :ok

      timestamp ->
        with {seconds, _} <- Integer.parse(to_string(timestamp)),
             true <- abs(System.system_time(:second) - seconds) <= tolerance_seconds() do
          :ok
        else
          _ -> {:error, "stale timestamp"}
        end
    end
  end

  defp tolerance_seconds do
    Application.get_env(:shopifex, :hmac_timestamp_tolerance_seconds, @default_tolerance_seconds)
  end
end
