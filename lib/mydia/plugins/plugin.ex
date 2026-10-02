defmodule Mydia.Plugins.Plugin do
  @moduledoc """
  Runtime descriptor for an installed plugin.

  Built from a validated `Mydia.Plugins.Manifest` via `from_manifest/2`. The
  manifest only *declares* what a plugin wants; a `%Plugin{}` therefore carries
  two distinct capability sets:

    * `capabilities` — the declared set parsed from the manifest, and
    * `granted_capabilities` — the set an admin has approved server-side
      (KTD6). It is **empty by default**: parsing a manifest never confers any
      active capability (R5, deny-by-default). U4/U8 populate grants from
      persisted `PluginConfig.granted_capabilities`, never from the manifest.

  Capability sets are canonical maps of `class => values`, e.g.
  `%{"net:http" => ["discord.com"], "events:subscribe" => ["media_item.added"]}`.
  """

  @type capabilities :: %{optional(String.t()) => [String.t()]}

  @type delivery :: :inline | :durable

  @type t :: %__MODULE__{
          slug: String.t(),
          name: String.t(),
          version: String.t(),
          description: String.t() | nil,
          author: String.t() | nil,
          entrypoint: String.t(),
          events: [String.t()],
          capabilities: capabilities(),
          granted_capabilities: capabilities(),
          enabled: boolean(),
          source: atom() | nil,
          delivery: delivery(),
          multi_instance: boolean(),
          category: String.t() | nil,
          setup: boolean(),
          connection: map() | nil,
          page: map() | nil,
          shelves: [map()]
        }

  defstruct slug: nil,
            name: nil,
            version: nil,
            description: nil,
            author: nil,
            entrypoint: "handle",
            events: [],
            capabilities: %{},
            granted_capabilities: %{},
            enabled: false,
            source: nil,
            delivery: :inline,
            multi_instance: false,
            category: nil,
            setup: false,
            connection: nil,
            page: nil,
            shelves: []

  alias Mydia.Plugins.Manifest

  @doc """
  Builds a `%Plugin{}` from a validated manifest.

  Grants are intentionally **not** taken from the manifest — `granted_capabilities`
  starts empty (deny-by-default). Pass `:granted_capabilities` and other runtime
  fields (`:enabled`, `:source`) as opts when rehydrating from persisted config.
  """
  @spec from_manifest(Manifest.t(), keyword()) :: t()
  def from_manifest(%Manifest{} = manifest, opts \\ []) do
    %__MODULE__{
      slug: manifest.slug,
      name: manifest.name,
      version: manifest.version,
      description: manifest.description,
      author: manifest.author,
      entrypoint: manifest.entrypoint,
      events: manifest.events,
      capabilities: manifest.capabilities,
      granted_capabilities: Keyword.get(opts, :granted_capabilities, %{}),
      enabled: Keyword.get(opts, :enabled, false),
      source: Keyword.get(opts, :source),
      delivery: Keyword.get(opts, :delivery, :inline),
      multi_instance: manifest.multi_instance,
      category: manifest.category,
      setup: manifest.setup,
      connection: manifest.connection,
      page: manifest.page,
      shelves: manifest.shelves
    }
  end

  @doc """
  Returns the granted hostnames for the `net:http` capability (deny-by-default:
  `[]` when not granted). This is the allowlist the network gate enforces (U6).
  """
  @spec granted_http_hosts(t()) :: [String.t()]
  def granted_http_hosts(%__MODULE__{granted_capabilities: granted}) do
    Map.get(granted, "net:http", [])
  end

  @doc """
  Hosts the operator allowed to resolve to a private address, derived from
  `allow_private` settings. `[]` unless granted.
  """
  @spec private_hosts(t()) :: [String.t()]
  def private_hosts(%__MODULE__{granted_capabilities: granted}) do
    Map.get(granted, "net:private", [])
  end

  @doc "True when `class` is present in the plugin's granted capabilities."
  @spec granted?(t(), String.t()) :: boolean()
  def granted?(%__MODULE__{granted_capabilities: granted}, class) do
    Map.has_key?(granted, class)
  end
end
