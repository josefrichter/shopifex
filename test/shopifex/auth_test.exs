defmodule Shopifex.AuthTest do
  use Shopifex.DataCase, async: false

  alias Shopifex.{Auth, Shops}

  setup do
    {:ok, task_supervisor: start_supervised!(Task.Supervisor)}
  end

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
      # then call refresh!/1 with a stale in-memory copy. The initial reload
      # should short-circuit and return the fresh row.
      shop =
        Shops.create_shop(%{
          url: "concurrent.myshopify.com",
          scope: "read_orders",
          access_token: "stale",
          token_expires_at: soon(),
          refresh_token: "rt"
        })

      _ =
        Shops.update_shop(shop, %{
          access_token: "stale",
          token_expires_at: later(),
          refresh_token: "already_rotated"
        })

      # No Req.Test stub registered → if this tried to hit Shopify it would raise.
      assert {:ok, observed} = Auth.refresh!(shop)
      assert observed.access_token == "stale"
      assert observed.refresh_token == "already_rotated"
    end

    test "serializes concurrent refreshes without reusing a one-time token", %{
      task_supervisor: task_supervisor
    } do
      test_pid = self()

      Req.Test.stub(Shopifex.ReqStub, fn conn ->
        send(test_pid, {:refresh_request, self()})

        receive do
          :release_refresh -> Req.Test.json(conn, token_response())
        end
      end)

      shop =
        Shops.create_shop(%{
          url: "serialized.myshopify.com",
          scope: "read_orders",
          access_token: "old",
          token_expires_at: soon(),
          refresh_token: "single_use_rt"
        })

      first = start_refresh_task(task_supervisor, shop)
      assert_receive {:refresh_request, request_pid}, 1_000

      second = start_refresh_task(task_supervisor, shop)
      refute_receive {:refresh_request, _pid}, 100

      send(request_pid, :release_refresh)

      assert {:ok, first_shop} = task_result(first)
      assert {:ok, second_shop} = task_result(second)
      assert first_shop.access_token == "new_access_token"
      assert second_shop.access_token == "new_access_token"
      assert first_shop.refresh_token == "new_refresh_token"
      assert second_shop.refresh_token == "new_refresh_token"
      refute_receive {:refresh_request, _pid}, 100
    end

    test "does not hold a shop-row lock while waiting for Shopify", %{
      task_supervisor: task_supervisor
    } do
      test_pid = self()

      Req.Test.stub(Shopifex.ReqStub, fn conn ->
        send(test_pid, {:refresh_request, self()})

        receive do
          :release_refresh -> Req.Test.json(conn, Map.delete(token_response(), "scope"))
        end
      end)

      shop =
        Shops.create_shop(%{
          url: "unlocked.myshopify.com",
          scope: "read_orders",
          access_token: "old",
          token_expires_at: soon(),
          refresh_token: "rt"
        })

      refresh_task = start_refresh_task(task_supervisor, shop)
      assert_receive {:refresh_request, request_pid}, 1_000

      update_task =
        start_task(task_supervisor, fn ->
          Shops.update_shop(shop, %{scope: "write_orders"})
        end)

      updated = task_result(update_task)
      assert updated.scope == "write_orders"

      send(request_pid, :release_refresh)

      assert {:ok, refreshed} = task_result(refresh_task)
      assert refreshed.scope == "write_orders"
      assert refreshed.access_token == "new_access_token"
    end

    test "does not overwrite a newer managed-install token pair", %{
      task_supervisor: task_supervisor
    } do
      test_pid = self()

      Req.Test.stub(Shopifex.ReqStub, fn conn ->
        send(test_pid, {:refresh_request, self()})

        receive do
          :release_refresh -> Req.Test.json(conn, token_response())
        end
      end)

      shop =
        Shops.create_shop(%{
          url: "managed-wins.myshopify.com",
          scope: "read_orders",
          access_token: "old",
          token_expires_at: soon(),
          refresh_token: "old_rt"
        })

      refresh_task = start_refresh_task(task_supervisor, shop)
      assert_receive {:refresh_request, request_pid}, 1_000

      managed_expires_at = later()

      managed_shop =
        Shops.update_shop(shop, %{
          access_token: "managed_access",
          token_expires_at: managed_expires_at,
          refresh_token: "managed_refresh",
          refresh_token_expires_at: DateTime.add(managed_expires_at, 86_400, :second)
        })

      send(request_pid, :release_refresh)

      assert {:ok, observed} = task_result(refresh_task)
      assert observed.access_token == "managed_access"
      assert observed.refresh_token == "managed_refresh"

      persisted = Repo.get!(ShopifexDummy.Shop, managed_shop.id)
      assert persisted.access_token == "managed_access"
      assert persisted.refresh_token == "managed_refresh"
    end

    test "releases its lease after Shopify rejects the refresh" do
      Req.Test.stub(Shopifex.ReqStub, fn conn ->
        conn |> Plug.Conn.put_status(400) |> Req.Test.json(%{"error" => "invalid_grant"})
      end)

      shop =
        Shops.create_shop(%{
          url: "retry-after-failure.myshopify.com",
          scope: "read_orders",
          access_token: "old",
          token_expires_at: soon(),
          refresh_token: "rt"
        })

      assert {:error, {:refresh_failed, 400}} = Auth.refresh!(shop)
      assert Repo.aggregate("shopifex_token_refresh_leases", :count) == 0

      Req.Test.stub(Shopifex.ReqStub, fn conn -> Req.Test.json(conn, token_response()) end)

      assert {:ok, refreshed} = Auth.refresh!(shop)
      assert refreshed.access_token == "new_access_token"
    end

    test "returns refresh_in_progress when the lease wait deadline is exhausted" do
      previous = Application.fetch_env(:shopifex, :token_refresh_wait_timeout_ms)
      Application.put_env(:shopifex, :token_refresh_wait_timeout_ms, 0)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:shopifex, :token_refresh_wait_timeout_ms, value)
          :error -> Application.delete_env(:shopifex, :token_refresh_wait_timeout_ms)
        end
      end)

      shop =
        Shops.create_shop(%{
          url: "busy.myshopify.com",
          scope: "read_orders",
          access_token: "old",
          token_expires_at: soon(),
          refresh_token: "rt"
        })

      Repo.insert_all("shopifex_token_refresh_leases", [
        %{
          shop_url: shop.url,
          owner: "another-node",
          lease_expires_at: DateTime.add(DateTime.utc_now(), 60, :second)
        }
      ])

      assert {:error, :refresh_in_progress} = Auth.refresh!(shop)
    end
  end

  defp start_refresh_task(task_supervisor, shop) do
    task = start_task(task_supervisor, fn -> Auth.refresh!(shop) end, start?: false)
    :ok = Req.Test.allow(Shopifex.ReqStub, self(), task.pid)
    send(task.pid, :run)
    task
  end

  defp start_task(task_supervisor, fun, opts \\ []) do
    task =
      Task.Supervisor.async_nolink(task_supervisor, fn ->
        receive do
          :run -> fun.()
        end
      end)

    if Keyword.get(opts, :start?, true), do: send(task.pid, :run)
    task
  end

  defp task_result(task) do
    ref = task.ref
    assert_receive {^ref, result}, 1_000
    Process.demonitor(ref, [:flush])
    result
  end
end
