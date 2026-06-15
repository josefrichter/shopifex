defmodule Shopifex.Plug.ManagedInstall do
  @moduledoc """
  Handles Shopify's managed app installation flow via token exchange, and keeps
  the embedded session's offline access token fresh.

  With managed installation (the default for new Shopify apps), Shopify sends an
  `id_token` JWT on every page load instead of going through the traditional
  OAuth authorization code exchange. This plug:

  1. Verifies the `id_token` with `Shopifex.SessionToken` (strict HS256).
  2. If the shop doesn't exist, exchanges the `id_token` for an **expiring**
     offline access token (RFC 8693) and persists the full token lifecycle
     (`access_token`, `token_expires_at`, `refresh_token`,
     `refresh_token_expires_at`).
  3. If the shop exists but its token is older than the staleness window
     (50 min, comfortably inside the 1h TTL), it re-exchanges to refresh.
  4. Otherwise it builds the session from the stored shop directly.

  It also handles the cookie-less `auth_token` redirect bridge (a signed
  `Phoenix.Token`) used to carry auth across an auth-controller redirect when
  third-party cookies are blocked in the Shopify admin iframe.

  If no recognised token is present, this plug is a no-op — the request falls
  through to the traditional OAuth flow.

  ## Usage

  Add this plug to your router pipeline **before** `Shopifex.Plug.ShopifySession`:

      pipeline :managed_install do
        plug Shopifex.Plug.ManagedInstall
      end

      scope "/auth" do
        pipe_through [:shopifex_browser, :managed_install, :shopify_session]
        get "/", MyAppWeb.AuthController, :auth
      end

  ## Configuration

      config :shopifex,
        api_key: "your_api_key",
        secret: "your_api_secret"

  Install-time side effects (profile fetch, analytics, snapshots) are
  app-specific and belong in your `AuthController` / shop-creation path, not in
  this plug.
  """

  require Logger

  # How old the shop's access_token may get before we re-exchange it on the next
  # id_token-bearing request. Shopify-issued expiring offline access tokens have
  # a 1-hour TTL; re-exchanging at 50 minutes keeps the token live on landing.
  # Background paths (schedulers, webhooks) refresh via the refresh_token in
  # `Shopifex.Auth` instead — they don't depend on this plug.
  @refresh_after_seconds 50 * 60

  def init(opts), do: opts

  def call(%{params: %{"id_token" => id_token, "shop" => shop_url}} = conn, _opts) do
    case Shopifex.SessionToken.verify(id_token, shop_url) do
      {:ok, _claims} ->
        load_or_exchange_shop(conn, id_token, shop_url)

      # Shopify session tokens live ~60s, so a stale embedded load (mobile
      # bfcache / back-forward, clock skew) routinely yields :expired. The
      # request still recovers — App Bridge supplies a fresh token on reload —
      # so this is expected, not an error. Log at :info; genuine anomalies (bad
      # signature/audience) stay :warning.
      {:error, :expired} ->
        Logger.info(
          "[Shopifex.ManagedInstall] Expired session token for #{shop_url}; falling through"
        )

        conn

      {:error, reason} ->
        Logger.warning(
          "[Shopifex.ManagedInstall] Invalid session token for #{shop_url}: #{inspect(reason)}"
        )

        conn
    end
  end

  # Redirect bridge from the auth controller — `auth_token` is a signed
  # `Phoenix.Token` that survives the redirect without cookies (third-party
  # cookie blocking in the iframe).
  def call(%{params: %{"auth_token" => auth_token, "shop" => shop_url}} = conn, _opts) do
    with {:ok, shop_id} <- Phoenix.Token.verify(conn, "shop_auth", auth_token, max_age: 60),
         shop when not is_nil(shop) <- Shopifex.Shops.get_shop_by_url(shop_url),
         true <- to_string(Map.get(shop, :id)) == to_string(shop_id) do
      host = conn.params["host"]
      locale = conn.params["locale"] || "en"
      Shopifex.Plug.build_session(conn, shop, host, locale)
    else
      _ -> conn
    end
  end

  def call(conn, _opts), do: conn

  defp load_or_exchange_shop(conn, id_token, shop_url) do
    case Shopifex.Shops.get_shop_by_url(shop_url) do
      nil ->
        Logger.info("[Shopifex.ManagedInstall] Shop #{shop_url} not found, exchanging id_token")

        exchange_token_and_upsert_shop(conn, id_token, shop_url, _new? = true, _fallback = nil)

      shop ->
        if token_stale?(shop) do
          Logger.info("[Shopifex.ManagedInstall] Refreshing access_token for #{shop_url}")

          exchange_token_and_upsert_shop(
            conn,
            id_token,
            shop_url,
            _new? = false,
            _fallback = shop
          )
        else
          build_session_from_shop(conn, shop)
        end
    end
  end

  defp token_stale?(shop) do
    case Map.get(shop, :updated_at) do
      %NaiveDateTime{} = updated_at ->
        NaiveDateTime.diff(NaiveDateTime.utc_now(), updated_at, :second) >= @refresh_after_seconds

      %DateTime{} = updated_at ->
        DateTime.diff(DateTime.utc_now(), updated_at, :second) >= @refresh_after_seconds

      _ ->
        true
    end
  end

  defp exchange_token_and_upsert_shop(conn, id_token, shop_url, new?, fallback) do
    api_key = Application.fetch_env!(:shopifex, :api_key)
    api_secret = Application.fetch_env!(:shopifex, :secret)

    # `expiring=1` is required for public apps created on or after 2026-04-01:
    # https://shopify.dev/changelog/expiring-offline-access-tokens-required-for-public-apps-april-1-2026
    #
    # With `expiring=1` the response adds `expires_in` (typically 3600) and
    # `refresh_token` (+ `refresh_token_expires_in`, typically 90 days). We
    # persist all four so background paths can refresh without an id_token.
    body =
      URI.encode_query(%{
        "client_id" => api_key,
        "client_secret" => api_secret,
        "grant_type" => "urn:ietf:params:oauth:grant-type:token-exchange",
        "subject_token" => id_token,
        "subject_token_type" => "urn:ietf:params:oauth:token-type:id_token",
        "requested_token_type" => "urn:shopify:params:oauth:token-type:offline-access-token",
        "expiring" => "1"
      })

    req_opts =
      [
        body: body,
        headers: [{"content-type", "application/x-www-form-urlencoded"}]
      ] ++ Application.get_env(:shopifex, :req_options, [])

    case Req.post("https://#{shop_url}/admin/oauth/access_token", req_opts) do
      {:ok, %{status: 200, body: response_body}} when is_map(response_body) ->
        Logger.info("[Shopifex.ManagedInstall] Token exchange successful for #{shop_url}")

        shop = upsert_shop(shop_url, build_shop_attrs(shop_url, response_body))

        # Webhook subscriptions are configured on first install only — refreshes
        # shouldn't re-subscribe.
        if new?, do: Shopifex.Shops.configure_webhooks(shop)

        build_session_from_shop(conn, shop)

      {:ok, %{status: status, body: body}} ->
        Logger.error(
          "[Shopifex.ManagedInstall] Token exchange failed for #{shop_url}: #{status} - #{inspect(body)}"
        )

        fallback_session(conn, fallback)

      {:error, error} ->
        Logger.error(
          "[Shopifex.ManagedInstall] Token exchange request failed for #{shop_url}: #{inspect(error)}"
        )

        fallback_session(conn, fallback)
    end
  end

  # Tolerates responses without `expires_in` / `refresh_token` (non-expiring
  # tokens, used by older installs or test fixtures) — the expiry timestamps
  # stay nil and `Shopifex.Auth.ensure_fresh_token/1` treats the token as
  # non-expiring (background refresh not possible; reactive-401 still works).
  defp build_shop_attrs(shop_url, body) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    scope_field = Shopifex.Shops.get_scope_field()

    %{
      url: shop_url,
      access_token: body["access_token"],
      token_expires_at: expires_at(now, body["expires_in"]),
      refresh_token: body["refresh_token"],
      refresh_token_expires_at: expires_at(now, body["refresh_token_expires_in"])
    }
    |> Map.put(scope_field, body["scope"])
  end

  defp upsert_shop(shop_url, attrs) do
    case Shopifex.Shops.get_shop_by_url(shop_url) do
      nil -> Shopifex.Shops.create_shop(attrs)
      shop -> Shopifex.Shops.update_shop(shop, attrs)
    end
  end

  defp build_session_from_shop(conn, shop) do
    host = conn.params["host"]
    locale = conn.params["locale"] || "en"
    Shopifex.Plug.build_session(conn, shop, host, locale)
  end

  # On exchange failure during a refresh, fall back to the existing shop's
  # session so the merchant can still load pages that don't hit Shopify APIs.
  # The stale token will 401 on actual API calls — but the next page load
  # retries the exchange.
  defp fallback_session(conn, nil), do: conn
  defp fallback_session(conn, shop), do: build_session_from_shop(conn, shop)

  defp expires_at(_now, nil), do: nil
  defp expires_at(now, seconds) when is_integer(seconds), do: DateTime.add(now, seconds, :second)
end
