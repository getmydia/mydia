defmodule Mydia.RelayStubHelpers do
  @moduledoc """
  Points the metadata relay at a Bypass server for one test.

  The relay URL is global application env, so a test using this must not be
  `async: true`. The previous value is restored on exit.
  """

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc "Opens a Bypass server and makes it the metadata relay until the test exits."
  def point_relay_at_bypass do
    bypass = Bypass.open()
    previous = Application.get_env(:mydia, :metadata_relay_url)
    Application.put_env(:mydia, :metadata_relay_url, "http://localhost:#{bypass.port}")

    on_exit(fn ->
      if previous,
        do: Application.put_env(:mydia, :metadata_relay_url, previous),
        else: Application.delete_env(:mydia, :metadata_relay_url)
    end)

    bypass
  end
end
