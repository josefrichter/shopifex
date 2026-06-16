defmodule Shopifex.RedirectAfterAgentTest do
  use ExUnit.Case, async: false

  alias Shopifex.RedirectAfterAgent

  test "round-trips the string charge id PaymentController produces from a GID" do
    # unwrap_charge/3 returns the trailing GID segment as a string ("4019552312"),
    # and Shopify's return-url charge_id also arrives as a string. These must match.
    RedirectAfterAgent.set("4019552312", "/back/here")
    assert RedirectAfterAgent.get("4019552312") == "/back/here"
  end

  test "set and get agree across binary/integer keys" do
    RedirectAfterAgent.set("777", "/x")
    assert RedirectAfterAgent.get(777) == "/x"

    RedirectAfterAgent.set(888, "/y")
    assert RedirectAfterAgent.get("888") == "/y"
  end

  test "get/1 consumes the entry (one-shot)" do
    RedirectAfterAgent.set("999", "/once")
    assert RedirectAfterAgent.get("999") == "/once"
    assert RedirectAfterAgent.get("999") == nil
  end
end
