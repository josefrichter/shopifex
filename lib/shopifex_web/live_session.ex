defmodule ShopifexWeb.LiveSession do
  # To avoid making LiveView a dependency of the entire application, we'll
  # silence this warning. At runtime, the LiveView module will be available
  # if the application is using LiveView.
  @compile {:no_warn_undefined, Phoenix.Component}

  @doc """
  Get options that should be passed to `live_session`.

  This is useful for integrating with other tools that require a custom `live_session`,
  like `beacon_live_admin`. For example:

  ```elixir
  beacon_live_admin ShopifexWeb.LiveSession.opts(...beacon_opts) do
    ...
  end
  ```
  """
  def opts(custom_opts \\ []) do
    on_mount = {__MODULE__, :assign_shop_to_socket}
    session = {__MODULE__, :put_shop_in_session, []}

    custom_opts
    |> Keyword.update(:on_mount, on_mount, &([on_mount] ++ List.wrap(&1)))
    |> Keyword.put(:session, session)
  end

  @doc """
  Return a map of session values to include in the liveview session. This
  will be merged with other session values and available in the on_mount.
  """
  def put_shop_in_session(conn) do
    session_token = Shopifex.Plug.session_token(conn)
    current_shop = Shopifex.Plug.current_shop(conn)
    %{"session_token" => session_token, "current_shop" => current_shop}
  end

  @doc """
  LiveView on_mount hooks for Shopify apps.

  ## `:assign_shop_to_socket` (default)

  Assigns `current_shop` and `session_token` from session to socket assigns.
  Use with the standard `shopifex_live_session` macro.

  ## `:embedded`

  Simplified hook for embedded Shopify apps where third-party cookies are
  blocked. Reads the shop from the session (set during the HTTP request by
  `put_shop_in_session/1`) and does NOT require tokens in URLs or LiveSocket
  connect params. Redirects to `/auth` if no shop is found.

  ### How it works

  1. HTTP request arrives with `id_token` from App Bridge
  2. `ManagedInstall` plug validates the token and builds a Shopifex session
  3. `put_shop_in_session/1` serializes the shop into the LiveView session
  4. This hook reads the shop from the session — no tokens needed

  Within a `live_session`, LiveView preserves the session across navigations.
  Full page loads get a fresh `id_token` from App Bridge automatically.

  ### Usage

      live_session :my_app,
        on_mount: [{ShopifexWeb.LiveSession, :embedded}],
        session: {ShopifexWeb.LiveSession, :put_shop_in_session, []}
  """
  def on_mount(:assign_shop_to_socket, _params, session, socket) do
    assigns = %{
      current_shop: session["current_shop"],
      session_token: session["session_token"]
    }

    {:cont, Phoenix.Component.assign(socket, assigns)}
  end

  @compile {:no_warn_undefined, Phoenix.LiveView}
  def on_mount(:embedded, _params, session, socket) do
    shop = session["current_shop"]

    if shop do
      {:cont, Phoenix.Component.assign(socket, current_shop: shop, session_token: nil)}
    else
      {:halt, Phoenix.LiveView.redirect(socket, to: "/auth")}
    end
  end
end
