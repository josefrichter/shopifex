defmodule Shopifex.Plug.ManagedInstall do
  @moduledoc """
  Handles Shopify's managed app installation flow via token exchange.

  With managed installation (the default for new Shopify apps), Shopify sends
  an `id_token` JWT on every page load instead of going through the traditional
  OAuth authorization code exchange. This plug intercepts that token, exchanges
  it for an offline access token via Shopify's token exchange API (RFC 8693),
  and creates the shop record so the standard `ShopifySession` plug can proceed.

  ## Usage

  Add this plug to your router pipeline **before** `Shopifex.Plug.ShopifySession`:

      pipeline :ensure_shop do
        plug Shopifex.Plug.ManagedInstall
      end

      scope "/auth" do
        pipe_through [:shopifex_browser, :ensure_shop, :shopify_session]
        get "/", MyAppWeb.AuthController, :auth
      end

  ## How it works

  1. Checks for `id_token` and `shop` in request params
  2. If the shop already exists in the database, builds a session directly
     from the validated request (HMAC-authenticated by Shopify)
  3. If the shop doesn't exist, exchanges the `id_token` for an offline
     access token using Shopify's token exchange endpoint
  4. Creates the shop record via `Shopifex.Shops.create_shop/1`
  5. Builds a Shopifex session so downstream plugs work normally

  If no `id_token` is present, this plug is a no-op — the request falls
  through to the traditional OAuth flow.

  ## Configuration

  Uses the existing Shopifex configuration:

      config :shopifex,
        api_key: "your_api_key",
        secret: "your_api_secret"
  """

  require Logger

  def init(opts), do: opts

  def call(%{params: %{"id_token" => id_token, "shop" => shop_url}} = conn, _opts) do
    host = conn.params["host"]
    locale = conn.params["locale"] || "en"

    case Shopifex.Shops.get_shop_by_url(shop_url) do
      nil ->
        Logger.info("[Shopifex.ManagedInstall] Shop #{shop_url} not found, exchanging id_token")
        exchange_token_and_create_shop(conn, id_token, shop_url, host, locale)

      shop ->
        # Shop exists — build session directly.
        # The id_token is a Shopify-signed JWT (HS256 with API secret), which
        # Guardian can validate since it allows both HS256 and HS512.
        Shopifex.Plug.build_session(conn, shop, host, locale)
    end
  end

  def call(conn, _opts), do: conn

  defp exchange_token_and_create_shop(conn, id_token, shop_url, host, locale) do
    api_key = Application.fetch_env!(:shopifex, :api_key)
    api_secret = Application.fetch_env!(:shopifex, :secret)

    url = "https://#{shop_url}/admin/oauth/access_token"

    case Req.post(url,
           form: [
             client_id: api_key,
             client_secret: api_secret,
             grant_type: "urn:ietf:params:oauth:grant-type:token-exchange",
             subject_token: id_token,
             subject_token_type: "urn:ietf:params:oauth:token-type:id_token",
             requested_token_type: "urn:shopify:params:oauth:token-type:offline-access-token"
           ]
         ) do
      {:ok, %{status: 200, body: %{"access_token" => access_token, "scope" => scope}}} ->
        Logger.info("[Shopifex.ManagedInstall] Token exchange successful for #{shop_url}")

        scope_field = Shopifex.Shops.get_scope_field()

        shop_params =
          %{url: shop_url, access_token: access_token}
          |> Map.put(scope_field, scope)

        shop = Shopifex.Shops.create_shop(shop_params)
        Shopifex.Shops.configure_webhooks(shop)

        Shopifex.Plug.build_session(conn, shop, host, locale)

      {:ok, %{status: status, body: body}} ->
        Logger.error(
          "[Shopifex.ManagedInstall] Token exchange failed for #{shop_url}: #{status} - #{inspect(body)}"
        )

        conn

      {:error, error} ->
        Logger.error(
          "[Shopifex.ManagedInstall] Token exchange request failed for #{shop_url}: #{inspect(error)}"
        )

        conn
    end
  end
end
