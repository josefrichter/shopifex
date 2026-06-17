defmodule Shopifex.PaymentGuardTest do
  use Shopifex.DataCase, async: true
  alias Shopifex.Shops
  alias ShopifexDummy.Shops.{PaymentGuard, Grant}

  setup do
    shop =
      Shops.create_shop(%{
        url: "shopifex-test.myshopify.com",
        scope: "read_inventory,read_products,read_orders",
        access_token: "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"
      })

    {:ok, plan} =
      Shops.create_plan(%{
        name: "Basic",
        price: "1.00",
        grants: ["restricted_feature"],
        features: ["gain access", "wow"]
      })

    {:ok, shop: shop, plan: plan}
  end

  describe "grant_for_guard/1" do
    setup %{plan: plan, shop: shop} do
      {:ok, _grant} = PaymentGuard.create_grant(shop, plan, 123)

      :ok
    end

    test "returns valid grant for guard from database", %{shop: shop} do
      assert %Grant{
               grants: ["restricted_feature"]
             } = PaymentGuard.grant_for_guard(shop, "restricted_feature")
    end

    test "returns nil when no grant present for guard", %{shop: shop} do
      assert PaymentGuard.grant_for_guard(shop, "another_restricted_feature") == nil
    end

    # Regression for the `or_where` precedence bug: a metered grant
    # (`remaining_usages > 0`) belonging to a *different* shop must never satisfy
    # this shop's guard check. The previous query ORed `remaining_usages > 0`
    # against the whole clause, so it matched any shop's metered grant.
    test "does not leak another shop's metered grant", %{shop: shop} do
      other_shop =
        Shops.create_shop(%{
          url: "other-shop.myshopify.com",
          scope: "read_products",
          access_token: "shpat_other_shop_token"
        })

      {:ok, _metered_grant} =
        Shops.create_grant(%{
          shop_id: other_shop.id,
          charge_id: 999,
          grants: ["restricted_feature"],
          remaining_usages: 10,
          total_usages: 0
        })

      # `shop` has only its own (unlimited) grant from the describe-level setup;
      # the metered grant belongs to `other_shop`.
      grant = PaymentGuard.grant_for_guard(shop, "restricted_feature")
      assert grant.shop_id == shop.id

      # And a guard this shop has no grant for must stay nil even though
      # `other_shop` holds a matching metered grant.
      assert PaymentGuard.grant_for_guard(other_shop, "nonexistent_for_other") == nil
    end

    test "supports taking a list of grants instead of a shop as first parameter" do
      assert %Grant{
               grants: ["another_restricted_feature"]
             } =
               PaymentGuard.grant_for_guard(
                 [
                   %Grant{
                     grants: ["another_restricted_feature"],
                     remaining_usages: nil
                   }
                 ],
                 "another_restricted_feature"
               )
    end
  end

  describe "grants_for_shop/1" do
    setup %{plan: plan, shop: shop} do
      {:ok, _grant} = PaymentGuard.create_grant(shop, plan, 123)

      :ok
    end

    test "returns a list of all grants for the provided shop", %{shop: shop} do
      shop_id = shop.id

      [
        %ShopifexDummy.Shops.Grant{
          shop_id: ^shop_id,
          grants: ["restricted_feature"]
        }
      ] = PaymentGuard.grants_for_shop(shop)
    end

    # Regression for the `or_where` precedence bug: every grant returned must
    # belong to the requested shop. A metered grant on another shop previously
    # leaked in through the `remaining_usages > 0` OR branch.
    test "only returns grants belonging to the provided shop", %{shop: shop} do
      other_shop =
        Shops.create_shop(%{
          url: "other-shop.myshopify.com",
          scope: "read_products",
          access_token: "shpat_other_shop_token"
        })

      {:ok, _metered_grant} =
        Shops.create_grant(%{
          shop_id: other_shop.id,
          charge_id: 999,
          grants: ["restricted_feature"],
          remaining_usages: 10,
          total_usages: 0
        })

      grants = PaymentGuard.grants_for_shop(shop)

      assert grants != []
      assert Enum.all?(grants, &(&1.shop_id == shop.id))
    end
  end
end
