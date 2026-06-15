defmodule ShopifexWeb.PaymentControllerChargeTest do
  use Shopifex.DataCase, async: false

  alias Shopifex.Shops

  setup do
    shop =
      Shops.create_shop(%{url: "billing.myshopify.com", scope: "orders", access_token: "tok"})

    {:ok, shop: shop}
  end

  # Captures the full GraphQL request body (query + variables) so tests can
  # assert both the mutation shape and the variables Shopify actually receives.
  defp stub_charge(mutation_field, charge_field, gid) do
    parent = self()

    Req.Test.stub(Shopifex.ReqStub, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {:graphql, Jason.decode!(body)})

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

  defp assert_no_idempotent(query) do
    refute query =~ "@idempotent", "Shopify does not document @idempotent for billing mutations"
  end

  describe "appSubscriptionCreate (recurring)" do
    test "monthly plan passes lineItems as a variable with the EVERY_30_DAYS interval", %{
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

      assert {:ok,
              %{"id" => "4019552312", "confirmation_url" => "https://confirm.example/charge"}} =
               ShopifexDummyWeb.PaymentController.create_charge(shop, plan)

      assert_received {:graphql, %{"query" => query, "variables" => variables}}
      assert query =~ "appSubscriptionCreate"
      # lineItems is a GraphQL variable, not interpolated into the query string.
      assert query =~ "lineItems: $lineItems"
      refute query =~ "appRecurringPricingDetails"
      assert_no_idempotent(query)

      assert [%{"plan" => %{"appRecurringPricingDetails" => pricing}}] = variables["lineItems"]
      assert pricing["interval"] == "EVERY_30_DAYS"
      assert pricing["price"] == %{"amount" => "9.99", "currencyCode" => "USD"}
      assert variables["trialDays"] == 0
    end

    test "annual plan uses the ANNUAL interval", %{shop: shop} do
      stub_charge("appSubscriptionCreate", "appSubscription", "gid://shopify/AppSubscription/7")

      plan = %{
        id: 2,
        name: "Pro",
        price: "99.00",
        type: "recurring_application_charge",
        annual: true,
        test: true
      }

      assert {:ok, %{"id" => "7"}} = ShopifexDummyWeb.PaymentController.create_charge(shop, plan)
      assert_received {:graphql, %{"variables" => variables}}

      assert [%{"plan" => %{"appRecurringPricingDetails" => %{"interval" => "ANNUAL"}}}] =
               variables["lineItems"]
    end

    test "passes trialDays through", %{shop: shop} do
      stub_charge("appSubscriptionCreate", "appSubscription", "gid://shopify/AppSubscription/8")

      plan = %{
        id: 3,
        name: "Trial",
        price: "10.00",
        type: "recurring_application_charge",
        trial_days: 14,
        test: true
      }

      assert {:ok, _} = ShopifexDummyWeb.PaymentController.create_charge(shop, plan)
      assert_received {:graphql, %{"query" => query, "variables" => variables}}
      assert query =~ "$trialDays: Int!"
      assert variables["trialDays"] == 14
    end

    test "normalizes replacement_behavior into the AppSubscriptionReplacementBehavior enum", %{
      shop: shop
    } do
      stub_charge("appSubscriptionCreate", "appSubscription", "gid://shopify/AppSubscription/9")

      plan = %{
        id: 4,
        name: "Upgrade",
        price: "20.00",
        type: "recurring_application_charge",
        replacement_behavior: :apply_immediately,
        test: true
      }

      assert {:ok, _} = ShopifexDummyWeb.PaymentController.create_charge(shop, plan)
      assert_received {:graphql, %{"query" => query, "variables" => variables}}
      assert query =~ "$replacementBehavior: AppSubscriptionReplacementBehavior"
      assert variables["replacementBehavior"] == "APPLY_IMMEDIATELY"
    end

    test "omits replacementBehavior (null) when the plan has none", %{shop: shop} do
      stub_charge("appSubscriptionCreate", "appSubscription", "gid://shopify/AppSubscription/10")

      plan = %{
        id: 5,
        name: "Plain",
        price: "5.00",
        type: "recurring_application_charge",
        test: true
      }

      assert {:ok, _} = ShopifexDummyWeb.PaymentController.create_charge(shop, plan)
      assert_received {:graphql, %{"variables" => variables}}
      assert variables["replacementBehavior"] == nil
    end

    test "merges a discount into the default line item's pricing details", %{shop: shop} do
      stub_charge("appSubscriptionCreate", "appSubscription", "gid://shopify/AppSubscription/11")

      plan = %{
        id: 6,
        name: "Discounted",
        price: "30.00",
        type: "recurring_application_charge",
        discount: %{value: %{percentage: 0.2}, durationLimitInIntervals: 3},
        test: true
      }

      assert {:ok, _} = ShopifexDummyWeb.PaymentController.create_charge(shop, plan)
      assert_received {:graphql, %{"variables" => variables}}
      assert [%{"plan" => %{"appRecurringPricingDetails" => pricing}}] = variables["lineItems"]

      assert pricing["discount"] == %{
               "value" => %{"percentage" => 0.2},
               "durationLimitInIntervals" => 3
             }
    end

    test "a caller-supplied :line_items list (multiple items / usage) overrides the default", %{
      shop: shop
    } do
      stub_charge("appSubscriptionCreate", "appSubscription", "gid://shopify/AppSubscription/12")

      line_items = [
        %{
          plan: %{
            appRecurringPricingDetails: %{
              price: %{amount: "10.00", currencyCode: "USD"},
              interval: "EVERY_30_DAYS"
            }
          }
        },
        %{
          plan: %{
            appUsagePricingDetails: %{
              terms: "$1 per 100 emails",
              cappedAmount: %{amount: "100.00", currencyCode: "USD"}
            }
          }
        }
      ]

      plan = %{
        id: 7,
        name: "Metered",
        price: "10.00",
        type: "recurring_application_charge",
        line_items: line_items,
        test: true
      }

      assert {:ok, _} = ShopifexDummyWeb.PaymentController.create_charge(shop, plan)
      assert_received {:graphql, %{"variables" => variables}}
      assert length(variables["lineItems"]) == 2
      assert [_, %{"plan" => %{"appUsagePricingDetails" => usage}}] = variables["lineItems"]
      assert usage["terms"] == "$1 per 100 emails"
    end

    test "honors a custom currency_code on the recurring line item", %{shop: shop} do
      stub_charge("appSubscriptionCreate", "appSubscription", "gid://shopify/AppSubscription/13")

      plan = %{
        id: 9,
        name: "Euro",
        price: "9.99",
        type: "recurring_application_charge",
        currency_code: "EUR",
        test: true
      }

      assert {:ok, _} = ShopifexDummyWeb.PaymentController.create_charge(shop, plan)
      assert_received {:graphql, %{"variables" => variables}}
      assert [%{"plan" => %{"appRecurringPricingDetails" => pricing}}] = variables["lineItems"]
      assert pricing["price"]["currencyCode"] == "EUR"
    end

    test "upcases a string-form replacement_behavior", %{shop: shop} do
      stub_charge("appSubscriptionCreate", "appSubscription", "gid://shopify/AppSubscription/14")

      plan = %{
        id: 10,
        name: "Standard",
        price: "9.99",
        type: "recurring_application_charge",
        replacement_behavior: "standard",
        test: true
      }

      assert {:ok, _} = ShopifexDummyWeb.PaymentController.create_charge(shop, plan)
      assert_received {:graphql, %{"variables" => variables}}
      assert variables["replacementBehavior"] == "STANDARD"
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

      plan = %{id: 8, name: "Bad", price: "x", type: "recurring_application_charge", test: true}

      assert {:error, [%{"message" => "is invalid"}]} =
               ShopifexDummyWeb.PaymentController.create_charge(shop, plan)
    end
  end

  describe "appPurchaseOneTimeCreate (one-time)" do
    test "passes a MoneyInput price and sends no @idempotent directive", %{shop: shop} do
      stub_charge(
        "appPurchaseOneTimeCreate",
        "appPurchaseOneTime",
        "gid://shopify/AppPurchaseOneTime/55"
      )

      plan = %{id: 9, name: "Lifetime", price: "390.00", type: "application_charge", test: true}

      assert {:ok, %{"id" => "55", "confirmation_url" => "https://confirm.example/charge"}} =
               ShopifexDummyWeb.PaymentController.create_charge(shop, plan)

      assert_received {:graphql, %{"query" => query, "variables" => variables}}
      assert query =~ "appPurchaseOneTimeCreate"
      assert query =~ "$price: MoneyInput!"
      assert_no_idempotent(query)
      assert variables["price"] == %{"amount" => "390.00", "currencyCode" => "USD"}
    end

    test "honors a custom currency_code on the one-time price", %{shop: shop} do
      stub_charge(
        "appPurchaseOneTimeCreate",
        "appPurchaseOneTime",
        "gid://shopify/AppPurchaseOneTime/56"
      )

      plan = %{
        id: 11,
        name: "Lifetime EUR",
        price: "390.00",
        type: "application_charge",
        currency_code: "EUR",
        test: true
      }

      assert {:ok, _} = ShopifexDummyWeb.PaymentController.create_charge(shop, plan)
      assert_received {:graphql, %{"variables" => variables}}
      assert variables["price"]["currencyCode"] == "EUR"
    end
  end
end
