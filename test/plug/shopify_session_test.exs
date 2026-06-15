defmodule Shopifex.Plug.ShopifySessionTest do
  use ShopifexWeb.ConnCase

  test "responds unauthorized when request content type is json" do
    conn =
      build_conn(:get, "?locale=fr")
      |> Map.merge(%{private: %{phoenix_format: "json"}})
      |> Plug.Conn.fetch_query_params()
      |> Shopifex.Plug.ShopifySession.call([])

    assert %{"message" => "Unauthorized"} = json_response(conn, 403)

    assert conn.halted
  end

  describe "authorized requests" do
    setup [:shop_in_session]

    test "locale is placed in session with locale parameter", %{shop: shop} do
      conn =
        build_conn(:get, "?locale=fr")
        |> Plug.Conn.put_req_header("authorization", "Bearer #{valid_session_token(shop.url)}")
        |> Plug.Conn.fetch_query_params()
        |> Shopifex.Plug.ShopifySession.call([])

      assert %ShopifexDummy.Shop{url: "shopifex.myshopify.com"} = Shopifex.Plug.current_shop(conn)
      assert Gettext.get_locale() == "fr"
    end
  end
end
