defmodule MydiaWeb.Live.Helpers.MediaAddHelpers do
  @moduledoc """
  Shared LiveView helpers for the "Add to Library" flow.

  Used by DashboardLive, DiscoverLive and the media detail franchise panel.
  The actual provider-fetch-and-create work lives in `Mydia.Media.Add`, which
  request approval shares.
  """

  require Logger

  alias Mydia.Media.Add
  alias Mydia.Metadata
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
  Opens the library picker dialog for one card.

  The candidate list is read here rather than carried from mount, so a library
  added or unmonitored since the page loaded cannot show up as a stale option.

  An unrecognised media type returns the socket untouched: the caret only ever
  sends "movie" or "tv_show", so anything else is a forged event and opening a
  dialog with an empty list would be worse than doing nothing.
  """
  @spec put_library_picker(Phoenix.LiveView.Socket.t(), map()) :: Phoenix.LiveView.Socket.t()
  def put_library_picker(socket, %{"tmdb_id" => tmdb_id, "media_type" => media_type} = params) do
    case media_type do
      "movie" -> assign_library_picker(socket, tmdb_id, :movie, params["title"])
      "tv_show" -> assign_library_picker(socket, tmdb_id, :tv_show, params["title"])
      _ -> socket
    end
  end

  def put_library_picker(socket, _params), do: socket

  @doc """
  Closes the library picker dialog.
  """
  @spec clear_library_picker(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
  def clear_library_picker(socket) do
    Phoenix.Component.assign(socket, :library_picker, nil)
  end

  defp assign_library_picker(socket, tmdb_id, media_type, title) do
    Phoenix.Component.assign(socket, :library_picker, %{
      tmdb_id: tmdb_id,
      media_type: media_type,
      title: title || "",
      libraries: candidate_libraries(media_type)
    })
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

  Pass `provider: :tvdb` when `provider_id` is already a TVDB series id, which
  is what every Discover TV search result carries. The TMDB-first path above
  only makes sense for a TMDB id, and the relay 404s a TVDB id on TMDB's route.

  An optional `config` can be injected for testing; defaults to
  `Metadata.default_relay_config()`.
  """
  def fetch_detail_metadata(provider_id, media_type, config \\ nil, opts \\ []) do
    config = config || Metadata.default_relay_config()

    cond do
      media_type != :tv_show ->
        Metadata.fetch_by_id(config, provider_id, media_type: :movie)

      # The id is already a TVDB series id, so there is no TMDB lookup to start
      # from: a Discover TV search result carries one, since `Relay.search/3`
      # routes `:tv_show` to `/tvdb/search`. Asking TMDB for it 404s.
      Keyword.get(opts, :provider) == :tvdb ->
        Metadata.fetch_by_id(config, provider_id, media_type: :tv_show, provider: :tvdb)

      true ->
        fetch_tv_detail_from_tmdb(provider_id, config)
    end
  end

  defp fetch_tv_detail_from_tmdb(provider_id, config) do
    case Metadata.fetch_by_id(config, provider_id, media_type: :tv_show, provider: :tmdb) do
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

  # Private helpers

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
