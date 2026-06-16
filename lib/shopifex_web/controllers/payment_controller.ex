defmodule ShopifexWeb.PaymentController do
  @moduledoc """
  You can use this module inside of another controller to handle initial iFrame load and shop installation

  Example:

  mix phx.gen.html Shops Plan plans name:string price:string features:array grants:array test:boolean
  mix phx.gen.html Shops Grant grants shop:references:shops charge_id:integer grants:array

  ```elixir
  defmodule MyAppWeb.PaymentController do
    use MyAppWeb, :controller
    use ShopifexWeb.PaymentController

    # Thats it! You can now configure your purchasable products :)
  end
  ```
  """

  @doc """
  Display the available payment plans for the user to select.
  """
  @callback render_plans(
              conn :: Plug.Conn.t(),
              guard_identifier :: String.t(),
              redirect_after :: String.t()
            ) :: Plug.Conn.t()

  @doc """
  An optional callback called after a payment is completed. By default, this function
  redirects the user to the app index within their Shopify admin panel.

  ## Example

      def after_payment(conn, shop, plan, grant, redirect_after) do
        # send yourself an e-mail about payment

        # follow default behaviour.
        super(conn, shop, plan, grant, redirect_after)
      end
  """
  @callback after_payment(
              Plug.Conn.t(),
              Ecto.Schema.t(),
              Ecto.Schema.t(),
              Ecto.Schema.t(),
              String.t()
            ) ::
              Plug.Conn.t()

  @doc """
  Given a shop and plan, return boolean for whether the charge should be created as
  a test charge.
  """
  @callback test_charge?(shop :: Ecto.Schema.t(), plan :: map()) :: boolean()

  @optional_callbacks render_plans: 3, after_payment: 5, test_charge?: 2

  defmacro __using__(_opts) do
    quote do
      @behaviour ShopifexWeb.PaymentController

      require Logger

      def show_plans(conn, params) do
        payment_guard = Application.fetch_env!(:shopifex, :payment_guard)
        path_prefix = Application.get_env(:shopifex, :path_prefix, "")
        # Embedded apps re-authenticate via Shopify's per-load id_token, so the
        # post-payment redirect just returns to the app root.
        default_redirect_after = path_prefix <> "/"

        render_plans(
          conn,
          Map.get(params, "guard_identifier"),
          Map.get(params, "redirect_after", default_redirect_after)
        )
      end

      def select_plan(conn, %{"plan_id" => plan_id, "redirect_after" => redirect_after}) do
        payment_guard = Application.fetch_env!(:shopifex, :payment_guard)

        redirect_after_agent =
          Application.get_env(:shopifex, :redirect_after_agent, Shopifex.RedirectAfterAgent)

        plan = payment_guard.get_plan(plan_id)
        shop = Shopifex.Plug.current_shop(conn)

        {:ok, charge} = create_charge(shop, plan)

        redirect_after_agent.set(charge["id"], redirect_after)

        send_resp(conn, 200, Jason.encode!(charge))
      end

      @impl ShopifexWeb.PaymentController
      def test_charge?(_shop, %{test: test?} = _plan), do: test?

      @doc """
      Creates a Shopify charge for the given plan and returns
      `{:ok, %{"id" => charge_id, "confirmation_url" => url}}`.

      Recurring plans (`type: "recurring_application_charge"`) use
      `appSubscriptionCreate` (monthly by default, annual when `plan.annual` is
      true). One-time plans (`type: "application_charge"`) use
      `appPurchaseOneTimeCreate`. Both run through `Shopifex.API.graphql/3`
      (which keeps the access token fresh and uses the configured API version)
      and match Shopify's documented GraphQL shape — line items are passed as a
      `$lineItems` variable rather than interpolated into the query, and no
      `@idempotent` directive is sent (Shopify does not document one for these
      mutations).

      ### Optional recurring features

      The default builds a single recurring line item from `plan.price` /
      `plan.annual`. Supply extra plan data to opt into Shopify features:

        * `:replacement_behavior` — an `AppSubscriptionReplacementBehavior`
          (e.g. `:apply_immediately`, `"STANDARD"`).
        * `:currency_code` — defaults to `"USD"`.
        * `:discount` — an `AppSubscriptionDiscountInput` map merged into the
          default line item's pricing details.
        * `:line_items` — a fully-formed list of `AppSubscriptionLineItemInput`
          maps. When given, it overrides the default line item entirely, so you
          can pass multiple line items, usage (`appUsagePricingDetails`) pricing,
          or custom discounts.

      Overridable — define your own `create_charge/2` to customise pricing.
      """
      def create_charge(shop, %{type: "recurring_application_charge"} = plan) do
        mutation = """
        mutation appSubscriptionCreate($name: String!, $returnUrl: URL!, $test: Boolean!, $trialDays: Int!, $lineItems: [AppSubscriptionLineItemInput!]!, $replacementBehavior: AppSubscriptionReplacementBehavior) {
          appSubscriptionCreate(name: $name, returnUrl: $returnUrl, test: $test, trialDays: $trialDays, lineItems: $lineItems, replacementBehavior: $replacementBehavior) {
            appSubscription {
              id
            }
            confirmationUrl
            userErrors {
              field
              message
            }
          }
        }
        """

        variables = %{
          name: plan.name,
          test: test_charge?(shop, plan),
          trialDays: Map.get(plan, :trial_days, 0),
          returnUrl: charge_return_url(shop, plan),
          lineItems: subscription_line_items(plan),
          replacementBehavior:
            normalize_replacement_behavior(Map.get(plan, :replacement_behavior))
        }

        shop
        |> Shopifex.API.graphql(mutation, variables)
        |> unwrap_charge("appSubscriptionCreate", "appSubscription")
      end

      def create_charge(shop, %{type: "application_charge"} = plan) do
        mutation = """
        mutation appPurchaseOneTimeCreate($name: String!, $returnUrl: URL!, $test: Boolean!, $price: MoneyInput!) {
          appPurchaseOneTimeCreate(name: $name, returnUrl: $returnUrl, test: $test, price: $price) {
            appPurchaseOneTime {
              id
            }
            confirmationUrl
            userErrors {
              field
              message
            }
          }
        }
        """

        variables = %{
          name: plan.name,
          price: %{amount: to_string(plan.price), currencyCode: charge_currency_code(plan)},
          test: test_charge?(shop, plan),
          returnUrl: charge_return_url(shop, plan)
        }

        shop
        |> Shopifex.API.graphql(mutation, variables)
        |> unwrap_charge("appPurchaseOneTimeCreate", "appPurchaseOneTime")
      end

      # A caller-supplied `:line_items` list wins outright (multiple line items,
      # usage pricing, custom discounts). Otherwise build the single recurring
      # line item from price/interval, optionally with a discount.
      defp subscription_line_items(%{line_items: line_items}) when is_list(line_items),
        do: line_items

      defp subscription_line_items(plan) do
        interval = if Map.get(plan, :annual, false), do: "ANNUAL", else: "EVERY_30_DAYS"

        pricing =
          %{
            price: %{amount: to_string(plan.price), currencyCode: charge_currency_code(plan)},
            interval: interval
          }
          |> maybe_put(:discount, Map.get(plan, :discount))

        [%{plan: %{appRecurringPricingDetails: pricing}}]
      end

      defp charge_currency_code(plan), do: Map.get(plan, :currency_code, "USD")

      defp normalize_replacement_behavior(nil), do: nil

      defp normalize_replacement_behavior(value) when is_atom(value),
        do: value |> Atom.to_string() |> String.upcase()

      defp normalize_replacement_behavior(value) when is_binary(value), do: String.upcase(value)

      defp maybe_put(map, _key, nil), do: map
      defp maybe_put(map, key, value), do: Map.put(map, key, value)

      defp charge_return_url(shop, plan) do
        redirect_uri = Application.get_env(:shopifex, :payment_redirect_uri)
        "#{redirect_uri}?plan_id=#{plan.id}&shop=#{Shopifex.Shops.get_url(shop)}"
      end

      defp unwrap_charge(result, mutation_field, charge_field) do
        case result do
          {:ok,
           %{
             ^mutation_field => %{
               "userErrors" => [],
               ^charge_field => %{"id" => gid},
               "confirmationUrl" => confirmation_url
             }
           }} ->
            # gid is "gid://shopify/AppSubscription/4019552312" — Shopify sends
            # the trailing numeric id back as the `charge_id` return-url param.
            {:ok,
             %{"id" => List.last(String.split(gid, "/")), "confirmation_url" => confirmation_url}}

          {:ok, %{^mutation_field => %{"userErrors" => errors}}} ->
            {:error, errors}

          error ->
            error
        end
      end

      def complete_payment(conn, %{
            "charge_id" => charge_id,
            "plan_id" => plan_id,
            "shop" => shop_url
          }) do
        redirect_after_agent =
          Application.get_env(:shopifex, :redirect_after_agent, Shopifex.RedirectAfterAgent)

        # Shopify's API doesn't provide an HMAC validation on this return-url.
        # The redirect-after entry stored against this charge_id at `select_plan`
        # time doubles as the anti-forgery check: no entry => we never started
        # this charge here, so reject.
        case redirect_after_agent.get(charge_id) do
          nil ->
            # A missing entry is *expected* to mean forgery — but with the default
            # in-memory Shopifex.RedirectAfterAgent it also happens, legitimately,
            # whenever Shopify's /payment/complete redirect lands on a different
            # node than the one that ran select_plan. In that case the merchant
            # was charged but the Grant is never created. Log loudly so this is
            # observable instead of a silent dropped grant — a node-local cache on
            # a multi-node deploy is the usual cause; switch to a persistent store
            # (Shopifex.RedirectAfter.Ecto) via config :shopifex, :redirect_after_agent.
            Logger.error(
              "[shopifex] complete_payment: no redirect-after entry for charge_id=" <>
                "#{inspect(charge_id)} (shop=#{inspect(shop_url)}). Treating as forbidden. " <>
                "If the merchant was actually charged, the grant was just dropped: the default " <>
                "RedirectAfterAgent is in-memory and node-local, so the confirmation redirect " <>
                "missed on a multi-node deploy. Configure a persistent " <>
                "config :shopifex, :redirect_after_agent (e.g. Shopifex.RedirectAfter.Ecto)."
            )

            {:error, :forbidden}

          redirect_after ->
            redirect_after = URI.decode_www_form(redirect_after)

            case Shopifex.Shops.get_shop_by_url(shop_url) do
              nil ->
                {:error, :forbidden}

              shop ->
                payment_guard = Application.fetch_env!(:shopifex, :payment_guard)
                plan = payment_guard.get_plan(plan_id)
                {:ok, grant} = payment_guard.create_grant(shop, plan, charge_id)
                after_payment(conn, shop, plan, grant, redirect_after)
            end
        end
      end

      @impl ShopifexWeb.PaymentController
      def render_plans(conn, guard_identifier, redirect_after) do
        conn
        |> put_view(ShopifexWeb.PaymentHTML)
        |> put_layout({ShopifexWeb.Layouts, :app})
        |> render("show_plans.html",
          guard: guard_identifier,
          redirect_after: redirect_after
        )
      end

      @impl ShopifexWeb.PaymentController
      def after_payment(conn, shop, _plan, _grant, redirect_after) do
        api_key = Application.get_env(:shopifex, :api_key)

        redirect(conn,
          external:
            "https://#{Shopifex.Shops.get_url(shop)}/admin/apps/#{api_key}#{redirect_after}"
        )
      end

      defoverridable render_plans: 3, after_payment: 5, test_charge?: 2, create_charge: 2
    end
  end
end
