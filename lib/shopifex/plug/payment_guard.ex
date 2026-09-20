defmodule Shopifex.Plug.PaymentGuard do
  @moduledoc """
  Add payment guards to your routes or controllers!

  ## Examples:

  ```elixir
  defmodule MyAppWeb.AdminLinkController do
    use MyAppWeb, :controller
    require Logger

    plug Shopifex.Plug.PaymentGuard, "premium_plan" when action in [:premium_function]

    def premium_function(conn, _params) do
      # Wow, much premium.
      conn
      |> send_resp(200, "success")
    end
  end
  ```
  """
  require Logger

  def init(options) do
    # initialize options
    options
  end

  @doc """
  This makes sure the shop in the session contains a payment which unlocks the guard.

  If no payment is present which unlocks the guard (or remaining usages are exhausted),
  the conn will be redirected to your application's PaymentController.show_plans route.
  """
  def call(conn, guard_identifier) do
    payment_guard = Application.fetch_env!(:shopifex, :payment_guard)
    shop = Shopifex.Plug.current_shop(conn)

    with grant when not is_nil(grant) <- payment_guard.grant_for_guard(shop, guard_identifier),
         updated_grant when not is_nil(updated_grant) <- payment_guard.use_grant(shop, grant) do
      Plug.Conn.put_private(conn, :grant_for_guard, updated_grant)
    else
      _ ->
        Logger.info("Payment guard blocked request")
        redirect_after = URI.encode_www_form("#{conn.request_path}?#{conn.query_string}")

        prefix = Application.get_env(:shopifex, :path_prefix, "")

        params =
          %{
            "guard_identifier" => guard_identifier,
            "redirect_after" => redirect_after,
            "timestamp" => Integer.to_string(System.system_time(:second))
          }
          |> maybe_put("shop", shop && Shopifex.Shops.get_url(shop))
          |> maybe_put("token", Shopifex.Plug.session_token(conn))
          |> sign_redirect()

        show_plans_url = "#{prefix}/payment/show-plans?#{URI.encode_query(params)}"

        conn
        |> Phoenix.Controller.redirect(to: show_plans_url)
        |> Plug.Conn.halt()
    end
  end

  defp maybe_put(params, _key, nil), do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  # Sign the redirect the way Shopify signs an app load (`hmac` over the sorted
  # query, plus a `timestamp`), so the show-plans route's `:shopify_session`
  # pipeline accepts it even when the blocked request carried no App Bridge
  # `id_token` — legacy HMAC-authenticated and non-embedded apps. When an
  # `id_token` is present it is forwarded as `token` and used first.
  defp sign_redirect(params) do
    secret = Application.fetch_env!(:shopifex, :secret)
    Map.put(params, "hmac", Shopifex.Plug.query_string_hmac(params, "&", secret))
  end
end
