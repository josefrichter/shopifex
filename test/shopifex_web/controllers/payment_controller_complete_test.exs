defmodule ShopifexWeb.PaymentControllerCompleteTest do
  # Covers complete_payment/2: the loud-fail on a redirect-cache miss (B2), and
  # the full select_plan -> complete_payment grant creation when a persistent
  # Shopifex.RedirectAfter.Ecto store is configured.
  use ShopifexWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Shopifex.Shops

  setup %{conn: conn} do
    shop =
      Shops.create_shop(%{url: "complete.myshopify.com", scope: "orders", access_token: "tok"})

    {:ok, plan} =
      Shops.create_plan(%{
        name: "Basic",
        price: "9.99",
        type: "recurring_application_charge",
        features: ["premium"],
        grants: ["premium"],
        usages: nil,
        test: true
      })

    {:ok, conn: conn, shop: shop, plan: plan}
  end

  describe "redirect-cache miss" do
    test "logs an actionable error and responds with a 403 Conn (not the bare tuple)", %{
      conn: conn,
      shop: shop,
      plan: plan
    } do
      # No redirect-after entry was ever stored for this charge (the multi-node
      # symptom: the confirmation redirect hit a node that never ran select_plan).
      {result, log} =
        with_log(fn ->
          ShopifexDummyWeb.PaymentController.complete_payment(conn, %{
            "charge_id" => "9999999",
            "plan_id" => to_string(plan.id),
            "shop" => shop.url
          })
        end)

      # A controller action MUST return a Plug.Conn — returning {:error, :forbidden}
      # raised a 500. Assert the response shape, not the old tuple.
      assert %Plug.Conn{status: 403} = result
      assert log =~ "no redirect-after entry"
      assert log =~ "redirect_after_agent"
    end

    test "GET /payment/complete with an unknown charge_id returns 403, never a raised 500", %{
      conn: conn,
      shop: shop,
      plan: plan
    } do
      # Drive it through the real router/action pipeline — the exact path the bug
      # broke (a non-Conn return raised before any response). The earlier
      # function-level test bypassed this and so never caught the 500.
      {conn, _log} =
        with_log(fn ->
          get(conn, "/payment/complete", %{
            "charge_id" => "9999999",
            "plan_id" => to_string(plan.id),
            "shop" => shop.url
          })
        end)

      assert conn.status == 403
    end
  end

  describe "with a persistent Shopifex.RedirectAfter.Ecto store" do
    setup do
      previous = Application.get_env(:shopifex, :redirect_after_agent)
      Application.put_env(:shopifex, :redirect_after_agent, Shopifex.RedirectAfter.Ecto)

      on_exit(fn ->
        if previous do
          Application.put_env(:shopifex, :redirect_after_agent, previous)
        else
          Application.delete_env(:shopifex, :redirect_after_agent)
        end
      end)

      :ok
    end

    test "select_plan's redirect survives to complete_payment and the grant is created", %{
      conn: conn,
      shop: shop,
      plan: plan
    } do
      charge_id = "4019552312"

      # select_plan stores this (here we store it directly, simulating that the
      # write happened on a *different* node — the Ecto store is shared).
      :ok = Shopifex.RedirectAfter.Ecto.set(charge_id, "/")

      conn =
        ShopifexDummyWeb.PaymentController.complete_payment(conn, %{
          "charge_id" => charge_id,
          "plan_id" => to_string(plan.id),
          "shop" => shop.url
        })

      # after_payment redirects into the Shopify admin (not {:error, :forbidden}).
      assert conn.status in [301, 302]

      [grant] = Shops.list_grants()
      assert grant.charge_id == String.to_integer(charge_id)
      assert grant.grants == ["premium"]

      # one-shot: the redirect entry was consumed
      assert Shopifex.RedirectAfter.Ecto.get(charge_id) == nil
    end
  end
end
