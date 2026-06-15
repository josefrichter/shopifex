defmodule Shopifex.Plug do
  @moduledoc """
  An API for accessing the Shopify session data for the current request.
  """
  @type shop :: %{access_token: String.t(), scope: String.t(), url: String.t()}
  @type shopify_host :: String.t()

  @doc """
  Get current request shop resource for give `conn`.

  Available in all requests which have passed through a `:shopify_*` pipeline.

  ## Examples:

      iex> current_shop(conn)
      %MyApp.Shop{}

  """
  @spec current_shop(conn :: Plug.Conn.t()) :: shop()
  def current_shop(%Plug.Conn{private: %{shopifex: %{shop: shop}}}), do: shop
  def current_shop(_), do: nil

  @doc """
  Get host parameter provided in URL params when Shopify loaded
  your app in the Shopify admin portal.

  Useful when initializing app-bridge instance from SPA application.

  ## Examples:

      iex> current_shopify_host(conn)
      "host from URL search parameter"

  """
  @spec current_shopify_host(conn :: Plug.Conn.t()) :: shopify_host()
  def current_shopify_host(%Plug.Conn{private: %{shopifex: %{shopify_host: shopify_host}}}),
    do: shopify_host

  def current_shopify_host(_), do: nil

  @doc """
  Returns the Shopify App Bridge session token (`id_token`) for the current
  request, read from the `id_token` or `token` query param, or the
  `Authorization: Bearer` header.

  Embedded apps no longer mint their own session token — Shopify supplies a
  fresh short-lived `id_token` on every embedded page load (App Bridge appends
  it to the URL as `id_token`, and sends it as a `Bearer` token on authenticated
  fetches). Verify it with `Shopifex.SessionToken`.

  ## Example
      iex> session_token(conn)
      "header.payload.signature"
  """
  @spec session_token(conn :: Plug.Conn.t()) :: String.t() | nil
  def session_token(%Plug.Conn{params: %{"id_token" => token}}) when is_binary(token), do: token

  def session_token(%Plug.Conn{params: %{"token" => token}}) when is_binary(token), do: token

  def session_token(%Plug.Conn{} = conn) do
    case Plug.Conn.get_req_header(conn, "authorization") do
      ["Bearer " <> token | _] -> token
      _ -> nil
    end
  end

  @doc """
  Build the Shopifex session. Used in various `:shopify_*` pipelines.

  Stores the current shop and Shopify host in `conn.private.shopifex`, where
  `current_shop/1` and `current_shopify_host/1` read them, and applies the
  request locale. No app-issued token is minted — embedded auth is carried by
  Shopify's per-request `id_token` (see `Shopifex.SessionToken`).
  """
  @spec build_session(
          conn :: Plug.Conn.t(),
          shop :: shop(),
          shopify_host :: shopify_host(),
          locale :: Gettext.locale()
        ) :: Plug.Conn.t()
  def build_session(conn, shop, host, locale \\ "en") do
    Gettext.put_locale(locale || "en")

    shopifex_private_data = %{
      shop: shop,
      shopify_host: host
    }

    Plug.Conn.put_private(conn, :shopifex, shopifex_private_data)
  end

  @doc """
  Places given shop into current session, making it accessible later on
  via `Shopifex.Plug.current_shop(conn)`
  """
  @spec put_shop_in_session(conn :: Plug.Conn.t(), shop :: shop()) :: Plug.Conn.t()
  def put_shop_in_session(conn, shop) do
    shopifex_private_data =
      conn.private
      |> Map.get(:shopifex, %{})
      |> Map.put(:shop, shop)

    Plug.Conn.put_private(conn, :shopifex, shopifex_private_data)
  end

  @doc """
  Returns the HMAC the request should carry, computed with the app's current
  secret. Used for verification and for (re)issuing signed values.
  """
  @spec build_hmac(conn :: Plug.Conn.t()) :: String.t()
  def build_hmac(conn), do: build_hmac(conn, primary_secret())

  @doc """
  Like `build_hmac/1`, but computes the HMAC with an explicit `secret`. Used by
  `hmac_matches?/2` to accept either the current or a rotated `:old_secret`.
  """
  @spec build_hmac(conn :: Plug.Conn.t(), secret :: binary()) :: String.t()
  def build_hmac(%Plug.Conn{query_params: %{"hmac" => _}} = conn, secret) do
    # hmac param takes precedence and is present in App load requests.
    conn.query_params
    |> Map.delete("hmac")
    |> query_string_hmac("&", secret)
  end

  def build_hmac(%Plug.Conn{query_params: %{"signature" => _}} = conn, secret) do
    # signature param is present in Shopify App proxy requests https://shopify.dev/apps/online-store/app-proxies
    conn.query_params
    |> Map.delete("signature")
    |> query_string_hmac("", secret)
  end

  def build_hmac(%Plug.Conn{method: "GET"} = conn, secret) do
    conn.query_params
    |> query_string_hmac("", secret)
  end

  def build_hmac(%Plug.Conn{method: "POST"} = conn, secret) do
    # Webhook body HMACs are Base64 and MUST be compared case-sensitively — do
    # not downcase. Shopify (JS/Ruby) compares the raw Base64 digest.
    :crypto.mac(:hmac, :sha256, secret, conn.assigns[:raw_body])
    |> Base.encode64()
  end

  @doc """
  Constant-time check that `received` matches the request's expected HMAC under
  the app's current secret &mdash; or, when `config :shopifex, :old_secret` is
  set, the previous one. Trying both lets you rotate the app secret without
  dropping in-flight webhooks / signed requests still carrying the old signature.
  Returns `false` for a non-binary `received` (e.g. a missing header).
  """
  @spec hmac_matches?(conn :: Plug.Conn.t(), received :: term()) :: boolean()
  def hmac_matches?(%Plug.Conn{} = conn, received) when is_binary(received) do
    Enum.any?(secrets(), fn secret ->
      Plug.Crypto.secure_compare(build_hmac(conn, secret), received)
    end)
  end

  def hmac_matches?(_conn, _received), do: false

  @spec get_hmac(conn :: Plug.Conn.t()) :: String.t() | nil
  def get_hmac(%Plug.Conn{params: %{"hmac" => hmac}}), do: String.downcase(hmac)

  def get_hmac(%Plug.Conn{params: %{"signature" => signature}}), do: String.downcase(signature)

  def get_hmac(%Plug.Conn{} = conn) do
    # The `x-shopify-hmac-sha256` webhook header is Base64 — return it verbatim
    # for a case-sensitive `secure_compare/2` against the Base64 body digest.
    with [hmac_header] <- Plug.Conn.get_req_header(conn, "x-shopify-hmac-sha256") do
      hmac_header
    else
      _ -> nil
    end
  end

  @doc false
  # Public only so `Shopifex.Test.sign_query_hmac/2` signs exactly as we verify
  # (incl. the `ids` bulk-action quirk). Not part of the public API.
  def query_string_hmac(query_params, joiner, secret) do
    query_string =
      query_params
      # Shopify signs query/app-proxy params in alphabetical order; sort
      # explicitly rather than relying on map iteration order.
      |> Enum.sort()
      |> Enum.map_join(joiner, fn
        {"ids", value} ->
          # This absolutely ridiculous solution: https://community.shopify.com/c/Shopify-Apps/Hmac-Verification-for-Bulk-Actions/m-p/590611#M18504
          ids =
            Enum.map(value, fn id ->
              "\"#{id}\""
            end)
            |> Enum.join(", ")

          "ids=[#{ids}]"

        {key, value} ->
          "#{key}=#{value}"
      end)

    :crypto.mac(:hmac, :sha256, secret, query_string)
    |> Base.encode16(case: :lower)
  end

  defp primary_secret, do: Application.fetch_env!(:shopifex, :secret)

  # The current secret first, then the rotated-out `:old_secret` if configured,
  # so HMAC verification accepts signatures from before a secret rotation.
  defp secrets do
    case Application.get_env(:shopifex, :old_secret) do
      old when is_binary(old) and old != "" -> [primary_secret(), old]
      _ -> [primary_secret()]
    end
  end
end
