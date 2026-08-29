defmodule Mydia.RelayGuard do
  @moduledoc """
  A Req adapter that refuses any request leaving this machine.

  Installed globally from `test/test_helper.exs` with
  `Req.default_options(adapter: __MODULE__)`. `Req.new/2` merges
  `default_options()` before splitting `:adapter` out into the request struct,
  so this reaches every `Req.new/1` call site with no change to `lib/`.

  Loopback traffic goes to the real `Req.Finch` adapter, which is what keeps
  Bypass working and leaves every `Mydia.MetadataCacheHelpers` warm call
  untouched. Everything else is recorded and refused.

  This exists because nothing else stopped it. `Mydia.Metadata.default_relay_config/0`
  falls back to `https://relay.mydia.dev` in test, and the cache warming that
  protects detail-page tests is opt-in and silent when forgotten (#530).
  `Mydia.MetadataStub` does not help: it swaps the provider in
  `Mydia.Metadata.Provider.Registry`, and these lookups call
  `Metadata.fetch_*_cached` against a config map directly.
  """

  alias Mydia.RelayGuard.BlockedError
  alias Mydia.RelayGuard.Escapes

  @loopback_hosts ~w(localhost 127.0.0.1 ::1)

  @doc "The Req adapter callback."
  def run(%Req.Request{} = req) do
    if loopback?(req.url.host) do
      Req.Finch.run(req)
    else
      Escapes.record(req)
      {req, %BlockedError{url: req.url}}
    end
  end

  @doc "Whether `host` names this machine."
  def loopback?(host) when host in @loopback_hosts, do: true
  def loopback?(_host), do: false
end
