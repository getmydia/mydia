defmodule Mydia.Downloads.Queue.ClientSelection do
  @moduledoc false

  import Ecto.Query, warn: false

  alias Mydia.Repo
  alias Mydia.Downloads.Download
  alias Mydia.Downloads.Blacklists
  alias Mydia.Downloads.BuiltIn
  alias Mydia.Downloads.BuiltIn.DiskSpace
  alias Mydia.Downloads.Client
  alias Mydia.Downloads.WantedFiles
  alias Mydia.Downloads.Client.Registry
  alias Mydia.Downloads.History
  alias Mydia.Downloads.Priority
  alias Mydia.Downloads.SeedingLimits
  alias Mydia.Downloads.Structs.DownloadMetadata
  alias Mydia.Indexers.SearchResult
  alias Mydia.Indexers.Structs.{SearchResultMetadata, TrackerTerms}
  alias Mydia.Indexers.TrackerRules
  alias Mydia.Settings
  alias Mydia.Media.MediaItem
  alias Mydia.Downloads.Queue.Duplicates
  alias Mydia.Downloads.Queue.FilePreview
  alias Mydia.Downloads.TorrentFetch
  require Logger

  # The disk reserve is set in decimal gigabytes (`min_free_space_gb`).
  @gb 1_000_000_000

  # Returns an Oban changeset, or nil when there is nothing sensible to search
  # for. `Media` exposes only the raising `get_media_item!/1`, so this reads the
  # association instead: a deleted media item yields nil rather than raising in
  # the middle of a cleanup path.
  @doc false
  # Public for Mydia.Jobs.RemoveDownload, which queues the search once a
  # rejected download's row is gone.
  def replacement_search(%Download{episode_id: episode_id}) when is_binary(episode_id) do
    Mydia.Jobs.TVShowSearch.new(%{"mode" => "specific", "episode_id" => episode_id})
  end

  def replacement_search(%Download{media_item_id: media_item_id} = download)
      when is_binary(media_item_id) do
    case Repo.preload(download, :media_item).media_item do
      %{type: "movie", id: id} ->
        Mydia.Jobs.MovieSearch.new(%{"mode" => "specific", "media_item_id" => id})

      %{type: "tv_show", id: id} ->
        Mydia.Jobs.TVShowSearch.new(%{"mode" => "show", "media_item_id" => id})

      _other ->
        nil
    end
  end

  def replacement_search(_download), do: nil

  @doc false
  def enqueue_search(nil), do: :ok
  def enqueue_search(changeset), do: Mydia.Jobs.insert(changeset)

  ## Private Functions - Download Initiation

  @doc false
  def verify_downloads_in_client(downloads) do
    has_active =
      Enum.any?(downloads, fn download ->
        case verify_single_download_in_client(download) do
          :active -> true
          :stale -> false
        end
      end)

    if has_active, do: :has_active, else: :all_stale
  end

  defp verify_single_download_in_client(download) do
    with {:ok, client_config} <- find_client_config(download.download_client),
         {:ok, adapter} <- get_adapter_for_client(client_config) do
      client_map_config = config_to_map(client_config)

      case Client.get_status(adapter, client_map_config, download.download_client_id) do
        {:ok, _status} ->
          :active

        {:error, %{type: :not_found}} ->
          Logger.warning("Active download not found in client, marking as failed",
            download_id: download.id,
            title: download.title,
            client: download.download_client
          )

          History.mark_download_failed(download, "Torrent no longer exists in download client")
          :stale

        {:error, reason} ->
          # Client error (connection issue, etc.) - assume download is still active
          # to avoid accidentally re-downloading
          Logger.warning("Could not verify download in client, assuming active",
            download_id: download.id,
            reason: inspect(reason)
          )

          :active
      end
    else
      {:error, _reason} ->
        # Client config not found - can't verify, assume active
        :active
    end
  end

  @doc false
  # Resolves a client name to {adapter, config_map}. Public so callers outside
  # this module (Mydia.Jobs.DownloadMonitor) can talk to a download client
  # without duplicating the config lookup, adapter lookup and config_to_map
  # conversion for a sixth time.
  @spec resolve_adapter(String.t() | nil) :: {:ok, module(), map()} | {:error, term()}
  def resolve_adapter(nil), do: {:error, :no_client}

  def resolve_adapter(client_name) do
    with {:ok, client_config} <- find_client_config(client_name),
         {:ok, adapter} <- get_adapter_for_client(client_config) do
      {:ok, adapter, config_to_map(client_config)}
    end
  end

  # Selects appropriate client and adds the download, with smart fallback if type is detected.
  # For a torrent whose adapter can list files, only the wanted files are added
  # (see Mydia.Downloads.WantedFiles); the selection, or nil, is returned last
  # so callers can record it on the download.
  @doc false
  # Public so Mydia.Downloads.Grabber can reuse the fetch/select/add pipeline.
  @spec select_and_add_to_client(SearchResult.t(), keyword()) ::
          {:ok, map(), String.t(), atom() | nil, WantedFiles.t() | nil} | {:error, term()}
  def select_and_add_to_client(search_result, opts) do
    with {:ok, config, client_id, type, selection, _created?} <-
           add_to_client(search_result, opts),
         do: {:ok, config, client_id, type, selection}
  end

  @doc false
  # `select_and_add_to_client/2`, plus whether the add created the torrent:
  # false when the client already held it, since an add of a known hash
  # returns the existing torrent as a success. Only a created torrent may be
  # undone (see `undo_add/3`).
  @spec add_to_client(SearchResult.t(), keyword()) ::
          {:ok, map(), String.t(), atom() | nil, WantedFiles.t() | nil, boolean()}
          | {:error, term()}
  #
  # With `file_preview: %Queue.FilePreview{}` and `only_files: [index]` the
  # torrent input, client, listing and peers come from the preview, and the
  # operator's choice replaces the automatic one (see `FilePreview.confirm/2`).
  def add_to_client(search_result, opts) do
    case Keyword.get(opts, :file_preview) do
      nil ->
        with {:ok, prepared} <- prepare(search_result, opts) do
          files =
            select_files(
              prepared.adapter,
              config_to_map(prepared.client_config),
              torrent_input(prepared.torrent_input_result),
              prepared.download_type,
              search_result,
              prepared.opts
            )

          add_with_client(prepared, files, search_result)
        end

      preview ->
        with {:ok, prepared, files} <- FilePreview.confirm(preview, opts),
             do: add_with_client(prepared, files, search_result)
    end
  end

  @doc false
  # The first half of `add_to_client/2`: fetch the torrent or NZB, refuse a
  # banned hash, settle the download type, title and content type, and choose
  # the client. Shared with `Queue.FilePreview`, which lists files from here
  # without adding anything.
  @spec prepare(SearchResult.t(), keyword()) ::
          {:ok,
           %{
             torrent_input_result: term(),
             download_type: atom() | nil,
             opts: keyword(),
             client_config: map(),
             adapter: module()
           }}
          | {:error, term()}
  def prepare(search_result, opts) do
    download_type = Keyword.get(opts, :download_type)

    # First, prepare the torrent/nzb input (download file if needed)
    # Pass the indexer name for authentication
    with {:ok, torrent_input_result} <-
           TorrentFetch.prepare_torrent_input(search_result.download_url, search_result.indexer),
         :ok <- TorrentFetch.refuse_banned_info_hash(torrent_input_result, search_result, opts) do
      # Extract detected type from the downloaded content
      detected_type =
        case torrent_input_result do
          {:file, _body, type} -> type
          _ -> nil
        end

      # Use detected type as fallback if download_type is nil
      final_download_type = download_type || detected_type

      Logger.info(
        "File type detection: original=#{inspect(download_type)}, detected=#{inspect(detected_type)}, final=#{inspect(final_download_type)}"
      )

      # Resolve a content type (e.g. "tv", "movie") so per-content-type
      # routing in the client config can pick the right category. See
      # `resolve_content_type/1` for the precedence rules.
      content_type = resolve_content_type(opts)

      # Update opts with the final download type and title
      opts_with_type =
        opts
        |> Keyword.put(:download_type, final_download_type)
        |> Keyword.put(:title, search_result.title)
        |> Keyword.put(:content_type, content_type)

      # Now select the appropriate client based on the final type
      with {:ok, client_config} <- select_download_client(opts_with_type),
           {:ok, adapter} <- get_adapter_for_client(client_config) do
        {:ok,
         %{
           torrent_input_result: torrent_input_result,
           download_type: final_download_type,
           opts: opts_with_type,
           client_config: client_config,
           adapter: adapter
         }}
      end
    end
  end

  @doc false
  # The prepared input without its detected type, as adapters take it.
  def torrent_input({:file, body, _type}), do: {:file, body}
  def torrent_input(other), do: other

  @doc false
  # True when the client `select_client_by_priority(:torrent)` picks can
  # list and select a torrent's files, so a manual grab can offer the choice.
  @spec file_choice_available?() :: boolean()
  def file_choice_available? do
    with %{} = client_config <- select_client_by_priority(:torrent),
         {:ok, adapter} <- get_adapter_for_client(client_config) do
      Client.supports_file_selection?(adapter)
    else
      _none -> false
    end
  end

  # The add itself, once the client is chosen and the files are picked
  # (`{selection | nil, peers, listed_files}`): guard the disk, note whether
  # the client already held the torrent, then add.
  defp add_with_client(prepared, {selection, peers, listed}, search_result) do
    %{
      adapter: adapter,
      client_config: client_config,
      torrent_input_result: torrent_input_result,
      download_type: final_download_type,
      opts: opts_with_type
    } = prepared

    torrent_input = torrent_input(torrent_input_result)

    add_opts =
      opts_with_type
      |> Keyword.put(:only_files, add_only_files(selection, listed))
      |> Keyword.put(:initial_peers, peers)

    with :ok <- check_space(client_config, selection, search_result, opts_with_type),
         before_add = presence(adapter, client_config, torrent_input_result),
         {:ok, client_id} <-
           add_torrent_to_client_with_input(adapter, client_config, torrent_input, add_opts) do
      created? = created?(before_add, client_id)
      # Best effort; the removal guard applies whatever the client says.
      terms = TrackerRules.for_result(search_result)
      SeedingLimits.push(adapter, config_to_map(client_config), client_id, terms)
      {:ok, client_config, client_id, final_download_type, selection, created?}
    end
  end

  # Lists a torrent's files and decides which ones to download. Returns
  # `{selection | nil, peers, listed_files}`; peers and files are only returned
  # by a successful listing. Any failure means "add every file": the selection
  # is an optimisation, never a reason to refuse a grab.
  defp select_files(adapter, config, torrent_input, download_type, search_result, opts) do
    if torrent_input?(torrent_input, download_type) do
      case Client.list_torrent_files(adapter, config, torrent_input) do
        {:ok, %{files: files, peers: peers}} ->
          {safe_select(search_result, files, opts), peers, files}

        {:error, :unsupported} ->
          {nil, nil, []}

        {:error, reason} ->
          Logger.warning("Could not list torrent files; adding every file",
            title: search_result.title,
            reason: inspect(reason)
          )

          {nil, nil, []}
      end
    else
      {nil, nil, []}
    end
  end

  # What the client held before the add, so `created?/2` can tell an add that
  # created a torrent from one that returned a torrent already there (an add
  # of a known hash succeeds with the existing id). An NZB always creates a
  # job. `{:absent, hash}` only on an explicit not-found for the info hash;
  # anything else, including a hash that cannot be read or a client that
  # cannot be asked, is `:unknown`, and an unknown add is never undone.
  defp presence(_adapter, _client_config, {:file, _body, :nzb}), do: :new_job

  defp presence(adapter, client_config, input) do
    config = config_to_map(client_config)

    # Clients disagree on the hash's case (rTorrent keys by upper-case and
    # finds nothing under lower-case), so absence needs both forms not found.
    with hash when is_binary(hash) <- TorrentFetch.prepared_info_hash(input),
         true <- absent?(Client.get_status(adapter, config, hash)),
         true <- absent?(Client.get_status(adapter, config, String.upcase(hash))) do
      {:absent, hash}
    else
      _unknown -> :unknown
    end
  rescue
    _error -> :unknown
  catch
    :exit, _reason -> :unknown
  end

  # The lookup is by info hash, so it says nothing about a client that keys
  # torrents by its own id (a debrid provider's job id): the add created the
  # torrent only when the client answered with that same hash.
  defp created?(:new_job, _client_id), do: true

  defp created?({:absent, hash}, client_id) when is_binary(client_id),
    do: String.downcase(client_id) == hash

  defp created?(_presence, _client_id), do: false

  # Only an explicit not-found proves absence; a status that failed any other
  # way (refused, timed out, server error) leaves it unknown.
  defp absent?({:error, %Client.Error{type: :not_found}}), do: true
  defp absent?(_status), do: false

  # A selection that keeps every file leaves `only_files` nil, but the add
  # still names every listed file: rqbit keeps an older, narrower selection on
  # a torrent it already manages unless the add asks for something explicit.
  # Without a listing (or a selection) nothing is sent, as before.
  defp add_only_files(%WantedFiles{only_files: nil}, [_ | _] = listed),
    do: listed |> Enum.map(& &1.index) |> Enum.sort()

  defp add_only_files(%WantedFiles{only_files: only_files}, _listed), do: only_files

  # Listing worked but the selection raised: the fallback promises every file,
  # so name them all rather than let a narrower managed selection stand.
  defp add_only_files(nil, [_ | _] = listed), do: listed |> Enum.map(& &1.index) |> Enum.sort()
  defp add_only_files(nil, _listed), do: nil

  defp torrent_input?({:magnet, _}, download_type), do: download_type in [nil, :torrent]
  defp torrent_input?(_input, download_type), do: download_type == :torrent

  defp safe_select(search_result, files, opts) do
    search_result
    |> WantedFiles.context_for(opts)
    |> WantedFiles.select(files)
  rescue
    error ->
      Logger.warning("File selection failed; adding every file",
        title: search_result.title,
        error: Exception.message(error)
      )

      nil
  end

  # Disk guard: refuses a grab the built-in client's download volume cannot
  # hold, keeping `min_free_space_bytes` free. Anything unmeasurable passes.
  defp check_space(client_config, selection, search_result, opts) do
    with true <- BuiltIn.managed?(config_to_map(client_config)),
         %{config: %{download_path: path, min_free_space_bytes: reserve}} when reserve > 0 <-
           BuiltIn.runtime(),
         needed when is_integer(needed) <- space_needed(selection, search_result) do
      free_fun = Keyword.get(opts, :free_bytes, &DiskSpace.free_bytes/1)

      case free_fun.(path) do
        {:ok, free} when needed + reserve > free ->
          {:error, {:client_error, insufficient_space_error(needed, free, reserve)}}

        {:ok, _free} ->
          :ok

        {:error, reason} ->
          Logger.warning("Could not measure free space; skipping the disk guard",
            path: path,
            reason: inspect(reason)
          )

          :ok
      end
    else
      _ -> :ok
    end
  end

  defp space_needed(%WantedFiles{selected_bytes: bytes}, _search_result), do: bytes

  defp space_needed(nil, %SearchResult{size: size}) when is_integer(size) and size > 0, do: size
  defp space_needed(_selection, _search_result), do: nil

  defp insufficient_space_error(needed, free, reserve) do
    message =
      "Not enough space on the download volume: needs #{DiskSpace.format_gb(needed)}, " <>
        "#{DiskSpace.format_gb(free)} free, #{div(reserve, @gb)} GB kept free"

    Client.Error.insufficient_space(message, %{needed: needed, free: free, reserve: reserve})
  end

  # Version of add_torrent_to_client that accepts pre-downloaded input
  defp add_torrent_to_client_with_input(adapter, client_config, torrent_input, opts) do
    client_map_config = config_to_map(client_config)
    content_type = Keyword.get(opts, :content_type)
    category = resolve_category(client_config, content_type, opts)
    title = Keyword.get(opts, :title)

    # Values go in the message, not metadata: the default formatter drops
    # metadata, and "why was this added without a category" (#1442) should be
    # answerable from a plain log.
    Logger.info(
      "Adding to download client: client=#{inspect(client_config.name)} " <>
        "content_type=#{inspect(content_type)} category=#{category_label(category)}"
    )

    priority = Keyword.get(opts, :priority, Priority.default())

    torrent_opts =
      []
      |> TorrentFetch.maybe_add_opt(:category, category)
      |> TorrentFetch.maybe_add_opt(:title, title)
      |> TorrentFetch.maybe_add_opt(:priority, priority)
      |> TorrentFetch.maybe_add_opt(:only_files, Keyword.get(opts, :only_files))
      |> TorrentFetch.maybe_add_opt(:initial_peers, Keyword.get(opts, :initial_peers))

    case Client.add_torrent(adapter, client_map_config, torrent_input, torrent_opts) do
      {:ok, client_id} ->
        {:ok, client_id}

      {:error, error} ->
        {:error, {:client_error, error}}
    end
  end

  defp category_label(category) when is_binary(category) and category != "",
    do: inspect(category)

  defp category_label(_none), do: "none"

  @doc false
  # Resolves the per-content-type category from the client config, falling back
  # to the legacy single-value `:category` field for backwards compatibility.
  # Order of precedence:
  #   1. explicit `opts[:category]` (manual override, rare)
  #   2. `client_config.categories[content_type]`
  #   3. `client_config.category` (legacy field)
  #   4. nil
  # Public-but-undocumented so tests can exercise it without round-tripping
  # through `initiate_download/2`.
  def resolve_category(client_config, content_type, opts) do
    cond do
      Keyword.has_key?(opts, :category) ->
        Keyword.get(opts, :category)

      is_binary(content_type) ->
        categories = client_config.categories || %{}

        case Map.get(categories, content_type) do
          nil -> client_config.category
          "" -> client_config.category
          value -> value
        end

      true ->
        client_config.category
    end
  end

  @doc false
  # Derives a content_type string from the download options + media context.
  # Centralised here so new content types (e.g. "music") can be added in one
  # place. Returns a string ("tv", "movie") or nil when the type cannot be
  # determined from the available context.
  # Public-but-undocumented for testability.
  def resolve_content_type(opts) do
    cond do
      Keyword.get(opts, :episode_id) ->
        "tv"

      media_item_id = Keyword.get(opts, :media_item_id) ->
        case Repo.get(MediaItem, media_item_id) do
          %MediaItem{type: "movie"} -> "movie"
          %MediaItem{type: "tv_show"} -> "tv"
          _ -> content_type_from_download_type(Keyword.get(opts, :download_type))
        end

      true ->
        content_type_from_download_type(Keyword.get(opts, :download_type))
    end
  end

  # Best-effort fallback when we can't resolve from media_item / episode.
  # Returns nil when the protocol gives us nothing useful, so the caller will
  # fall back to the legacy single `category` field via `resolve_category/3`.
  defp content_type_from_download_type(_), do: nil

  defp select_download_client(opts) do
    client_name = Keyword.get(opts, :client_name)
    download_type = Keyword.get(opts, :download_type)

    # Use specific client if requested
    if client_name do
      case find_client_by_name(client_name) do
        nil -> {:error, {:client_not_found, client_name}}
        client -> {:ok, client}
      end
    else
      # Otherwise select by priority, filtered by download type
      case select_client_by_priority(download_type) do
        nil -> {:error, :no_clients_configured}
        client -> {:ok, client}
      end
    end
  end

  defp find_client_by_name(name) do
    Settings.list_download_client_configs()
    |> Enum.find(&(&1.name == name && &1.enabled))
  end

  # Lowest priority wins. On a tie the built-in client wins: external clients
  # default to 1, the lowest a priority can be, so otherwise the built-in one
  # could never be made the default (issue #1422).
  @doc false
  # Public for testing.
  def select_client_by_priority(download_type) do
    client =
      Settings.list_download_client_configs()
      |> Enum.filter(&(&1.enabled and supports_download_type?(&1, download_type)))
      |> Enum.sort_by(&{&1.priority, not BuiltIn.managed?(&1)}, :asc)
      |> List.first()

    if client do
      Logger.info(
        "Selected download client: #{client.name} (type: #{client.type}, priority: #{client.priority}) for download_type: #{download_type}"
      )
    else
      Logger.warning("No suitable client found for download_type: #{download_type}")
    end

    client
  end

  # Public-but-undocumented for testability.
  #
  # Asks the adapter what protocols it accepts and matches against the
  # search result's resolved download_type. When download_type is nil (we
  # couldn't sniff it from the payload), every client is eligible — the
  # adapter's `add_torrent/3` will reject mismatched payloads.
  def supports_download_type?(_client, nil), do: true

  def supports_download_type?(client, download_type) do
    case Registry.get_adapter(client.type) do
      {:ok, adapter} ->
        # `function_exported?/3` returns false for modules that haven't been
        # loaded yet (it doesn't auto-load). In production every adapter is
        # loaded during application boot via Mydia.Downloads.register_clients/0,
        # but in tests modules load lazily and the check would falsely
        # report "not supported". `Code.ensure_loaded?/1` forces a load
        # before the predicate runs.
        Code.ensure_loaded?(adapter) and
          function_exported?(adapter, :supported_protocols, 0) and
          download_type in adapter.supported_protocols()

      {:error, _} ->
        false
    end
  end

  @doc false
  def get_adapter_for_client(client_config) do
    case Registry.get_adapter(client_config.type) do
      {:ok, adapter} ->
        Logger.info("Using adapter #{inspect(adapter)} for client type #{client_config.type}")
        {:ok, adapter}

      {:error, _} = error ->
        error
    end
  end

  @doc false
  # Builds the metadata map persisted on a Download for a search result.
  # Public so the optimistic grab pipeline (Mydia.Downloads.Grabber) can build
  # identical records without going through the synchronous pipeline.
  def build_download_metadata(%SearchResult{} = search_result) do
    search_result = %{
      search_result
      | metadata: Duplicates.normalize_metadata(search_result.metadata)
    }

    metadata_attrs = %{
      size: search_result.size,
      seeders: search_result.seeders,
      leechers: search_result.leechers,
      quality: search_result.quality,
      download_protocol: search_result.download_protocol
    }

    metadata_attrs =
      case search_result.metadata do
        %SearchResultMetadata{season_pack: true, season_number: season_number} = m ->
          Map.merge(metadata_attrs, %{
            season_pack: true,
            season_number: season_number,
            episode_count: m.episode_count,
            episode_ids: m.episode_ids
          })

        _ ->
          metadata_attrs
      end

    metadata_attrs
    |> DownloadMetadata.new()
    |> DownloadMetadata.to_map()
    |> Map.put(:indexer, search_result.indexer)
    |> Map.put(:guid, Blacklists.release_guid(search_result))
    |> put_tracker_terms(search_result)
  end

  # The terms in force at grab, overrides applied, are frozen on the download:
  # a later override never changes the rules of a torrent already seeding.
  defp put_tracker_terms(metadata, search_result) do
    case TrackerRules.for_result(search_result) do
      nil -> metadata
      terms -> Map.put(metadata, :tracker_terms, TrackerTerms.to_map(terms))
    end
  end

  defp create_download_record(search_result, client_config, client_id, opts) do
    metadata =
      search_result
      |> build_download_metadata()
      |> Map.merge(WantedFiles.to_metadata(Keyword.get(opts, :wanted_files)))

    attrs = %{
      indexer: search_result.indexer,
      title: search_result.title,
      download_url: search_result.download_url,
      download_client: client_config.name,
      download_client_id: client_id,
      media_item_id: Keyword.get(opts, :media_item_id),
      episode_id: Keyword.get(opts, :episode_id),
      library_path_id: Keyword.get(opts, :library_path_id),
      metadata: metadata
    }

    History.create_download(attrs)
  end

  @doc false
  def create_download_record_with_retry(search_result, client_config, client_id, opts) do
    case create_download_record(search_result, client_config, client_id, opts) do
      {:ok, download} ->
        {:ok, download}

      {:error, %Ecto.Changeset{} = changeset}
      when is_struct(changeset, Ecto.Changeset) ->
        if has_unique_constraint_error?(changeset, :download_client) do
          Logger.warning(
            "Unique constraint on download_client_id, cleaning stale record and retrying",
            client: client_config.name,
            client_id: client_id
          )

          case find_stale_download(client_config.name, client_id) do
            nil ->
              {:error, changeset}

            stale_download ->
              Logger.info("Deleting stale download record",
                download_id: stale_download.id,
                title: stale_download.title
              )

              History.delete_download(stale_download)
              create_download_record(search_result, client_config, client_id, opts)
          end
        else
          {:error, changeset}
        end

      error ->
        error
    end
  end

  defp has_unique_constraint_error?(%Ecto.Changeset{} = changeset, field) do
    Enum.any?(changeset.errors, fn
      {^field, {_msg, opts}} -> Keyword.get(opts, :constraint) == :unique
      _ -> false
    end)
  end

  @doc false
  # A grab adds the torrent before it saves the row that tracks it. When the
  # save fails, most often because the item or the row was deleted mid-grab,
  # nothing else will ever remove that torrent: the delete only cancels the
  # torrents its rows name. So the add is undone here, data included, since
  # the torrent is seconds old and nobody wants it.
  #
  # Only a torrent the add created goes (`created?`, from `add_to_client/2`):
  # one the client already held is someone else's, tracked or not. Ownership is
  # also read again here, for a row that claimed the torrent since the add. A
  # grab saving it in the instant between that read and the client call can
  # still lose it; closing that would take a lock around the client.
  # Best effort: a client that refuses or exits is logged and the grab's error
  # stands.
  @spec undo_add(map(), String.t(), boolean()) :: :ok
  def undo_add(_client_config, _client_id, false = _created?), do: :ok

  def undo_add(client_config, client_id, true = _created?) do
    if tracked?(client_config.name, client_id),
      do: :ok,
      else: remove_untracked(client_config, client_id)
  end

  defp tracked?(client_name, client_id) do
    Download
    |> where([d], d.download_client == ^client_name and d.download_client_id == ^client_id)
    |> Repo.exists?()
  end

  defp remove_untracked(client_config, client_id) do
    with {:ok, adapter} <- get_adapter_for_client(client_config),
         :ok <-
           Client.remove_download(adapter, config_to_map(client_config), client_id,
             delete_files: true
           ) do
      Logger.info("Removed a torrent whose download record could not be saved",
        client: client_config.name,
        client_id: client_id
      )
    else
      error ->
        Logger.warning("Could not remove an untracked torrent after a failed grab",
          client: client_config.name,
          client_id: client_id,
          reason: inspect(error)
        )
    end

    :ok
  catch
    # An adapter can exit (a debrid fetcher whose supervisor is down); the
    # grab's own error must still stand.
    :exit, reason ->
      Logger.warning("Could not remove an untracked torrent after a failed grab",
        client: client_config.name,
        client_id: client_id,
        reason: inspect({:exit, reason})
      )

      :ok
  end

  defp find_stale_download(client_name, client_id) do
    Download
    |> where([d], d.download_client == ^client_name and d.download_client_id == ^client_id)
    |> Repo.one()
  end

  @doc false
  # The adapter and connection map for an enabled client, by name. Shared with
  # Mydia.Downloads.Removal so the removal job talks to the client exactly as
  # cancel_download/2 does.
  @spec client_for(String.t()) :: {:ok, module(), map()} | {:error, :no_client}
  def client_for(client_name) do
    with {:ok, client_config} <- find_client_config(client_name),
         {:ok, adapter} <- get_adapter_for_client(client_config) do
      {:ok, adapter, config_to_map(client_config)}
    else
      _no_client -> {:error, :no_client}
    end
  end

  @doc false
  def find_client_config(client_name) do
    case find_client_by_name(client_name) do
      nil -> {:error, {:client_not_found, client_name}}
      client -> {:ok, client}
    end
  end

  @doc false
  def config_to_map(config) do
    %{
      type: config.type,
      host: config.host,
      port: config.port,
      use_ssl: config.use_ssl,
      username: config.username,
      password: config.password,
      url_base: config.url_base,
      api_key: config.api_key,
      connection_settings: config.connection_settings || %{},
      options: config.connection_settings || %{},
      # Surfaced for adapters that need per-client policy (priority routing,
      # per-content-type categories, stall grace). Adapters that don't care
      # about these fields simply ignore them.
      categories: Map.get(config, :categories) || %{},
      priority_profile: Map.get(config, :priority_profile) || %{},
      incomplete_grace_minutes: Map.get(config, :incomplete_grace_minutes)
    }
  end
end
