defmodule ShopifexWeb do
  @moduledoc """
  The entrypoint for shopifex web interface, such
  as controllers, views, channels and so on.

  This can be used in your application as:

      use ShopifexWeb, :controller
      use ShopifexWeb, :view

  The definitions below will be executed for every view,
  controller, etc, so keep them short and clean, focused
  on imports, uses and aliases.

  Do NOT define functions inside the quoted expressions
  below. Instead, define any helper function in modules
  and import those modules here.
  """

  def controller do
    web_module = Application.get_env(:shopifex, :web_module)

    quote do
      use Phoenix.Controller, formats: [:html, :json]
      use Gettext, backend: ShopifexWeb.Gettext

      import Plug.Conn
      alias unquote(web_module).Router.Helpers, as: Routes
    end
  end

  @doc """
  HTML rendering — Phoenix 1.7+ function components. `use ShopifexWeb, :html`
  brings in `Phoenix.Component` (`~H`, `embed_templates`, `attr/3`) plus the
  HTML helpers shared across Shopifex's `*HTML` modules and layouts.
  """
  def html do
    quote do
      use Phoenix.Component

      # Import convenience functions from controllers
      import Phoenix.Controller, only: [get_csrf_token: 0]

      unquote(html_helpers())
    end
  end

  defp html_helpers do
    quote do
      use Gettext, backend: ShopifexWeb.Gettext
      import Phoenix.HTML
    end
  end

  @doc """
  When used, dispatch to the appropriate controller/view/etc.
  """
  defmacro __using__(which) when is_atom(which) do
    apply(__MODULE__, which, [])
  end
end
