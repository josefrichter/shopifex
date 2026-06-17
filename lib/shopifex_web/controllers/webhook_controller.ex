defmodule ShopifexWeb.WebhookController do
  @moduledoc """
  You can use this module inside of another one of your application controllers.
  The conn, shop and topic will be called by handle_topic/3 which you can define in your parent controller.

  Example:

  ```elixir
  use ShopifexWeb.WebhookController

  def handle_topic(conn, shop, "app/uninstalled") do
    Shopifex.Shops.delete_shop(shop)

    conn
    |> send_resp(200, "success")
  end

  # Mandatory Shopify shop data erasure GDPR webhook. Simply delete the shop record
  def handle_topic(conn, shop, "shop/redact") do
    Shopifex.Shops.delete_shop(shop)

    conn
    |> send_resp(204, "")
  end

  # Mandatory Shopify customer data erasure GDPR webhook. Simply delete the shop (customer) record
  def handle_topic(conn, shop, "customers/redact") do
    Shopifex.Shops.delete_shop(shop)

    conn
    |> send_resp(204, "")
  end

  # Mandatory Shopify customer data request GDPR webhook.
  def handle_topic(conn, _shop, "customers/data_request") do
    # Send an email of the shop data to the customer.
    conn
    |> send_resp(202, "Accepted")
  end
  ```
  """
  defmacro __using__(_opts) do
    quote do
      plug(:assign_shopify_topic)

      # Every genuine Shopify webhook carries exactly one `x-shopify-topic`
      # header, but pattern-matching `[topic]` raised a `MatchError` (→ 500) on a
      # missing or duplicated header. Fail closed with a 400 instead so a
      # malformed request can't crash the endpoint.
      defp assign_shopify_topic(conn, _) do
        case Plug.Conn.get_req_header(conn, "x-shopify-topic") do
          [topic] ->
            Plug.Conn.assign(conn, :shopify_topic, topic)

          _ ->
            require Logger
            Logger.info("Rejecting webhook with missing or duplicate x-shopify-topic header")

            conn
            |> Plug.Conn.send_resp(400, "missing x-shopify-topic header")
            |> Plug.Conn.halt()
        end
      end

      def action(conn, _),
        do: handle_topic(conn, Shopifex.Plug.current_shop(conn), conn.assigns[:shopify_topic])

      # Default handlers for Shopify's mandatory compliance (GDPR) webhooks.
      # These satisfy app-review requirements out of the box: `shop/redact`
      # deletes the shop record, the customer topics acknowledge with 200.
      #
      # `handle_topic/3` is `defoverridable`, so apps can replace these. If you
      # define your own `handle_topic/3` clauses you replace ALL of them — add a
      # catch-all that calls `super(conn, shop, topic)` if you want to keep these
      # compliance defaults.
      def handle_topic(conn, _shop, "customers/data_request"),
        do: Plug.Conn.send_resp(conn, 200, "")

      def handle_topic(conn, _shop, "customers/redact"),
        do: Plug.Conn.send_resp(conn, 200, "")

      def handle_topic(conn, shop, "shop/redact") do
        if shop, do: Shopifex.Shops.delete_shop(shop)
        Plug.Conn.send_resp(conn, 200, "")
      end

      defoverridable handle_topic: 3
    end
  end
end
