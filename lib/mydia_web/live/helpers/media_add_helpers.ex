defmodule MydiaWeb.Live.Helpers.MediaAddHelpers do
  @moduledoc """
  Shared LiveView helpers for the "Add to Library" flow.

  Used by DashboardLive, DiscoverLive and the media detail franchise panel.
  The actual provider-fetch-and-create work lives in `Mydia.Media.Add`, which
  request approval shares.
  """

  require Logger

  alias Mydia.Media.Add
  alias Mydia.Media.AddDefaults
  alias Mydia.Media.FranchiseEntry
  alias Mydia.Metadata
  alias Mydia.Metadata.Structs.SearchResult
  alias Mydia.Settings

  @doc """
  Libraries a caller may pick as the add-time target for `media_type`.

  Filters to monitored, type-compatible libraries and drops unmaterialised
  runtime entries: those carry synthetic "runtime::" ids and have no
  `library_paths` row for a foreign key to reference. `LibraryPathSync` upserts
  env-configured paths into real rows at startup, so this list is complete in
  practice.
  """
  @spec candidate_libraries(:movie | :tv_show) :: [Mydia.Settings.LibraryPath.t()]
  def candidate_libraries(media_type) do
    kind = if media_type == :movie, do: :movies, else: :series
    allowed = Mydia.Library.TargetResolver.allowed_types(kind)

    Settings.list_library_paths()
    |> Enum.filter(fn lp ->
      lp.type in allowed and lp.monitored and
        not String.starts_with?(to_string(lp.id), "runtime::")
    end)
  end

  @doc """
  Add options for a client-supplied `library_path_id`.

  Three cases have to stay distinct, which is why this returns a tagged tuple
  rather than a bare keyword list: no choice was made, a valid choice was made,
  or a choice was made that this server will not honour. Only the third is
  worth telling the user about, and #458 was filed because a silently ignored
  choice is worse than no picker at all.

  Only `nil` and `""` mean "no choice was made". `nil` is what an ordinary
  "Add to Library" click sends, since the form has no picker to include a
  `library_path_id` at all; `""` is the picker's own placeholder option. Any
  other shape, including a non-binary value such as a map, list, or integer,
  is a malformed target and is rejected rather than silently treated as "no
  choice".

  The blank-string clause is the reason this function exists. `""` is truthy in
  Elixir, so without it the value reaches the changeset as
  `library_path_id: ""` and fails the foreign key rather than falling back to
  normal target resolution.

  The candidate check is authorization, not convenience. This value arrives in
  event params, so without it a crafted event can name any `library_paths` row,
  including one of the wrong type for the media being added.
  """
  @spec library_path_opts(term(), :movie | :tv_show) ::
          {:ok, keyword()} | {:error, :unknown_library}
  def library_path_opts(library_path_id, media_type)

  def library_path_opts(nil, _media_type), do: {:ok, []}
  def library_path_opts("", _media_type), do: {:ok, []}

  def library_path_opts(id, media_type) when is_binary(id) and id != "" do
    if Enum.any?(candidate_libraries(media_type), &(to_string(&1.id) == id)) do
      {:ok, [library_path_id: id]}
    else
      {:error, :unknown_library}
    end
  end

  def library_path_opts(_library_path_id, _media_type), do: {:error, :unknown_library}

  @doc """
  Enriches a list of search result items with library status information.

  For each item, adds `:in_library`, `:monitored`, and `:id` fields
  based on the library_status_map.
  """
  def enrich_with_library_status(items, library_status_map) do
    Enum.map(items, fn item ->
      provider_id_int = Add.parse_provider_id(item.provider_id)

      library_status =
        Map.get(library_status_map, provider_id_int) ||
          Map.get(library_status_map, {:tvdb, provider_id_int}) ||
          %{in_library: false}

      Map.merge(item, %{
        in_library: library_status[:in_library] || false,
        monitored: library_status[:monitored] || false,
        id: library_status[:id]
      })
    end)
  end

  @doc """
  Builds media item attrs from metadata. See `Mydia.Media.Add.build_media_item_attrs/3`.
  """
  defdelegate build_media_item_attrs(metadata, media_type, opts \\ []), to: Add

  @doc """
  Handles the full add-media-to-library flow.

  Returns `{:ok, media_item, updated_library_status_map}`,
  `{:already_in_library, media_item, updated_library_status_map}`, or
  `{:error, reason}`, where reason is `{:metadata, term()}` or
  `{:changeset, Ecto.Changeset.t()}`.

  The `:already_in_library` tuple is not an error from a caller's point of
  view: the show the user asked for is in the library, just under a row that
  was already there. Callers should flash it as info rather than an error.

  An optional `config` (relay config map) can be injected for testing; it
  defaults to `Metadata.default_relay_config()`.

  `opts` are forwarded to `Mydia.Media.Add`, except `:search_on_add`, which is
  popped off first: `Add` does not accept it. `:monitored`,
  `:quality_profile_id` and `:library_path_id` let a caller inherit settings
  from an item the user is already looking at, or pin an explicit target
  library. TV shows ignore monitored and quality profile today.

  On a successful add, queues an automatic indexer search when
  `:search_on_add` is true. A queue failure is logged and does not fail the
  add: adding the title is what the user asked for, the search is a
  convenience on top of it.
  """
  def handle_add_media_to_library(
        provider_id,
        media_type,
        library_status_map,
        config \\ nil,
        opts \\ []
      ) do
    {search_on_add, add_opts} = Keyword.pop(opts, :search_on_add, false)
    provider_id_int = Add.parse_provider_id(provider_id)

    case Add.from_provider(provider_id, media_type, config, add_opts) do
      {:ok, media_item} ->
        maybe_queue_search(media_item, search_on_add)

        {:ok, media_item,
         update_library_status_map(library_status_map, media_item, provider_id_int)}

      # Not an error from here up: the show the user asked for is in the
      # library. Callers flash it as info and flip the card.
      {:error, {:already_in_library, media_item}} ->
        {:already_in_library, media_item,
         update_library_status_map(library_status_map, media_item, provider_id_int)}

      {:error, _} = error ->
        error
    end
  end

  # This is the shared home for auto-search-on-add. AddMediaLive used to carry
  # a near-identical private maybe_queue_search/2, but that module was deleted
  # once Discover absorbed one-click add, so this is the only copy now. Uses
  # Search.queue_auto_searches/1 rather than enqueuing directly: it is already
  # Oban-dedupe-safe (singular insert/1, not insert_all/1) and is what the
  # media detail page uses.
  #
  # A failure leaves the item added. Adding the title is what the user asked
  # for; the search is a convenience.
  defp maybe_queue_search(_media_item, false), do: :ok

  defp maybe_queue_search(media_item, true) do
    case Mydia.Search.queue_auto_searches([media_item]) do
      {:ok, _count} ->
        :ok

      {:error, reason} ->
        Logger.warning("Failed to queue search on add",
          media_item_id: media_item.id,
          reason: inspect(reason)
        )

        :ok
    end
  end

  @doc """
  Fetches detailed metadata for the detail modal.

  For TV shows, the preview reflects the provider the add flow will use: when
  the derived source is `:tmdb` the TMDB metadata is returned directly;
  otherwise it tries to resolve richer TVDB metadata, falling back to TMDB if
  that lookup fails.

  For movies, fetches TMDB metadata directly.

  An optional `config` can be injected for testing; defaults to
  `Metadata.default_relay_config()`.
  """
  def fetch_detail_metadata(tmdb_id, media_type, config \\ nil) do
    config = config || Metadata.default_relay_config()

    if media_type == :tv_show do
      case Metadata.fetch_by_id(config, tmdb_id, media_type: :tv_show, provider: :tmdb) do
        {:ok, tmdb_metadata} ->
          if Settings.derive_tv_metadata_source() == :tmdb do
            {:ok, tmdb_metadata}
          else
            case Add.resolve_tvdb_metadata(tmdb_metadata, config) do
              {:ok, tvdb_metadata, _tvdb_id} -> {:ok, tvdb_metadata}
              {:error, _} -> {:ok, tmdb_metadata}
            end
          end

        error ->
          error
      end
    else
      Metadata.fetch_by_id(config, tmdb_id, media_type: :movie)
    end
  end

  @doc """
  Formats changeset errors into a human-readable string.
  """
  def format_changeset_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc_msg ->
        String.replace(acc_msg, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
  end

  @doc """
  Builds the merged dialog's preview panel for one clicked card.

  `candidate_lists` are the item collections the host already holds in assigns.
  They are searched in order, so a host passes its grid before its rail.

  The lists hold three different shapes. Discover and Dashboard carry
  `SearchResult` structs and enriched maps built from them; the detail page's
  franchise strip carries `FranchiseEntry`, which has no `overview` field and
  is keyed on `tmdb_id` rather than `provider_id`.

  A miss falls back to the title the caret sends in `phx-value-title`, which is
  all the dialog strictly needs. A nil poster resolves to the placeholder in
  `AddMediaComponents.get_poster_url/1`.
  """
  @spec preview_for([list()], term(), String.t() | nil) :: %{
          title: String.t(),
          year: integer() | nil,
          poster_path: String.t() | nil,
          overview: String.t() | nil
        }
  def preview_for(candidate_lists, provider_id, fallback_title) do
    id = to_string(provider_id)

    candidate_lists
    |> Enum.concat()
    |> Enum.find(&(entry_id(&1) == id))
    |> case do
      nil -> %{title: fallback_title || "", year: nil, poster_path: nil, overview: nil}
      entry -> preview_entry(entry)
    end
  end

  @doc """
  Opens the merged Configure Before Adding dialog for one card.

  The candidate libraries are read here rather than carried from mount, so a
  library added or unmonitored since the page loaded must not show up as a
  stale option.

  An unrecognised media type returns the socket untouched. The caret only ever
  sends "movie" or "tv_show", so anything else is a forged event and opening a
  dialog on it would be worse than doing nothing.
  """
  @spec put_add_config(Phoenix.LiveView.Socket.t(), map(), Mydia.Accounts.User.t() | nil, [
          list()
        ]) :: Phoenix.LiveView.Socket.t()
  def put_add_config(socket, params, user, candidate_lists)

  def put_add_config(
        socket,
        %{"tmdb_id" => provider_id, "media_type" => media_type} = params,
        user,
        candidate_lists
      ) do
    case media_type do
      "movie" -> assign_add_config(socket, provider_id, :movie, params, user, candidate_lists)
      "tv_show" -> assign_add_config(socket, provider_id, :tv_show, params, user, candidate_lists)
      _ -> socket
    end
  end

  def put_add_config(socket, _params, _user, _candidate_lists), do: socket

  @doc """
  Closes the merged dialog.
  """
  @spec clear_add_config(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def clear_add_config(socket) do
    Phoenix.Component.assign(socket, :add_config, nil)
  end

  @doc """
  Turns the dialog's submitted `config[...]` params into `Mydia.Media.Add` opts.

  `library_path_opts/2` runs first and its rejection is propagated rather than
  swallowed. That call is authorization, not convenience: the value arrives in
  event params, so without it a crafted submit can name any `library_paths`
  row, including one of the wrong type for the media being added.

  A rejected quality profile is deliberately quieter. `AddDefaults` validates it
  through `Settings.quality_profile_exists?/1` and falls back to the instance
  default, because a stale profile still produces a usable add where a
  wrong-type library path does not.

  `:search_on_add` is put back onto the list after `to_add_opts/1`, which omits
  it because `Add` does not accept it.
  """
  @spec add_opts_from_config(map(), :movie | :tv_show, Mydia.Accounts.User.t() | nil) ::
          {:ok, keyword()} | {:error, :unknown_library}
  def add_opts_from_config(params, media_type, user) do
    with {:ok, library_opts} <-
           library_path_opts(presence(params["library_path_id"]), media_type) do
      defaults =
        AddDefaults.resolve(user, media_type,
          library_path_id: library_opts[:library_path_id],
          quality_profile_id: presence(params["quality_profile_id"]),
          monitored: params["monitored"] == "true",
          season_monitoring: presence(params["season_monitoring"]),
          search_on_add: params["search_on_add"] == "true"
        )

      {:ok,
       defaults
       |> AddDefaults.to_add_opts()
       |> Keyword.put(:search_on_add, defaults.search_on_add)}
    end
  end

  # Private helpers

  defp assign_add_config(socket, provider_id, media_type, params, user, candidate_lists) do
    Phoenix.Component.assign(socket, :add_config, %{
      provider_id: provider_id,
      media_type: media_type,
      defaults: AddDefaults.resolve(user, media_type),
      preview: preview_for(candidate_lists, provider_id, params["title"]),
      libraries: candidate_libraries(media_type)
    })
  end

  defp entry_id(%FranchiseEntry{tmdb_id: id}) when not is_nil(id), do: to_string(id)
  defp entry_id(%{provider_id: id}) when not is_nil(id), do: to_string(id)
  defp entry_id(_entry), do: nil

  defp preview_entry(%SearchResult{} = item) do
    %{
      title: item.title || item.name,
      year: item.year,
      poster_path: item.poster_path,
      overview: item.overview
    }
  end

  defp preview_entry(%FranchiseEntry{} = entry) do
    %{title: entry.title, year: entry.year, poster_path: entry.poster_path, overview: nil}
  end

  defp preview_entry(entry) when is_map(entry) do
    %{
      title: Map.get(entry, :title) || Map.get(entry, :name),
      year: Map.get(entry, :year),
      poster_path: Map.get(entry, :poster_path),
      overview: Map.get(entry, :overview)
    }
  end

  defp presence(nil), do: nil
  defp presence(""), do: nil
  defp presence(value), do: value

  defp update_library_status_map(library_status_map, media_item, tmdb_id_int) do
    entry = %{
      in_library: true,
      monitored: media_item.monitored,
      type: media_item.type,
      id: media_item.id
    }

    map = Map.put(library_status_map, tmdb_id_int, entry)

    if media_item.tvdb_id do
      Map.put(map, {:tvdb, media_item.tvdb_id}, entry)
    else
      map
    end
  end
end
