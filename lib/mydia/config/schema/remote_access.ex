defmodule Mydia.Config.Schema.RemoteAccess do
  @moduledoc """
  The `remote_access` section of `Mydia.Config.Schema`.

  `enabled` is whether this server runs its p2p node and accepts pairing. It
  only counts while the player is on, and that switch (ENABLE_PLAYER) is not
  part of this schema on purpose: see `Mydia.Player`. ENABLE_REMOTE_ACCESS
  overrides the admin toggle that writes it.

  `relay_urls` are iroh relays to use instead of mydia's, in preference order.
  Empty means mydia's list from the metadata relay (`Mydia.P2p.RelayList`).
  iroh's public relays stay underneath either way. IROH_RELAY_URL overrides
  the admin field that writes it.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key false
  embedded_schema do
    field :enabled, :boolean, default: true
    field :relay_urls, {:array, :string}, default: []
  end

  @type t :: %__MODULE__{}

  def changeset(schema, attrs) do
    schema
    |> cast(attrs, [:enabled, :relay_urls])
    |> validate_change(:relay_urls, fn :relay_urls, urls ->
      case Enum.reject(urls || [], &relay_url?/1) do
        [] -> []
        bad -> [relay_urls: "must be https URLs: #{Enum.join(bad, ", ")}"]
      end
    end)
  end

  @doc """
  Whether `url` can be an iroh relay: https with a host, and no comma. The one
  rule the config, the admin UI and `Mydia.P2p.RelayList` all apply. A list is
  stored and read comma-separated, so a comma inside a URL would reload as two
  entries.
  """
  @spec relay_url?(term()) :: boolean()
  def relay_url?(url) when is_binary(url) do
    not String.contains?(url, ",") and
      match?(
        %URI{scheme: "https", host: host} when is_binary(host) and host != "",
        URI.parse(url)
      )
  end

  def relay_url?(_), do: false
end
