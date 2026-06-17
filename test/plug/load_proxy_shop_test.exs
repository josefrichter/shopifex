defmodule Shopifex.Plug.LoadProxyShopTest do
  @moduledoc """
  `LoadProxyShop` resolves the shop from a (signature-verified) app-proxy
  request's `shop` param and exposes it via `Shopifex.Plug.current_shop/1`.
  """
  use Shopifex.DataCase, async: false

  alias Shopifex.Plug.LoadProxyShop
  alias Shopifex.Shops

  defp proxy_conn(params) do
    # A real test adapter is needed because the :halt path calls send_resp/3.
    %{Plug.Test.conn(:get, "/") | params: params}
  end

  setup do
    shop = Shops.create_shop(%{url: "proxy.myshopify.com", scope: "orders", access_token: "t"})
    {:ok, shop: shop}
  end

  test "assigns current_shop from the signed shop param", %{shop: shop} do
    conn = LoadProxyShop.call(proxy_conn(%{"shop" => shop.url}), LoadProxyShop.init([]))

    refute conn.halted
    assert Shopifex.Plug.current_shop(conn).url == shop.url
  end

  test "an unknown shop passes through with current_shop nil by default (:pass)" do
    conn =
      LoadProxyShop.call(proxy_conn(%{"shop" => "ghost.myshopify.com"}), LoadProxyShop.init([]))

    refute conn.halted
    assert Shopifex.Plug.current_shop(conn) == nil
  end

  test "an unknown shop halts with 401 when on_missing: :halt" do
    conn =
      LoadProxyShop.call(
        proxy_conn(%{"shop" => "ghost.myshopify.com"}),
        LoadProxyShop.init(on_missing: :halt)
      )

    assert conn.halted
    assert conn.status == 401
  end

  test "a request with no shop param passes through by default (:pass)" do
    conn = LoadProxyShop.call(proxy_conn(%{}), LoadProxyShop.init([]))

    refute conn.halted
    assert Shopifex.Plug.current_shop(conn) == nil
  end

  test "a request with no shop param halts with 401 when on_missing: :halt" do
    conn = LoadProxyShop.call(proxy_conn(%{}), LoadProxyShop.init(on_missing: :halt))

    assert conn.halted
    assert conn.status == 401
  end
end
