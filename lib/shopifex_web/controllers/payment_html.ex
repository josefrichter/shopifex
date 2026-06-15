defmodule ShopifexWeb.PaymentHTML do
  @moduledoc """
  HTML for the plans/billing page rendered by `ShopifexWeb.PaymentController`.
  """
  use ShopifexWeb, :html

  embed_templates("payment_html/*")

  def path_prefix, do: Application.get_env(:shopifex, :path_prefix, "")
  def api_key, do: Application.get_env(:shopifex, :api_key)
  def payment_guard, do: Application.get_env(:shopifex, :payment_guard)

  def available_plans(shop, guard) do
    shop
    |> payment_guard().list_available_plans_for_guard(guard)
    |> Enum.map(fn plan ->
      Map.take(plan, [:id, :features, :grants, :name, :price, :type, :usages])
    end)
    |> Jason.encode!()
  end

  def current_grants(conn) do
    shop = Shopifex.Plug.current_shop(conn)
    payment_guard = Application.fetch_env!(:shopifex, :payment_guard)

    shop
    |> payment_guard.grants_for_shop()
    |> Enum.map(& &1.grants)
    |> List.flatten()
    |> Enum.uniq()
    |> Enum.join(",")
  end

  def shop_url(%Plug.Conn{} = conn) do
    conn
    |> Shopifex.Plug.current_shop()
    |> Shopifex.Shops.get_url()
  end
end
