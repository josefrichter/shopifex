defmodule Shopifex.Plug.HmacTest do
  @moduledoc """
  Security-focused tests for HMAC handling: constant-time comparison, exact
  Base64 case for webhooks, deterministic query-param sorting, query timestamp
  freshness, and that computed HMACs never leak into the logs.
  """
  use Shopifex.DataCase, async: false

  import ExUnit.CaptureLog

  alias Shopifex.Shops
  alias Shopifex.Plug.{ValidateHmac, ShopifyWebhook}

  @secret "shpss_thisisafakesecret"

  # Replicates the library's canonical query HMAC: params sorted alphabetically,
  # signed as lowercase hex.
  defp query_hmac(params, joiner) do
    query_string =
      params
      |> Enum.sort()
      |> Enum.map_join(joiner, fn {k, v} -> "#{k}=#{v}" end)

    :crypto.mac(:hmac, :sha256, @secret, query_string) |> Base.encode16(case: :lower)
  end

  defp get_conn(params) do
    # A real test adapter is needed because the reject path calls send_resp/3.
    %{Plug.Test.conn(:get, "/") | params: params, query_params: params}
  end

  describe "query / app-proxy HMAC (ValidateHmac)" do
    test "accepts a request signed over alphabetically-sorted params with a fresh timestamp" do
      base = %{
        "shop" => "x.myshopify.com",
        "timestamp" => to_string(System.system_time(:second)),
        "code" => "abc",
        "state" => "z"
      }

      params = Map.put(base, "hmac", query_hmac(base, "&"))
      conn = ValidateHmac.call(get_conn(params), [])

      refute conn.halted
    end

    test "rejects a request whose hmac was computed in a non-sorted order" do
      base = %{"b" => "2", "a" => "1", "timestamp" => to_string(System.system_time(:second))}

      # Sign in reverse-sorted order — the plug signs in sorted order, so this must fail.
      wrong =
        base
        |> Enum.sort()
        |> Enum.reverse()
        |> Enum.map_join("&", fn {k, v} -> "#{k}=#{v}" end)

      wrong_hmac = :crypto.mac(:hmac, :sha256, @secret, wrong) |> Base.encode16(case: :lower)

      conn = ValidateHmac.call(get_conn(Map.put(base, "hmac", wrong_hmac)), [])
      assert conn.halted
      assert conn.status == 401
    end

    test "rejects a stale timestamp even when the signature is valid" do
      stale = System.system_time(:second) - 1000
      base = %{"shop" => "x.myshopify.com", "timestamp" => to_string(stale)}
      params = Map.put(base, "hmac", query_hmac(base, "&"))

      conn = ValidateHmac.call(get_conn(params), [])
      assert conn.halted
      assert conn.status == 401
    end

    test "accepts a timestamp inside the configured tolerance" do
      almost_stale = System.system_time(:second) - 80
      base = %{"shop" => "x.myshopify.com", "timestamp" => to_string(almost_stale)}
      params = Map.put(base, "hmac", query_hmac(base, "&"))

      refute ValidateHmac.call(get_conn(params), []).halted
    end

    test "accepts a validly-signed request that omits the timestamp (e.g. bulk-action links)" do
      base = %{"shop" => "x.myshopify.com", "code" => "abc"}
      params = Map.put(base, "hmac", query_hmac(base, "&"))

      refute ValidateHmac.call(get_conn(params), []).halted
    end

    test "rejects a non-integer timestamp even when the signature is valid" do
      base = %{"shop" => "x.myshopify.com", "timestamp" => "not-a-number"}
      params = Map.put(base, "hmac", query_hmac(base, "&"))

      conn = ValidateHmac.call(get_conn(params), [])
      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "webhook HMAC (ShopifyWebhook) — exact Base64 case" do
    setup do
      shop = Shops.create_shop(%{url: "wh.myshopify.com", scope: "orders", access_token: "t"})
      raw = ~s({"id": 99, "topic": "orders/create"})
      hmac = :crypto.mac(:hmac, :sha256, @secret, raw) |> Base.encode64()
      {:ok, shop: shop, raw: raw, hmac: hmac}
    end

    defp webhook_conn(raw, hmac) do
      %{Plug.Test.conn(:post, "/webhook") | params: %{"myshopify_domain" => "wh.myshopify.com"}}
      |> Plug.Conn.assign(:raw_body, raw)
      |> Plug.Conn.put_req_header("x-shopify-hmac-sha256", hmac)
    end

    test "accepts the exact Base64 digest and builds the session", %{raw: raw, hmac: hmac} do
      conn = ShopifyWebhook.call(webhook_conn(raw, hmac), [])

      refute conn.halted
      assert Shopifex.Plug.current_shop(conn).url == "wh.myshopify.com"
    end

    test "rejects a case-mutated Base64 digest (Base64 is case-significant)", %{
      raw: raw,
      hmac: hmac
    } do
      mutated =
        if hmac == String.downcase(hmac), do: String.upcase(hmac), else: String.downcase(hmac)

      assert mutated != hmac, "expected the test digest to contain mixed-case characters"

      conn = ShopifyWebhook.call(webhook_conn(raw, mutated), [])
      assert conn.halted
      assert conn.status == 401
    end

    test "rejects a missing/garbage HMAC header", %{raw: raw} do
      conn = ShopifyWebhook.call(webhook_conn(raw, "not-the-hmac"), [])
      assert conn.halted
      assert conn.status == 401
    end
  end

  describe "HMAC failures do not leak the computed secret into logs" do
    setup do
      # The failure logs are emitted at :info; the test config gates at :warn,
      # so lower the primary level for these assertions (restored afterwards).
      previous = Logger.level()
      Logger.configure(level: :info)
      on_exit(fn -> Logger.configure(level: previous) end)
      :ok
    end

    test "ValidateHmac logs a generic failure, never the expected HMAC" do
      base = %{"shop" => "x.myshopify.com", "timestamp" => to_string(System.system_time(:second))}
      conn = get_conn(Map.put(base, "hmac", "deadbeef"))
      expected = Shopifex.Plug.build_hmac(conn)

      log =
        capture_log([level: :info], fn ->
          assert ValidateHmac.call(conn, []).halted
        end)

      refute log =~ expected
      assert log =~ "invalid HMAC"
    end

    test "ShopifyWebhook logs a generic failure, never the expected HMAC" do
      conn =
        %{Plug.Test.conn(:post, "/webhook") | params: %{"myshopify_domain" => "wh.myshopify.com"}}
        |> Plug.Conn.assign(:raw_body, ~s({"a": 1}))
        |> Plug.Conn.put_req_header("x-shopify-hmac-sha256", "wrong")

      expected = Shopifex.Plug.build_hmac(conn)

      log =
        capture_log([level: :info], fn ->
          assert ShopifyWebhook.call(conn, []).halted
        end)

      refute log =~ expected
      assert log =~ "invalid HMAC"
    end
  end
end
