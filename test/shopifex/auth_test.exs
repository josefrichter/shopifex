defmodule Shopifex.AuthTest do
  use Shopifex.DataCase, async: false

  alias Shopifex.{Auth, Shops}

  defp token_response(opts \\ []) do
    %{
      "access_token" => Keyword.get(opts, :access_token, "new_access_token"),
      "scope" => Keyword.get(opts, :scope, "read_orders"),
      "expires_in" => Keyword.get(opts, :expires_in, 3600),
      "refresh_token" => Keyword.get(opts, :refresh_token, "new_refresh_token"),
      "refresh_token_expires_in" => Keyword.get(opts, :refresh_token_expires_in, 7_776_000)
    }
  end

  defp soon, do: DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:second)
  defp later, do: DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

  describe "ensure_fresh_token/1" do
    test "is a no-op when token_expires_at is nil (legacy / non-expiring install)" do
      shop =
        Shops.create_shop(%{
          url: "legacy.myshopify.com",
          scope: "read_orders",
          access_token: "legacy_token"
        })

      assert Auth.ensure_fresh_token(shop) == shop
    end

    test "returns the shop unchanged when the token is comfortably fresh" do
      shop =
        Shops.create_shop(%{
          url: "fresh.myshopify.com",
          scope: "read_orders",
          access_token: "tok",
          token_expires_at: later(),
          refresh_token: "rt"
        })

      assert Auth.ensure_fresh_token(shop).access_token == "tok"
    end

    test "proactively refreshes when the token is within the safety window" do
      Req.Test.stub(Shopifex.ReqStub, fn conn -> Req.Test.json(conn, token_response()) end)

      shop =
        Shops.create_shop(%{
          url: "soon.myshopify.com",
          scope: "read_orders",
          access_token: "old",
          token_expires_at: soon(),
          refresh_token: "rt"
        })

      refreshed = Auth.ensure_fresh_token(shop)
      assert refreshed.access_token == "new_access_token"
      assert refreshed.refresh_token == "new_refresh_token"
    end
  end

  describe "refresh!/1" do
    test "persists all four token fields from the grant response" do
      Req.Test.stub(Shopifex.ReqStub, fn conn -> Req.Test.json(conn, token_response()) end)

      shop =
        Shops.create_shop(%{
          url: "r.myshopify.com",
          scope: "read_orders",
          access_token: "old",
          token_expires_at: soon(),
          refresh_token: "rt"
        })

      assert {:ok, refreshed} = Auth.refresh!(shop)
      assert refreshed.access_token == "new_access_token"
      assert refreshed.refresh_token == "new_refresh_token"
      assert %DateTime{} = refreshed.token_expires_at
      assert %DateTime{} = refreshed.refresh_token_expires_at
    end

    test "tolerates a non-expiring grant response (nil expiry columns)" do
      Req.Test.stub(Shopifex.ReqStub, fn conn ->
        Req.Test.json(conn, %{"access_token" => "plain_token", "scope" => "read_orders"})
      end)

      shop =
        Shops.create_shop(%{
          url: "plain.myshopify.com",
          scope: "read_orders",
          access_token: "old",
          token_expires_at: soon(),
          refresh_token: "rt"
        })

      assert {:ok, refreshed} = Auth.refresh!(shop)
      assert refreshed.access_token == "plain_token"
      assert is_nil(refreshed.token_expires_at)
      assert is_nil(refreshed.refresh_token)
    end

    test "returns {:error, :no_refresh_token} when the shop has no refresh_token" do
      shop =
        Shops.create_shop(%{
          url: "n.myshopify.com",
          scope: "read_orders",
          access_token: "old",
          token_expires_at: soon()
        })

      assert {:error, :no_refresh_token} = Auth.refresh!(shop)
    end

    test "returns {:error, {:refresh_failed, status}} when Shopify rejects the grant" do
      Req.Test.stub(Shopifex.ReqStub, fn conn ->
        conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})
      end)

      shop =
        Shops.create_shop(%{
          url: "bad.myshopify.com",
          scope: "read_orders",
          access_token: "old",
          token_expires_at: soon(),
          refresh_token: "expired_rt"
        })

      assert {:error, {:refresh_failed, 400}} = Auth.refresh!(shop)
    end

    test "second caller observes the first caller's fresh token without re-hitting Shopify" do
      # Pre-write a fresh token as if a concurrent caller already refreshed,
      # then call refresh!/1 with a stale in-memory copy. The FOR UPDATE branch
      # should short-circuit and return the locked (fresh) row.
      shop =
        Shops.create_shop(%{
          url: "concurrent.myshopify.com",
          scope: "read_orders",
          access_token: "stale",
          token_expires_at: soon(),
          refresh_token: "rt"
        })

      _ = Shops.update_shop(shop, %{access_token: "already_fresh", token_expires_at: later()})

      # No Req.Test stub registered → if this tried to hit Shopify it would raise.
      assert {:ok, observed} = Auth.refresh!(shop)
      assert observed.access_token == "already_fresh"
    end
  end
end
