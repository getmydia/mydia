defmodule MetadataRelay.ClientConfig do
  @moduledoc """
  The client configuration document served at `GET /client-config`.

  Installs read this at boot to learn which iroh relays mydia operates, so a
  relay can be moved or replaced by deploying this service instead of shipping
  a new server image and player build and waiting for every install to upgrade.

  The list below is the source of truth. Changing it is a `metadata-relay-v*`
  tag plus Keel's five minute poll, which is minutes rather than the weeks a
  client release takes.

  `relay-worker/src/config/client_config.ts` carries the same list and must be
  changed in the same commit. `relay-worker/test/contract/routes.json` includes
  this route so the cutover gate diffs the two.

  Clients ignore keys they do not know, so a new key can be added here without
  a client change. There is deliberately no version field: an incompatible
  change adds a new key and leaves the old one in place for a release, which is
  the same shape as the `pairing/v2` fallback in the player's relay client.
  """

  @relay_urls ["https://cae1-1.relay.mydia.dev"]

  @doc """
  The iroh relays mydia operates, in preference order.

  Clients append iroh's own public relays underneath these as a fallback, so
  this list carries only mydia's own.
  """
  @spec relay_urls() :: [String.t()]
  def relay_urls, do: @relay_urls

  @doc """
  The full client configuration document.
  """
  @spec document() :: %{p2p: %{relays: [String.t()]}}
  def document, do: %{p2p: %{relays: relay_urls()}}
end
