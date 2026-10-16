defmodule MydiaWeb.DownloadsLive.ListView do
  @moduledoc """
  Pure list logic for the Downloads page: URL filter parsing, in-memory
  filtering, the queue summary, and the per-row rules (display title, row state,
  status badge, stall) that the list, the filters and the detail drawer share.

  Works on the enriched list `Mydia.Downloads.list_downloads_with_status/1`
  returns. Touches no Repo and no socket.
  """

  alias Mydia.Downloads.StallDetector
  alias Mydia.Downloads.Structs.DownloadMetadata
  alias MydiaWeb.DownloadsLive.{Filters, Summary}

  @status_options [
    {"downloading", "Downloading"},
    {"stalled", "Stalled"},
    {"paused", "Paused"},
    {"queued", "Queued"},
    {"importing", "Importing"}
  ]
  @statuses Enum.map(@status_options, &elem(&1, 0))

  @spec status_options() :: [{String.t(), String.t()}]
  def status_options, do: @status_options

  @spec parse_filters(map(), atom()) :: Filters.t()
  def parse_filters(params, tab) do
    status = Map.get(params, "status")

    %Filters{
      q: blank_to_nil(Map.get(params, "q")),
      client: blank_to_nil(Map.get(params, "client")),
      status: if(tab == :queue and status in @statuses, do: status)
    }
  end

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  @spec active?(Filters.t()) :: boolean()
  def active?(%Filters{} = filters), do: filters != %Filters{}

  @spec to_params(Filters.t()) :: keyword()
  def to_params(%Filters{} = filters) do
    [q: filters.q, client: filters.client, status: filters.status]
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
  end

  @spec chips(Filters.t()) :: [{String.t(), String.t()}]
  def chips(%Filters{} = filters) do
    [
      filters.q && {"q", "\"#{filters.q}\""},
      filters.client && {"client", "Client: #{filters.client}"},
      filters.status && {"status", "Status: #{status_label(filters.status)}"}
    ]
    |> Enum.reject(&(&1 in [nil, false]))
  end

  defp status_label(value) do
    Enum.find_value(@status_options, value, fn {v, label} -> v == value && label end)
  end

  @spec filter(list(), Filters.t()) :: list()
  def filter(downloads, %Filters{} = filters), do: Enum.filter(downloads, &matches?(&1, filters))

  defp matches?(download, %Filters{q: q, client: client, status: status}) do
    matches_query?([display_title(download), download.title], q) and
      (is_nil(client) or download.download_client == client) and
      (is_nil(status) or row_state(download) == status)
  end

  @doc """
  Filters client-scan entries (Needs Matching, External). They have no
  download row, so only the query and the client apply.
  """
  @spec filter_scan(list(), Filters.t()) :: list()
  def filter_scan(items, %Filters{q: q, client: client}) do
    Enum.filter(items, fn item ->
      matches_query?([item.title], q) and (is_nil(client) or item.client_name == client)
    end)
  end

  defp matches_query?(_fields, nil), do: true

  defp matches_query?(fields, q) do
    needle = String.downcase(q)
    Enum.any?(fields, &(is_binary(&1) and String.contains?(String.downcase(&1), needle)))
  end

  @doc """
  The queue phase a row is in, as the status filter names it. nil for rows
  outside the Queue (imported, failed, cancelled).
  """
  @spec row_state(map()) :: String.t() | nil
  def row_state(download) do
    cond do
      soft_stalled?(download) -> "stalled"
      download.status == "downloading" -> "downloading"
      download.status == "paused" -> "paused"
      download.status in ~w(queued checking grabbing) -> "queued"
      download.status in ~w(seeding completed) and is_nil(download.imported_at) -> "importing"
      true -> nil
    end
  end

  @spec summarize(list()) :: Summary.t()
  def summarize(downloads) do
    %Summary{
      active: length(downloads),
      stalled: Enum.count(downloads, &soft_stalled?/1),
      download_speed: sum_by(downloads, & &1.download_speed),
      upload_speed: sum_by(downloads, & &1.upload_speed),
      remaining_bytes: sum_by(downloads, &remaining_bytes/1),
      eta_seconds:
        downloads
        |> Enum.filter(&(&1.status == "downloading"))
        |> Enum.map(&eta_seconds/1)
        |> Enum.reject(&is_nil/1)
        |> Enum.max(fn -> nil end),
      stale_as_of:
        downloads
        |> Enum.map(& &1.status_as_of)
        |> Enum.reject(&is_nil/1)
        |> Enum.min(DateTime, fn -> nil end)
    }
  end

  defp sum_by(downloads, fun) do
    downloads |> Enum.map(fun) |> Enum.filter(&is_number/1) |> Enum.sum()
  end

  defp remaining_bytes(%{size: size, downloaded: downloaded}) when is_integer(size) and size > 0,
    do: max(size - (downloaded || 0), 0)

  defp remaining_bytes(_download), do: 0

  defp eta_seconds(%{eta: %DateTime{} = at}),
    do: max(DateTime.diff(at, DateTime.utc_now(), :second), 0)

  defp eta_seconds(%{eta: seconds}) when is_integer(seconds) and seconds >= 0, do: seconds
  defp eta_seconds(_download), do: nil

  @spec clients(list()) :: [String.t()]
  def clients(downloads) do
    downloads
    |> Enum.map(& &1.download_client)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "The library title a row belongs to: the show for an episode, else the item."
  @spec media_item_id(map()) :: String.t() | nil
  def media_item_id(%{media_item_id: id}) when is_binary(id), do: id
  def media_item_id(%{episode: %{media_item_id: id}}) when is_binary(id), do: id
  def media_item_id(_download), do: nil

  @metadata_struct_keys ~w(size seeders leechers quality season_pack season_number download_protocol)

  @doc """
  One value from a download's metadata. Keys modeled by `DownloadMetadata` are
  read through the struct (normalised); any other key is read raw.
  """
  @spec get_metadata_value(map(), String.t()) :: term()
  def get_metadata_value(download, key) do
    metadata_map = download.metadata || %{}

    if key in @metadata_struct_keys do
      case DownloadMetadata.from_map(metadata_map) do
        nil -> nil
        metadata -> Map.get(metadata, String.to_existing_atom(key))
      end
    else
      Map.get(metadata_map, key)
    end
  end

  @spec display_title(map()) :: String.t()
  def display_title(download) do
    cond do
      # Episode download - show parent show title
      is_map(download.episode) ->
        if is_map(download.episode.media_item) do
          download.episode.media_item.title
        else
          # Fallback to direct media_item if episode.media_item is not loaded
          if is_map(download.media_item), do: download.media_item.title, else: "Unknown Show"
        end

      # Movie or show-level download
      is_map(download.media_item) && download.media_item.title ->
        download.media_item.title

      # Fallback to torrent title
      true ->
        download.title
    end
  end

  # An import problem that should be surfaced on the row even though the torrent
  # client still reports the download as completed/seeding. The torrent finishing
  # is only half the job — if the post-download import keeps failing (e.g. a
  # filesystem permission error) the user otherwise sees a healthy "seeding" row
  # with no hint that nothing landed in the library. Returns:
  #
  #   * `:failed`   — import failed terminally (no further automatic retries)
  #   * `:retrying` — import failed but a retry is scheduled
  #   * `nil`       — no import problem (not yet attempted, or already imported)
  @spec import_issue(map()) :: :failed | :retrying | nil
  def import_issue(download) do
    cond do
      not is_nil(download.imported_at) -> nil
      is_nil(download.import_failed_at) and is_nil(download.import_last_error) -> nil
      not is_nil(download.import_next_retry_at) -> :retrying
      true -> :failed
    end
  end

  @doc false
  # Returns `{class, label}` for the download's status badge. A soft-stall is a
  # recoverable warning: progress has stopped but the download still occupies
  # its episode and may auto-clear. There is no terminal stall badge — an
  # escalated stall is rejected outright and the row no longer exists.
  @spec status_badge(map()) :: {String.t(), String.t()}
  def status_badge(download) do
    if soft_stalled?(download) do
      {status_badge_class("stalled"), "Stalled"}
    else
      {status_badge_class(download.status), String.capitalize(download.status)}
    end
  end

  defp status_badge_class(status) do
    case status do
      "completed" -> "badge-success"
      "seeding" -> "badge-success"
      "imported" -> "badge-success"
      "failed" -> "badge-error"
      "missing" -> "badge-error"
      "cancelled" -> "badge-warning"
      "downloading" -> "badge-primary"
      "checking" -> "badge-info"
      "queued" -> "badge-info"
      "paused" -> "badge-warning"
      "stalled" -> "badge-warning"
      _ -> "badge-ghost"
    end
  end

  # A recoverable soft-stall: `stalled_since` set but not yet escalated to a
  # terminal `import_failed_at` failure. Gated on the live "downloading" status
  # so a download that pauses, completes, or goes client-unreachable after a
  # soft-stall does not keep rendering a stale warning — `stalled_since` is only
  # cleared while the download is observed downloading, so it can linger on a row
  # that has since moved on.
  @spec soft_stalled?(map()) :: boolean()
  def soft_stalled?(download) do
    download.status == "downloading" and StallDetector.soft_stalled?(download)
  end

  # Seconds since this download last moved a byte. Falls back to stalled_since
  # for a row whose last_progress_at predates stall tracking.
  @spec stall_elapsed_seconds(map()) :: integer()
  def stall_elapsed_seconds(download) do
    reference = download.last_progress_at || download.stalled_since
    DateTime.diff(DateTime.utc_now(), reference, :second)
  end
end
