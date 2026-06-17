defmodule ShopifexWeb.AuthController do
  @moduledoc """
  You can use this module inside of another controller to handle initial iFrame load and shop installation

  Example:

  ```elixir
  defmodule MyAppWeb.AuthController do
    use MyAppWeb, :controller
    use ShopifexWeb.AuthController

    # Thats it! Validation, installation are now handled for you :)
  end
  ```
  """
  @type shop :: %{access_token: String.t(), scope: String.t(), url: String.t()}

  @doc """
  An optional callback called after the installation is completed, the shop is
  persisted in the database and webhooks are registered. By default, this function
  redirects the user to the app within their Shopify admin panel.

  ## Example

      @impl true
      def after_install(conn, shop, oauth_state) do
        # send yourself an e-mail about shop installation

        # follow default behaviour.
        super(conn, shop, oauth_state)
      end
  """
  @callback after_install(Plug.Conn.t(), shop(), oauth_state :: String.t()) :: Plug.Conn.t()

  @doc """
  An optional callback called after the oauth update is completed. By default,
  this function redirects the user to the app within their Shopify admin panel.

  ## Example

      @impl true
      def after_update(conn, shop, oauth_state) do
        # do some work related to oauth_state

        # follow default behaviour.
        super(conn, shop, oauth_state)
      end
  """
  @callback after_update(Plug.Conn.t(), shop(), oauth_state :: String.t()) :: Plug.Conn.t()

  @doc """
  An optional callback which is called after the shop data has been retrieved from
  Shopify API. This function should persist the shop data and return a shop record.

  ## Example

      @impl true
      def insert_shop(shop) do
        # make sure there is only one store in the database because we don't have
        # a unique index on the url column for some reason.

        case Shopifex.Shops.get_shop_by_url(shop.url) do
          nil -> super(shop)
          shop -> shop
        end
      end
  """
  @callback insert_shop(shop()) :: shop()

  @doc """
  An optional callback which you can use to override how your app is rendered on
  initial load. If you are building a server-rendered app, you might just want
  to redirect to your index page. If you are building an externally hosted SPA,
  you probably want to redirect to the Shopify admin link for your app.

  Externally hosted SPA's will likely only hit this route on install.
  """
  @callback auth(conn :: Plug.Conn.t(), params :: Plug.Conn.params()) :: Plug.Conn.t()

  @optional_callbacks after_install: 3, after_update: 3, insert_shop: 1, auth: 2

  defmacro __using__(_opts) do
    quote do
      @behaviour ShopifexWeb.AuthController

      require Logger

      @impl ShopifexWeb.AuthController
      def auth(conn, params) do
        path_prefix = Application.get_env(:shopifex, :path_prefix, "")

        # A server 302 is a top-level iframe navigation, so — unlike App Bridge
        # `fetch`es — it does NOT inherit the `id_token`, and third-party cookies
        # are blocked, so identity is not carried implicitly to the landing route.
        # Forward the embedded-context params: per Shopify's docs App Bridge needs
        # `shop` and `host` to (re)initialize and acquire a session token on the
        # landing page, and forwarding the still-valid `id_token` lets that route's
        # `:shopify_session` authenticate this immediate hop without a bounce.
        # (Whatever route you redirect to must sit behind a `:shopify_session`
        # pipeline for this to work.)
        query =
          params
          |> Map.take(["shop", "host", "embedded", "locale", "id_token"])
          |> URI.encode_query()

        to = path_prefix <> "/" <> if(query == "", do: "", else: "?" <> query)

        redirect(conn, to: to)
      end

      def initialize_installation(conn, %{"shop" => shop_url} = params) do
        if Regex.match?(~r/^.*\.myshopify\.com/, shop_url) do
          # The installation case and reinstallation case share the same URL, and query parameters,
          # except for the value of of the redirect_uri
          url = fn redirect_uri ->
            build_external_url(["https://", shop_url, "/admin/oauth/authorize"], %{
              client_id: Application.fetch_env!(:shopifex, :api_key),
              scope: Application.fetch_env!(:shopifex, :scopes),
              redirect_uri: redirect_uri,
              state: params["state"]
            })
          end

          # check if store is in the system already:
          case Shopifex.Shops.get_shop_by_url(shop_url) do
            nil ->
              Logger.info("Initiating shop installation for #{shop_url}")
              install_url = url.(Application.fetch_env!(:shopifex, :redirect_uri))
              redirect(conn, external: install_url)

            shop ->
              Logger.info("Initiating shop reinstallation for #{shop_url}")
              reinstall_url = url.(Application.fetch_env!(:shopifex, :reinstall_uri))
              redirect(conn, external: reinstall_url)
          end
        else
          conn
          |> put_view(ShopifexWeb.AuthHTML)
          |> put_layout({ShopifexWeb.Layouts, :app})
          |> put_flash(:error, "Invalid shop URL")
          |> render("select_store.html")
        end
      end

      @impl ShopifexWeb.AuthController
      def after_install(conn, shop, _state) do
        shop_url = Shopifex.Shops.get_url(shop)
        api_key = Application.fetch_env!(:shopifex, :api_key)

        url = build_external_url(["https://", shop_url, "/admin/apps", api_key])
        redirect(conn, external: url)
      end

      @impl ShopifexWeb.AuthController
      def insert_shop(shop) do
        Shopifex.Shops.create_shop(shop)
      end

      def install(conn, %{"code" => code, "shop" => shop_url} = params) do
        state = Map.get(params, "state", "")
        url = build_external_url(["https://", shop_url, "/admin/oauth/access_token"])

        case Req.post(url,
               json: %{
                 client_id: Application.fetch_env!(:shopifex, :api_key),
                 client_secret: Application.fetch_env!(:shopifex, :secret),
                 code: code
               }
             ) do
          {:ok, %{status: 200, body: body}} ->
            params =
              body
              |> atomize_oauth_response()
              |> Map.put(:url, shop_url)

            params = Map.put(params, Shopifex.Shops.get_scope_field(), params[:scope])

            shop = insert_shop(params)

            Shopifex.Shops.configure_webhooks(shop)

            after_install(conn, shop, state)

          _error ->
            raise(Shopifex.InstallError, message: "Installation failed for shop #{shop_url}")
        end
      end

      @impl ShopifexWeb.AuthController
      def after_update(conn, shop, _state) do
        shop_url = Shopifex.Shops.get_url(shop)
        api_key = Application.fetch_env!(:shopifex, :api_key)

        url = build_external_url(["https://", shop_url, "/admin/apps/", api_key])
        redirect(conn, external: url)
      end

      def update(conn, %{"code" => code, "shop" => shop_url} = params) do
        state = Map.get(params, "state", "")
        url = build_external_url(["https://", shop_url, "/admin/oauth/access_token"])

        case Req.post(url,
               json: %{
                 client_id: Application.fetch_env!(:shopifex, :api_key),
                 client_secret: Application.fetch_env!(:shopifex, :secret),
                 code: code
               }
             ) do
          {:ok, %{status: 200, body: body}} ->
            params = atomize_oauth_response(body)

            params = Map.put(params, Shopifex.Shops.get_scope_field(), params[:scope])

            shop =
              shop_url
              |> Shopifex.Shops.get_shop_by_url()
              |> Shopifex.Shops.update_shop(params)

            Shopifex.Shops.configure_webhooks(shop)

            after_update(conn, shop, state)

          _error ->
            raise(Shopifex.UpdateError, message: "Update failed for shop #{shop_url}")
        end
      end

      defoverridable after_install: 3, after_update: 3, insert_shop: 1, auth: 2

      defp build_external_url(path, query_params \\ %{}) do
        Path.join(path) <> "?" <> URI.encode_query(query_params)
      end

      # Map the known keys from Shopify's OAuth / token-exchange response to
      # atoms via a fixed whitelist — never `String.to_atom/1` on external input
      # (atom-exhaustion DoS). Unknown keys are dropped; the shop changeset only
      # casts permitted fields, so this is behaviour-preserving for persistence.
      defp atomize_oauth_response(body) do
        atoms = %{
          "access_token" => :access_token,
          "scope" => :scope,
          "expires_in" => :expires_in,
          "refresh_token" => :refresh_token,
          "refresh_token_expires_in" => :refresh_token_expires_in
        }

        body
        |> Map.take(Map.keys(atoms))
        |> Map.new(fn {k, v} -> {Map.fetch!(atoms, k), v} end)
      end
    end
  end
end
