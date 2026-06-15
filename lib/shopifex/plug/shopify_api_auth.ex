defmodule Shopifex.Plug.ShopifyApiAuth do
  @moduledoc """
  Authenticates async API requests from an embedded SPA front end using the
  Shopify App Bridge session token.

  The front end attaches the token Shopify gives it (via `app-bridge`'s
  `getSessionToken`/`idToken`) as an `Authorization: Bearer <token>` header.
  This plug verifies it with `Shopifex.SessionToken`, resolves the shop, and
  builds the Shopifex session so controllers can call
  `Shopifex.Plug.current_shop/1`. On failure it responds `401` and halts.

  Used by the `:shopify_api` / `:shopifex_api` pipelines. Replaces the
  Guardian-based pipeline used in Shopifex v2.
  """

  import Plug.Conn
  require Logger

  def init(opts), do: opts

  def call(conn, _opts) do
    with token when is_binary(token) <- Shopifex.Plug.session_token(conn),
         {:ok, %{"dest" => "https://" <> shop_url}} <- Shopifex.SessionToken.verify(token),
         shop when not is_nil(shop) <- Shopifex.Shops.get_shop_by_url(shop_url) do
      Shopifex.Plug.build_session(conn, shop, conn.params["host"], conn.params["locale"] || "en")
    else
      _ ->
        conn
        |> put_status(:unauthorized)
        |> Phoenix.Controller.json(%{error: "unauthorized", status: 401})
        |> halt()
    end
  end
end
