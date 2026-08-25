defmodule Shopifex.API do
  @moduledoc """
  Shopify GraphQL Admin API transport.

  This is the library's single chokepoint for Admin API calls. Every request
  goes through `graphql/3`, which keeps expiring offline access tokens fresh:

  - **Proactive refresh** before the call (`Shopifex.Auth.ensure_fresh_token/1`):
    if the token will expire within ~5 minutes, refresh now so the request
    doesn't race the expiry.
  - **Reactive refresh** after a 401 (`Shopifex.Auth.refresh!/1`): if Shopify
    rejects the token anyway (e.g. revoked early), refresh once and retry the
    request once.

  This is the strategy Shopify explicitly recommends:
  https://shopify.dev/changelog/offline-access-tokens-now-support-expiry-and-refresh

  ## What lives here vs. in your app

  This module ships only the *transport*. App-specific queries and mutations
  (products, inventory, metafields, …) belong in your application — call
  `Shopifex.API.graphql/3` from there. The library itself only uses this
  transport for webhook subscription and billing mutations.

  ## API version

  The Admin API version is configurable and defaults to `"2026-07"`:

      config :shopifex, :api_version, "2026-07"

  `api_version/0` is the single source of truth — webhook and billing code
  read it too.
  """

  alias Shopifex.Auth

  @default_api_version "2026-07"

  @doc """
  Run a GraphQL query/mutation against the shop's Admin API.

  Returns `{:ok, data}` on success, or `{:error, reason}` where `reason` is
  either the GraphQL `errors` list (HTTP 200 with partial failure), a
  `{status, body}` tuple, or a transport error.
  """
  @spec graphql(struct(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def graphql(shop, query, variables \\ %{}) do
    shop = Auth.ensure_fresh_token(shop)
    do_graphql(shop, query, variables, _allow_retry = true)
  end

  defp do_graphql(shop, query, variables, allow_retry?) do
    body = %{query: query}
    body = if variables != %{}, do: Map.put(body, :variables, variables), else: body

    req_opts =
      [
        json: body,
        headers: [{"x-shopify-access-token", shop.access_token}]
      ] ++ Application.get_env(:shopifex, :req_options, [])

    url = "https://#{Shopifex.Shops.get_url(shop)}/admin/api/#{api_version()}/graphql.json"

    case Req.post(url, req_opts) do
      # Errors take precedence even when "data" is present — Shopify returns
      # partial responses (`data: { foo: null }, errors: [...]`) when a single
      # field fails (e.g. missing scope). Without this we'd silently drop the
      # error and the caller would see a nil field with no clue why.
      {:ok, %{status: 200, body: %{"errors" => errors}}} ->
        {:error, errors}

      {:ok, %{status: 200, body: %{"data" => data}}} ->
        {:ok, data}

      # Reactive refresh: if Shopify says the token is bad, try to refresh once
      # and retry the request. Only refresh-retry once to avoid an infinite
      # loop if the refresh succeeds but the new token is still rejected.
      {:ok, %{status: 401}} = response when allow_retry? ->
        case Auth.refresh!(shop) do
          {:ok, refreshed_shop} ->
            do_graphql(refreshed_shop, query, variables, _allow_retry = false)

          {:error, _reason} ->
            unwrap_error(response)
        end

      {:ok, response} ->
        unwrap_error({:ok, response})

      {:error, err} ->
        {:error, err}
    end
  end

  defp unwrap_error({:ok, %{status: status, body: body}}), do: {:error, {status, body}}

  @doc """
  The configured Shopify Admin API version. Defaults to `"#{@default_api_version}"`.
  """
  @spec api_version() :: String.t()
  def api_version, do: Application.get_env(:shopifex, :api_version, @default_api_version)
end
