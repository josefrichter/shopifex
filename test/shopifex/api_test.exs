defmodule Shopifex.APITest do
  use Shopifex.DataCase, async: false

  alias Shopifex.{API, Shops}

  setup do
    shop =
      Shops.create_shop(%{
        url: "api.myshopify.com",
        scope: "read_orders",
        access_token: "tok"
      })

    {:ok, shop: shop}
  end

  test "returns {:ok, data} on a successful GraphQL response", %{shop: shop} do
    Req.Test.stub(Shopifex.ReqStub, fn conn ->
      Req.Test.json(conn, %{"data" => %{"shop" => %{"name" => "Test Shop"}}})
    end)

    assert {:ok, %{"shop" => %{"name" => "Test Shop"}}} = API.graphql(shop, "{ shop { name } }")
  end

  test "errors take precedence even when data is present", %{shop: shop} do
    Req.Test.stub(Shopifex.ReqStub, fn conn ->
      Req.Test.json(conn, %{
        "data" => %{"shop" => nil},
        "errors" => [%{"message" => "Access denied"}]
      })
    end)

    assert {:error, [%{"message" => "Access denied"}]} = API.graphql(shop, "{ shop { name } }")
  end

  test "uses the configured API version in the request URL", %{shop: shop} do
    parent = self()

    Req.Test.stub(Shopifex.ReqStub, fn conn ->
      send(parent, {:request_path, conn.request_path})
      Req.Test.json(conn, %{"data" => %{}})
    end)

    API.graphql(shop, "{ shop { name } }")
    assert_received {:request_path, path}
    assert path == "/admin/api/#{API.api_version()}/graphql.json"
  end

  test "reactively refreshes once on 401 and retries the request" do
    shop =
      Shops.create_shop(%{
        url: "retry.myshopify.com",
        scope: "read_orders",
        access_token: "stale",
        # comfortably fresh so ensure_fresh_token does NOT proactively refresh —
        # the only refresh comes from the reactive 401 path.
        token_expires_at:
          DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second),
        refresh_token: "rt"
      })

    graphql_calls = :counters.new(1, [:atomics])

    Req.Test.stub(Shopifex.ReqStub, fn conn ->
      cond do
        String.contains?(conn.request_path, "/admin/oauth/access_token") ->
          Req.Test.json(conn, %{
            "access_token" => "fresh",
            "scope" => "read_orders",
            "expires_in" => 3600,
            "refresh_token" => "rt2",
            "refresh_token_expires_in" => 7_776_000
          })

        true ->
          n = :counters.get(graphql_calls, 1)
          :counters.add(graphql_calls, 1, 1)

          if n == 0 do
            conn |> Plug.Conn.put_status(401) |> Req.Test.json(%{})
          else
            Req.Test.json(conn, %{"data" => %{"ok" => true}})
          end
      end
    end)

    assert {:ok, %{"ok" => true}} = API.graphql(shop, "{ ok }")
  end
end
