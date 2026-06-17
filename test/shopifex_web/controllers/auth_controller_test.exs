defmodule ShopifexWeb.AuthControllerTest do
  use ShopifexWeb.ConnCase, async: true

  test "new shop is redirected to install", %{conn: conn} do
    # Ensure it works with and without trailing slash
    shop_urls = [
      "shopifex.myshopify.com",
      "shopifex.myshopify.com/"
    ]

    for shop_url <- shop_urls do
      conn =
        get(conn, Routes.auth_path(@endpoint, :initialize_installation), %{
          "shop" => shop_url
        })

      assert conn.status == 302
      [location] = Plug.Conn.get_resp_header(conn, "location")
      assert location =~ "https://shopifex.myshopify.com/admin/oauth/authorize"
    end
  end

  test "locale is an optional parameter in auth flow", %{conn: conn} do
    query =
      %{
        "shop" => "shopifex.myshopify.com",
        "hmac" => "E0D42CC61A5D3A685D3A7AE652E5BFB0F6D05DDDBE446CA6AC496FFA3FA5488B"
      }
      |> URI.encode_query()

    conn = get(conn, Routes.auth_path(@endpoint, :auth) <> "?#{query}")

    [location] = Plug.Conn.get_resp_header(conn, "location")

    assert location ==
             "https://shopifex.myshopify.com/admin/oauth/authorize?client_id=thisisafakeapikey&scope=orders&redirect_uri=https://shopifex-dummy.com/auth/install"

    assert conn.status == 302
  end

  test "store selector is rendered with a flash error if an invalid url is passed", %{conn: conn} do
    conn =
      get(conn, Routes.auth_path(@endpoint, :initialize_installation), %{
        "shop" => "invalid.shopify.url"
      })

    body = html_response(conn, 200)
    assert body =~ "Install"
    assert body =~ "Invalid shop URL"
  end

  describe "managed installation through the generated /auth route" do
    setup do
      parent = self()

      # Stub the whole round trip: RFC 8693 token exchange (scope matches the
      # configured `:scopes` so the :shopify_session pipeline's EnsureScopes
      # passes) plus GraphQL webhook configuration.
      Req.Test.stub(Shopifex.ReqStub, fn conn ->
        if String.ends_with?(conn.request_path, "/admin/oauth/access_token") do
          Req.Test.json(conn, %{
            "access_token" => "integration_token",
            "scope" => "orders",
            "expires_in" => 3600,
            "refresh_token" => "integration_refresh",
            "refresh_token_expires_in" => 7_776_000
          })
        else
          {:ok, body, conn} = Plug.Conn.read_body(conn)

          if Jason.decode!(body)["query"] =~ "webhookSubscriptionCreate" do
            send(parent, :webhook_created)

            Req.Test.json(conn, %{
              "data" => %{
                "webhookSubscriptionCreate" => %{
                  "webhookSubscription" => %{"id" => "gid://shopify/WebhookSubscription/1"},
                  "userErrors" => []
                }
              }
            })
          else
            Req.Test.json(conn, %{"data" => %{"webhookSubscriptions" => %{"edges" => []}}})
          end
        end
      end)

      :ok
    end

    test "GET /auth?id_token=...&shop=... installs the shop and lands in the app", %{conn: conn} do
      shop_url = "integration.myshopify.com"
      id_token = valid_session_token(shop_url)

      query =
        URI.encode_query(%{"id_token" => id_token, "shop" => shop_url, "host" => "aG9zdA=="})

      conn = get(conn, Routes.auth_path(@endpoint, :auth) <> "?#{query}")

      # auth/2 redirects to the app root, carrying the embedded-context params
      # (shop/host/id_token) so App Bridge can re-initialize on the landing page
      # and the landing route's :shopify_session can authenticate the hop.
      location = redirected_to(conn)
      assert %URI{path: "/", query: redirect_query} = URI.parse(location)
      redirect_params = URI.decode_query(redirect_query)
      assert redirect_params["shop"] == shop_url
      assert redirect_params["host"] == "aG9zdA=="
      assert redirect_params["id_token"] == id_token

      # Webhooks are configured on first install, end-to-end through the pipeline.
      assert_received :webhook_created

      shop = Shopifex.Shops.get_shop_by_url(shop_url)
      assert shop.access_token == "integration_token"
      assert shop.scope == "orders"
      assert shop.refresh_token == "integration_refresh"
    end
  end
end
