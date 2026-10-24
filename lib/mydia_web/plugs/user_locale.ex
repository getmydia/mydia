defmodule MydiaWeb.Plugs.UserLocale do
  @moduledoc """
  Applies a signed-in user's `interface_language` over the browser locale set
  by `MydiaWeb.Plugs.Locale`. Runs at the end of the router's `:auth`
  pipeline, after Guardian has loaded the user. The session keeps the browser
  locale, so a user who switches back to Automatic gets it again.
  """
  @behaviour Plug

  import Plug.Conn

  alias Mydia.Accounts
  alias Mydia.Accounts.{User, UserPreference}

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    case Guardian.Plug.current_resource(conn) do
      %User{} = user ->
        preference =
          user |> Accounts.get_user_preference!() |> UserPreference.interface_language()

        locale = Mydia.Locale.with_preference(preference, conn.assigns[:locale])
        Gettext.put_locale(MydiaWeb.Gettext, locale)
        assign(conn, :locale, locale)

      _ ->
        conn
    end
  end
end
