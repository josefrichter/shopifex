defmodule Shopifex.Plug.EnsureScopesTest do
  use ShopifexWeb.ConnCase

  setup do
    conn = build_conn(:get, "/my-route?foo=bar&fizz=buzz")
    {:ok, conn: conn}
  end

  setup [:shop_in_session]

  test "shop scopes matching shopifex config passes plug", %{
    conn: conn
  } do
    shop = Shopifex.Plug.current_shop(conn)
    Application.put_env(:shopifex, :scopes, shop.scope)

    conn = Shopifex.Plug.EnsureScopes.call(conn, [])

    refute conn.halted
  end

  test "raises an actionable error by default when scopes are missing", %{conn: conn} do
    assert_raise Shopifex.RuntimeError, ~r/missing required scopes/, fn ->
      Shopifex.Plug.EnsureScopes.call(conn, required_scopes: "read_orders")
    end
  end

  test "renders redirect page with location to Shopify OAuth update flow when opted in", %{
    conn: conn
  } do
    conn =
      Shopifex.Plug.EnsureScopes.call(conn,
        required_scopes: "read_orders",
        on_missing_scopes: :redirect
      )

    assert conn.halted
    assert html_response(conn, 200) =~ "Redirecting"

    assert conn.assigns.redirect_location =~
             "https://shopifex.myshopify.com/admin/oauth/authorize?client_id=thisisafakeapikey"
  end

  test "renders redirect page with exactly one doctype even when root layout is set", %{
    conn: conn
  } do
    defmodule DummyRootLayout do
      use Phoenix.Component

      def root(assigns) do
        ~H"""
        <!DOCTYPE html>
        <html>
          <body>{@inner_content}</body>
        </html>
        """
      end
    end

    conn =
      conn
      |> Phoenix.Controller.put_root_layout(html: {DummyRootLayout, :root})
      |> Shopifex.Plug.EnsureScopes.call(
        required_scopes: "read_orders",
        on_missing_scopes: :redirect
      )

    body = html_response(conn, 200)
    assert length(Regex.scan(~r/<!DOCTYPE html>/i, body)) == 1
  end

  test "throws error when shop not in session", %{
    conn: conn
  } do
    assert_raise Shopifex.RuntimeError, fn ->
      conn
      |> Map.put(:private, %{})
      |> Shopifex.Plug.EnsureScopes.call([])
    end
  end
end
