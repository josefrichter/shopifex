defmodule Shopifex.Plug.ManagedInstallTest.Callbacks do
  @moduledoc false
  use Shopifex.ManagedInstall.Callbacks

  @impl true
  def after_install(shop) do
    case Application.get_env(:shopifex, :managed_install_test_pid) do
      pid when is_pid(pid) -> send(pid, {:after_install, shop})
      _ -> :ok
    end

    :ok
  end
end

defmodule Shopifex.Plug.ManagedInstallTest.OverrideCallbacks do
  @moduledoc false
  use Shopifex.ManagedInstall.Callbacks

  # Signals invocation AND stamps a marker onto the persisted record so the test
  # can prove the override's return value (not the default create_shop) is what
  # flows into the session / webhooks / after_install.
  @impl true
  def insert_shop(attrs) do
    case Application.get_env(:shopifex, :managed_install_test_pid) do
      pid when is_pid(pid) -> send(pid, {:insert_shop, attrs})
      _ -> :ok
    end

    Shopifex.Shops.create_shop(%{attrs | access_token: "OVERRIDDEN-" <> attrs.access_token})
  end
end

defmodule Shopifex.Plug.ManagedInstallTest do
  use Shopifex.DataCase, async: false

  import Ecto.Query
  alias Shopifex.Shops
  alias Shopifex.Plug.ManagedInstall

  @secret "shpss_thisisafakesecret"
  @api_key "thisisafakeapikey"
  @shop "managed-install.myshopify.com"

  setup do
    Application.put_env(:shopifex, :managed_install_test_pid, self())

    Application.put_env(
      :shopifex,
      :managed_install_callbacks,
      Shopifex.Plug.ManagedInstallTest.Callbacks
    )

    on_exit(fn ->
      Application.delete_env(:shopifex, :managed_install_test_pid)
      Application.delete_env(:shopifex, :managed_install_callbacks)
    end)

    :ok
  end

  # --- helpers ---------------------------------------------------------------

  defp sign(claims) do
    jwk = JOSE.JWK.from_oct(@secret)
    {_, token} = JOSE.JWT.sign(jwk, %{"alg" => "HS256"}, claims) |> JOSE.JWS.compact()
    token
  end

  defp token(overrides \\ %{}) do
    now = System.system_time(:second)

    Map.merge(
      %{
        "dest" => "https://#{@shop}",
        "iss" => "https://#{@shop}/admin",
        "aud" => @api_key,
        "exp" => now + 60,
        "nbf" => now - 10,
        "iat" => now
      },
      overrides
    )
    |> sign()
  end

  defp conn_with(params), do: %Plug.Conn{params: params}

  defp token_exchange_response do
    %{
      "access_token" => "offline_access_token",
      "scope" => "read_orders",
      "expires_in" => 3600,
      "refresh_token" => "offline_refresh_token",
      "refresh_token_expires_in" => 7_776_000
    }
  end

  # One stub for the whole managed-install round trip: the RFC 8693 token
  # exchange (POST /admin/oauth/access_token) plus the GraphQL webhook
  # configuration. Notifies the test process so we can assert what ran.
  defp stub_shopify do
    parent = self()

    Req.Test.stub(Shopifex.ReqStub, fn conn ->
      if String.ends_with?(conn.request_path, "/admin/oauth/access_token") do
        send(parent, :token_exchanged)
        Req.Test.json(conn, token_exchange_response())
      else
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        query = Jason.decode!(body)["query"]

        if query =~ "webhookSubscriptionCreate" do
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
  end

  defp backdate_shop!(shop, seconds_ago) do
    old = NaiveDateTime.utc_now() |> NaiveDateTime.add(-seconds_ago, :second)

    Shops.repo().update_all(from(s in Shops.shop_schema(), where: s.id == ^shop.id),
      set: [updated_at: old]
    )
  end

  # --- new shop --------------------------------------------------------------

  test "new shop: exchanges id_token, persists the full token lifecycle, configures webhooks, invokes after_install, builds session" do
    stub_shopify()

    conn =
      ManagedInstall.call(conn_with(%{"id_token" => token(), "shop" => @shop, "host" => "h"}), [])

    assert_received :token_exchanged
    assert_received :webhook_created
    assert_received {:after_install, _shop}

    shop = Shops.get_shop_by_url(@shop)
    assert shop.access_token == "offline_access_token"
    assert %DateTime{} = shop.token_expires_at
    assert shop.refresh_token == "offline_refresh_token"
    assert %DateTime{} = shop.refresh_token_expires_at

    assert Shopifex.Plug.current_shop(conn).url == @shop
  end

  test "new shop honors a custom insert_shop/1 override, whose return value flows into the session" do
    Application.put_env(
      :shopifex,
      :managed_install_callbacks,
      Shopifex.Plug.ManagedInstallTest.OverrideCallbacks
    )

    stub_shopify()

    conn = ManagedInstall.call(conn_with(%{"id_token" => token(), "shop" => @shop}), [])

    # The override ran (not the default create_shop)...
    assert_received {:insert_shop, _attrs}
    # ...and the record it returned is what was persisted and put in the session.
    assert Shopifex.Plug.current_shop(conn).access_token == "OVERRIDDEN-offline_access_token"
    assert Shops.get_shop_by_url(@shop).access_token == "OVERRIDDEN-offline_access_token"
  end

  # --- existing fresh shop ---------------------------------------------------

  test "existing fresh shop: builds the session without a token exchange" do
    Shops.create_shop(%{
      url: @shop,
      scope: "read_orders",
      access_token: "existing_token",
      token_expires_at:
        DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second),
      refresh_token: "existing_refresh"
    })

    conn =
      ManagedInstall.call(conn_with(%{"id_token" => token(), "shop" => @shop, "host" => "h"}), [])

    refute_received :token_exchanged
    refute_received {:after_install, _}
    assert Shopifex.Plug.current_shop(conn).access_token == "existing_token"
  end

  # --- existing stale shop ---------------------------------------------------

  test "existing stale shop: re-exchanges, refreshes lifecycle fields, reconciles webhooks, but skips install hooks" do
    shop =
      Shops.create_shop(%{
        url: @shop,
        scope: "read_orders",
        access_token: "stale_token",
        token_expires_at:
          DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:second),
        refresh_token: "stale_refresh"
      })

    # Older than the 50-minute staleness window.
    backdate_shop!(shop, 60 * 60)
    stub_shopify()

    conn =
      ManagedInstall.call(conn_with(%{"id_token" => token(), "shop" => @shop, "host" => "h"}), [])

    assert_received :token_exchanged
    # A re-exchange reconciles webhooks (idempotent self-healing)...
    assert_received :webhook_created
    # ...but must NOT re-run install hooks.
    refute_received {:after_install, _}

    refreshed = Shops.get_shop_by_url(@shop)
    assert refreshed.access_token == "offline_access_token"
    assert refreshed.refresh_token == "offline_refresh_token"
    assert Shopifex.Plug.current_shop(conn).access_token == "offline_access_token"
  end

  # --- invalid / expired / missing tokens ------------------------------------

  test "invalid id_token: no-op (no exchange, no shop in session)" do
    conn = ManagedInstall.call(conn_with(%{"id_token" => "not-a-jwt", "shop" => @shop}), [])

    refute_received :token_exchanged
    assert Shopifex.Plug.current_shop(conn) == nil
    assert Shops.get_shop_by_url(@shop) == nil
  end

  test "expired id_token: no-op (falls through for App Bridge to retry with a fresh token)" do
    expired = token(%{"exp" => System.system_time(:second) - 120})

    conn = ManagedInstall.call(conn_with(%{"id_token" => expired, "shop" => @shop}), [])

    refute_received :token_exchanged
    assert Shopifex.Plug.current_shop(conn) == nil
  end

  test "no id_token: passes the conn through untouched" do
    conn = ManagedInstall.call(conn_with(%{"shop" => @shop}), [])

    refute_received :token_exchanged
    assert Shopifex.Plug.current_shop(conn) == nil
  end
end
