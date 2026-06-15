defmodule ShopifexWeb.PaymentControllerChargeTest do
  use Shopifex.DataCase, async: false

  alias Shopifex.Shops

  setup do
    shop =
      Shops.create_shop(%{url: "billing.myshopify.com", scope: "orders", access_token: "tok"})

    {:ok, shop: shop}
  end

  defp stub_charge(mutation_field, charge_field, gid) do
    parent = self()

    Req.Test.stub(Shopifex.ReqStub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:query, Jason.decode!(body)["query"]})

      Req.Test.json(conn, %{
        "data" => %{
          mutation_field => %{
            charge_field => %{"id" => gid},
            "confirmationUrl" => "https://confirm.example/charge",
            "userErrors" => []
          }
        }
      })
    end)
  end

  test "recurring plan uses appSubscriptionCreate (monthly) with an idempotency key", %{
    shop: shop
  } do
    stub_charge(
      "appSubscriptionCreate",
      "appSubscription",
      "gid://shopify/AppSubscription/4019552312"
    )

    plan = %{
      id: 1,
      name: "Basic",
      price: "9.99",
      type: "recurring_application_charge",
      test: true
    }

    assert {:ok, %{"id" => "4019552312", "confirmation_url" => "https://confirm.example/charge"}} =
             ShopifexDummyWeb.PaymentController.create_charge(shop, plan)

    assert_received {:query, query}
    assert query =~ "appSubscriptionCreate"
    assert query =~ "@idempotent(key:"
    assert query =~ "EVERY_30_DAYS"
  end

  test "annual recurring plan uses the ANNUAL interval", %{shop: shop} do
    stub_charge(
      "appSubscriptionCreate",
      "appSubscription",
      "gid://shopify/AppSubscription/7"
    )

    plan = %{
      id: 2,
      name: "Pro",
      price: "99.00",
      type: "recurring_application_charge",
      annual: true,
      test: true
    }

    assert {:ok, %{"id" => "7"}} = ShopifexDummyWeb.PaymentController.create_charge(shop, plan)
    assert_received {:query, query}
    assert query =~ "ANNUAL"
  end

  test "one-time plan uses appPurchaseOneTimeCreate with an idempotency key", %{shop: shop} do
    stub_charge(
      "appPurchaseOneTimeCreate",
      "appPurchaseOneTime",
      "gid://shopify/AppPurchaseOneTime/55"
    )

    plan = %{id: 3, name: "Lifetime", price: "390.00", type: "application_charge", test: true}

    assert {:ok, %{"id" => "55", "confirmation_url" => "https://confirm.example/charge"}} =
             ShopifexDummyWeb.PaymentController.create_charge(shop, plan)

    assert_received {:query, query}
    assert query =~ "appPurchaseOneTimeCreate"
    assert query =~ "@idempotent(key:"
  end

  test "surfaces userErrors from Shopify", %{shop: shop} do
    Req.Test.stub(Shopifex.ReqStub, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{
          "appSubscriptionCreate" => %{
            "appSubscription" => nil,
            "confirmationUrl" => nil,
            "userErrors" => [%{"field" => ["price"], "message" => "is invalid"}]
          }
        }
      })
    end)

    plan = %{id: 4, name: "Bad", price: "x", type: "recurring_application_charge", test: true}

    assert {:error, [%{"message" => "is invalid"}]} =
             ShopifexDummyWeb.PaymentController.create_charge(shop, plan)
  end
end
