defmodule Mix.Shopifex.MigrationTest do
  use ExUnit.Case, async: true

  test "fresh-install migration includes the token refresh lease table" do
    migration =
      Mix.Shopifex.Migration.gen("CreateShopifyTables", "shopify", %{
        repo: ShopifexDummy.Repo,
        binary_id: false
      })

    assert migration =~ "create table(:shopifex_token_refresh_leases, primary_key: false)"
    assert migration =~ "add :shop_url, :string, primary_key: true"
    assert migration =~ "add :owner, :string, null: false"
    assert migration =~ "add :lease_expires_at, :utc_datetime_usec, null: false"
  end
end
