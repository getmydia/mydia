defmodule Mydia.Downloads.ExternalPolicy do
  @moduledoc """
  What Mydia does with a torrent sitting in a download client that Mydia did
  not add.

  Mydia adopts and imports foreign torrents that match a library item. That is
  intentional, and for most operators it is what they want: a release grabbed
  by hand still lands in the library. It is also the behaviour reported in
  issue #531, where an operator keeps several copies of one film side by side
  to compare them and Mydia files each finished copy into the library folder.

  This module is the whole opt-out rule.

  ## The modes

    * `:adopt` — every foreign torrent matching a library item is adopted
    * `:category_only` — adopt only torrents carrying one of this client's
      configured categories
    * `:ignore` — never adopt; foreign torrents stay visible under Downloads,
      External
    * `:auto` — the stored default, resolved rather than frozen

  `:auto` resolves to `:category_only` when the client has a category
  configured and can report one back, and to `:adopt` otherwise. Resolving it
  at read time rather than stamping a value at migration time is deliberate: a
  client that gains a category later tightens on its own, and an operator who
  never used categories keeps exactly the behaviour they had before.

  ## Why it is pure

  No database, no network, every input an argument, in the same spirit as
  `Mydia.Downloads.ClientAdoption`. Two callers depend on this rule and must
  never disagree about it:

    * `Mydia.Downloads.UntrackedMatcher` decides whether to adopt
    * `Mydia.Downloads.ExternalTorrents` decides whether a torrent renders as
      something to fix (Issues) or something deliberately left alone (External)

  If those two drifted apart, a torrent could be refused by one and filed as a
  problem by the other, which is the confusing state this module exists to make
  impossible. Being pure means the whole edge-case suite lives in its tests.
  """

  alias Mydia.Downloads.Structs.DownloadStatus
  alias Mydia.Settings.DownloadClientConfig

  @typedoc """
  Why a torrent was or was not adopted.

  The two exclusion reasons are distinct because they render differently:
  `:excluded_by_category` still gets library suggestions computed, since the
  operator plausibly wants a one-off manual pull, while `:excluded_by_ignore`
  does not, because scoring every foreign torrent every couple of minutes is
  work the operator explicitly asked Mydia not to do.
  """
  @type decision :: :adopt | :excluded_by_category | :excluded_by_ignore

  @type mode :: :adopt | :category_only | :ignore

  @doc """
  Whether this client type reports a category or label Mydia can read back.

  Delegates to `Mydia.Settings.DownloadClientConfig` so the runtime rule and
  the write-time validation cannot disagree about which clients qualify.
  """
  @spec supports_categories?(atom()) :: boolean()
  def supports_categories?(type) do
    type in DownloadClientConfig.category_capable_types()
  end

  @doc """
  Every category configured for a client, from both the per-content-type map
  and the legacy single field.

  Blank and whitespace-only values are dropped: an empty category input is the
  operator saying "none", and treating it as a real category would silence the
  client entirely under `:category_only`.
  """
  @spec configured_categories(DownloadClientConfig.t()) :: MapSet.t(String.t())
  def configured_categories(config) do
    from_map =
      case Map.get(config, :categories) do
        map when is_map(map) -> Map.values(map)
        _ -> []
      end

    [Map.get(config, :category) | from_map]
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> MapSet.new()
  end

  @doc """
  The mode actually in force for a client, with `:auto` resolved.

  A `nil` mode is treated as `:auto` so a struct built without the field, which
  happens in tests and in older serialised runtime config, still resolves
  rather than crashing.
  """
  @spec effective_mode(DownloadClientConfig.t()) :: mode()
  def effective_mode(config) do
    case Map.get(config, :external_torrents) do
      mode when mode in [:adopt, :category_only, :ignore] -> mode
      _auto_or_nil -> resolve_auto(config)
    end
  end

  @doc """
  Whether to adopt this torrent from this client, and why not when the answer
  is no.
  """
  @spec decide(DownloadClientConfig.t(), DownloadStatus.t()) :: decision()
  def decide(config, %DownloadStatus{} = status) do
    case effective_mode(config) do
      :ignore ->
        :excluded_by_ignore

      :adopt ->
        :adopt

      :category_only ->
        if category_match?(config, status), do: :adopt, else: :excluded_by_category
    end
  end

  @doc """
  Whether to adopt this torrent from this client.
  """
  @spec adopt?(DownloadClientConfig.t(), DownloadStatus.t()) :: boolean()
  def adopt?(config, %DownloadStatus{} = status), do: decide(config, status) == :adopt

  ## Private

  defp resolve_auto(config) do
    capable? = supports_categories?(Map.get(config, :type))

    if capable? and not Enum.empty?(configured_categories(config)) do
      :category_only
    else
      :adopt
    end
  end

  # Exact match, never a prefix. "mydia" and "mydia-movies" are two different
  # categories in every client that has them, and matching loosely would adopt
  # from a category the operator deliberately kept separate.
  defp category_match?(config, status) do
    configured = configured_categories(config)

    status
    |> Map.get(:categories)
    |> List.wrap()
    |> Enum.any?(&MapSet.member?(configured, &1))
  end
end
