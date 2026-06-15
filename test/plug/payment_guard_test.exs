defmodule Shopifex.Plug.PaymentGuardTest do
  use ShopifexWeb.ConnCase

  setup do
    conn = build_conn(:get, "/premium-route?foo=bar&fizz=buzz")
    {:ok, conn: conn}
  end

  setup [:shop_in_session]

  test "payment guard blocks pay-walled function and redirects to payment page with session token",
       %{
         conn: conn
       } do
    halted_conn = Shopifex.Plug.PaymentGuard.call(conn, "block")

    assert html_response(halted_conn, 302) =~
             "<html><body>You are being <a href=\"/payment/show-plans?"

    [redirect_location] = Plug.Conn.get_resp_header(halted_conn, "location")

    conn_follow_redirect = get(Phoenix.ConnTest.build_conn(), redirect_location)

    assert Shopifex.Plug.session_token(conn_follow_redirect)
    assert html_response(conn_follow_redirect, 200) =~ "Payment options"
  end

  test "show-plans escapes a malicious redirect_after (no inline-script breakout)", %{conn: conn} do
    payload = "</script><script>window.__xss=1</script>"

    conn =
      get(
        conn,
        "/payment/show-plans?guard_identifier=block&redirect_after=" <>
          URI.encode_www_form(payload)
      )

    body = html_response(conn, 200)
    # The raw </script><script> breakout must NOT appear...
    refute body =~ "<script>window.__xss"
    refute body =~ "</script><script>"
    # ...because `<` is emitted as the HTML-safe JSON escape <.
    assert body =~ "\\u003Cscript"
  end

  test "payment guard grants access pay-walled function and places guard payment in session", %{
    conn: conn,
    shop: shop
  } do
    Shopifex.Shops.create_grant(%{shop_id: shop.id, grants: ["premium_access"]})

    conn = Shopifex.Plug.PaymentGuard.call(conn, "premium_access")

    assert %ShopifexDummy.Shops.Grant{grants: ["premium_access"]} = conn.private.grant_for_guard
  end
end
