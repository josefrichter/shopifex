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
            "redirect_after" => redirect_after
          }
          |> maybe_put_token(Shopifex.Plug.session_token(conn))

        show_plans_url = "#{prefix}/payment/show-plans?#{URI.encode_query(params)}"

        conn
        |> Phoenix.Controller.redirect(to: show_plans_url)
        |> Plug.Conn.halt()
    end
  end

  defp maybe_put_token(params, nil), do: params
  defp maybe_put_token(params, token), do: Map.put(params, "token", token)
end
