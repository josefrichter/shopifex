defmodule Shopifex.ManagedInstall.Callbacks do
  @moduledoc """
  Extensibility hooks for the managed-installation flow
  (`Shopifex.Plug.ManagedInstall`).

  Managed installation runs inside a plug, *before* any controller, so it cannot
  use `ShopifexWeb.AuthController`'s `insert_shop/1` and `after_install/3`
  callbacks (those only apply to the legacy OAuth controller flow). Instead,
  configure a callback module here to customise how a newly token-exchanged shop
  is persisted and what side effects run on first install:

      config :shopifex,
        managed_install_callbacks: MyApp.ManagedInstallCallbacks

      defmodule MyApp.ManagedInstallCallbacks do
        use Shopifex.ManagedInstall.Callbacks

        @impl true
        def insert_shop(attrs) do
          # enforce single-tenant, attach defaults, etc.
          Shopifex.Shops.create_shop(attrs)
        end

        @impl true
        def after_install(shop) do
          # fetch shop profile, send yourself an email, take a baseline snapshot…
          :ok
        end
      end

  Both callbacks are optional — `use Shopifex.ManagedInstall.Callbacks` provides
  defaults (`insert_shop/1` delegates to `Shopifex.Shops.create_shop/1`,
  `after_install/1` is a no-op). The plug always configures webhooks on first
  install itself, regardless of `after_install/1`.

  Token *refreshes* of an already-installed shop do not invoke these callbacks —
  they only update the token-lifecycle fields via `Shopifex.Shops.update_shop/2`.
  """

  @doc """
  Persist a brand-new shop from the token-exchange attributes and return the
  shop record. Defaults to `Shopifex.Shops.create_shop/1`.
  """
  @callback insert_shop(attrs :: map()) :: Shopifex.Plug.shop()

  @doc """
  Run app-specific side effects after a shop is installed for the first time
  (after persistence and webhook configuration). Defaults to a no-op.
  """
  @callback after_install(shop :: Shopifex.Plug.shop()) :: any()

  @doc false
  def module do
    Application.get_env(:shopifex, :managed_install_callbacks, __MODULE__.Default)
  end

  defmacro __using__(_opts) do
    quote do
      @behaviour Shopifex.ManagedInstall.Callbacks

      @impl true
      def insert_shop(attrs), do: Shopifex.Shops.create_shop(attrs)

      @impl true
      def after_install(_shop), do: :ok

      defoverridable insert_shop: 1, after_install: 1
    end
  end
end
