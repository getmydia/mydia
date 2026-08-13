defmodule Mydia.MetadataStub do
  @moduledoc """
  Setup helper that swaps the real metadata relay provider for
  `Mydia.MetadataStubProvider` and restores it afterwards.

  Use as `setup :setup_metadata_stub`.

  The metadata cache is cleared on the way in and on the way out. It is global
  ETS with no other test-suite reset, so a cached season or lookup would
  otherwise make TV coverage pass or fail depending on test ordering.

  Every case using this helper must be `async: false`. `Provider.Registry` is an
  Agent, so registration is process-global. ExUnit runs sync modules only after
  every async module has finished, which is what makes the swap safe.
  """

  alias Mydia.Metadata
  alias Mydia.Metadata.Cache
  alias Mydia.Metadata.Provider.Registry
  alias Mydia.MetadataStubProvider

  @doc """
  Registers the stub provider and restores real providers on exit.
  """
  def setup_metadata_stub(_context \\ %{}) do
    Registry.register(:metadata_relay, MetadataStubProvider)
    Cache.clear()

    ExUnit.Callbacks.on_exit(fn ->
      Metadata.register_providers()
      Cache.clear()
    end)

    :ok
  end
end
