defmodule MydiaWeb.Plugs.UnlessPluginPage do
  @moduledoc """
  Runs another plug on every request except plugin page requests
  (`/plugins/:slug/app/...`).

  Two endpoint plugs are wrapped this way. `Plug.Parsers` must not consume a
  page's body, because `MydiaWeb.PluginPageController` reads the raw bytes and
  hands them to the guest untouched. `Corsica` must not answer a page's CORS
  preflight, because the controller sets the page-specific headers (a sandboxed
  frame sends `Origin: null` and a custom token header).

  Only the exact segment `app` under `/plugins/:slug` matches, so `/plugins/x/appx`
  and `/plugins/x/app%2Fy` are treated as ordinary requests.

  Options: `:plug` (module) and `:opts` (its options, initialised at compile time).
  """

  @behaviour Plug

  @impl true
  def init(opts) do
    mod = Keyword.fetch!(opts, :plug)
    %{plug: mod, opts: mod.init(Keyword.get(opts, :opts, []))}
  end

  @impl true
  def call(%Plug.Conn{path_info: ["plugins", _slug, "app" | _]} = conn, _wrapped) do
    case conn.body_params do
      %Plug.Conn.Unfetched{} -> %{conn | body_params: %{}}
      _ -> conn
    end
  end

  def call(conn, %{plug: mod, opts: opts}), do: mod.call(conn, opts)
end
