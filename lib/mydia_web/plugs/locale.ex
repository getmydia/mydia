defmodule MydiaWeb.Plugs.Locale do
  @moduledoc """
  Sets the request's interface locale from the browser.

  Runs in the `:browser` pipeline, before authentication, so it only knows
  `Accept-Language` and the instance default. The result is stored in the
  session as `"locale"` so LiveView processes (which do not see request
  headers) start from it. `MydiaWeb.Plugs.UserLocale` applies a signed-in
  user's preference on top. See `Mydia.Locale`.
  """
  @behaviour Plug

  import Plug.Conn

  @impl Plug
  def init(opts), do: opts

  @impl Plug
  def call(conn, _opts) do
    header = conn |> get_req_header("accept-language") |> List.first()
    locale = Mydia.Locale.resolve(nil, header, Mydia.Locale.instance_default())

    conn =
      if get_session(conn, "locale") == locale,
        do: conn,
        else: put_session(conn, "locale", locale)

    Gettext.put_locale(MydiaWeb.Gettext, locale)
    assign(conn, :locale, locale)
  end
end
