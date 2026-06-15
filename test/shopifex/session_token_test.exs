defmodule Shopifex.SessionTokenTest do
  use ExUnit.Case, async: true

  alias Shopifex.SessionToken

  @secret "shpss_thisisafakesecret"
  @api_key "thisisafakeapikey"
  @shop "session-token-test.myshopify.com"

  defp sign(claims) do
    jwk = JOSE.JWK.from_oct(@secret)
    {_, token} = JOSE.JWT.sign(jwk, %{"alg" => "HS256"}, claims) |> JOSE.JWS.compact()
    token
  end

  defp valid_claims(overrides \\ %{}) do
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
  end

  test "accepts a valid token and returns its claims" do
    assert {:ok, claims} = SessionToken.verify(sign(valid_claims()), @shop)
    assert claims["dest"] == "https://#{@shop}"
  end

  test "accepts a valid token without a shop_url argument" do
    assert {:ok, _claims} = SessionToken.verify(sign(valid_claims()))
  end

  test "rejects a token signed with the wrong secret as invalid_signature" do
    jwk = JOSE.JWK.from_oct("a-totally-different-secret")
    {_, token} = JOSE.JWT.sign(jwk, %{"alg" => "HS256"}, valid_claims()) |> JOSE.JWS.compact()
    assert {:error, :invalid_signature} = SessionToken.verify(token, @shop)
  end

  test "returns :expired distinctly for an expired token" do
    now = System.system_time(:second)
    token = sign(valid_claims(%{"exp" => now - 120}))
    assert {:error, :expired} = SessionToken.verify(token, @shop)
  end

  test "rejects a mismatched destination" do
    token = sign(valid_claims())
    assert {:error, :invalid_destination} = SessionToken.verify(token, "other.myshopify.com")
  end

  test "rejects a non-myshopify destination" do
    token = sign(valid_claims(%{"dest" => "https://evil.example.com"}))
    assert {:error, :invalid_destination} = SessionToken.verify(token)
  end

  test "rejects a wrong audience" do
    token = sign(valid_claims(%{"aud" => "someone-elses-api-key"}))
    assert {:error, :invalid_audience} = SessionToken.verify(token, @shop)
  end

  test "rejects a mismatched issuer" do
    token = sign(valid_claims(%{"iss" => "https://#{@shop}/not-admin"}))
    assert {:error, :invalid_issuer} = SessionToken.verify(token, @shop)
  end

  test "rejects non-binary input" do
    assert {:error, :invalid_token} = SessionToken.verify(nil)
    assert {:error, :invalid_token} = SessionToken.verify(123, @shop)
  end

  describe "secret rotation (:old_secret)" do
    @old_secret "shpss_previous_app_secret"

    setup do
      on_exit(fn -> Application.delete_env(:shopifex, :old_secret) end)
      :ok
    end

    test "accepts a token signed with the old secret only when :old_secret is configured" do
      jwk = JOSE.JWK.from_oct(@old_secret)
      {_, token} = JOSE.JWT.sign(jwk, %{"alg" => "HS256"}, valid_claims()) |> JOSE.JWS.compact()

      assert {:error, :invalid_signature} = SessionToken.verify(token, @shop)

      Application.put_env(:shopifex, :old_secret, @old_secret)
      assert {:ok, claims} = SessionToken.verify(token, @shop)
      assert claims["dest"] == "https://#{@shop}"
    end

    test "the current secret still verifies while :old_secret is configured" do
      Application.put_env(:shopifex, :old_secret, @old_secret)
      assert {:ok, _claims} = SessionToken.verify(sign(valid_claims()), @shop)
    end
  end
end
