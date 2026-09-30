defmodule MydiaWeb.Plugs.PageBodyBypass do
  @moduledoc """
  `Plug.Parsers` that leaves plugin page requests (`/plugins/:slug/app/...`)
  alone.

  A page owns its request bodies: `MydiaWeb.PluginPageController` reads the raw
  bytes and hands them to the guest untouched, so the parsers must not consume
  the body first. Every other path is parsed with the given `Plug.Parsers`
  options.
  """

  @behaviour Plug

  @impl true
  def init(opts), do: Plug.Parsers.init(opts)

  @impl true
  def call(%Plug.Conn{path_info: ["plugins", _slug, "app" | _]} = conn, _opts) do
    %{conn | body_params: %{}}
  end

  def call(conn, opts), do: Plug.Parsers.call(conn, opts)
end
