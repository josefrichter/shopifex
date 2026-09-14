defmodule ShopifexWeb.PaymentHTML do
  @moduledoc """
  HTML for the plans/billing page rendered by `ShopifexWeb.PaymentController`.
  """
  use ShopifexWeb, :html

  embed_templates("payment_html/*")

  def path_prefix, do: Application.get_env(:shopifex, :path_prefix, "")
  def api_key, do: Application.get_env(:shopifex, :api_key)
  def payment_guard, do: Application.get_env(:shopifex, :payment_guard)

  @doc "The plans available for `guard`, as schema structs, for server rendering."
  def plans_for_guard(%Plug.Conn{} = conn, guard) do
    conn
    |> Shopifex.Plug.current_shop()
    |> payment_guard().list_available_plans_for_guard(guard)
  end

  @doc "True when `plan` grants exactly the shop's current grant set (the active plan)."
  def current_plan?(%Plug.Conn{} = conn, plan) do
    current_plan?(current_grant_list(conn), plan)
  end

  def current_plan?(current_grants, plan) when is_list(current_grants) do
    Enum.sort(List.wrap(plan.grants)) == Enum.sort(current_grants)
  end

  @doc "Human price label, e.g. `$9.99/month`, `€100/year`, or `$390 one-time`."
  def price_label(plan) do
    currency = Map.get(plan, :currency_code, "USD") || "USD"

    price_str =
      case currency do
        "USD" -> "$#{plan.price}"
        "EUR" -> "€#{plan.price}"
        "GBP" -> "£#{plan.price}"
        code -> "#{code} #{plan.price}"
      end

    case plan.type do
      "recurring_application_charge" ->
        interval = if Map.get(plan, :annual, false), do: "/year", else: "/month"
        "#{price_str}#{interval}"

      _ ->
        "#{price_str} one-time"
    end
  end

  @doc "The deduped list of grant identifiers the shop currently holds."
  def current_grant_list(%Plug.Conn{} = conn) do
    shop = Shopifex.Plug.current_shop(conn)
    payment_guard = Application.fetch_env!(:shopifex, :payment_guard)

    shop
    |> payment_guard.grants_for_shop()
    |> Enum.map(& &1.grants)
    |> List.flatten()
    |> Enum.uniq()
  end

  @doc "The shop's current grants as a comma-joined string (kept for back-compat)."
  def current_grants(conn), do: conn |> current_grant_list() |> Enum.join(",")

  def shop_url(%Plug.Conn{} = conn) do
    conn
    |> Shopifex.Plug.current_shop()
    |> Shopifex.Shops.get_url()
  end
end
