import Config

config :shopifex,
  shop_schema: %{},
  payment_guard: Shopifex.Plug.PaymentGuardTest.PaymentGuard,
  env: Mix.env()

# Route Shopifex.Auth / Shopifex.API HTTP through Req.Test so token-lifecycle
# and GraphQL transport can be tested without real Shopify calls. Each test
# registers a stub against the `Shopifex.ReqStub` name.
config :shopifex, :req_options, plug: {Req.Test, Shopifex.ReqStub}

import_config "../test/support/shopifex_dummy/config/config.exs"
