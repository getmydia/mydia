defmodule Mydia.MediaRequests do
  @moduledoc """
  The MediaRequests context handles media request submissions, approvals, and rejections.
  """

  use Mydia.QueryHelpers.Filterable,
    function_name: :apply_request_filters,
    filters: [
      status: :eq,
      requester_id: :eq
    ]

  import Ecto.Query, warn: false
  import Mydia.QueryHelpers
  require Logger

  alias Mydia.Repo
  alias Mydia.Media
  alias Mydia.Media.Add
  alias Mydia.Media.MediaItem
  alias Mydia.Media.MediaRequest
  alias Mydia.DB
  alias Mydia.Search
  alias Ecto.Multi

  @doc """
  Returns the list of media requests.

  ## Options
    - `:status` - Filter by status ("pending", "approved", "rejected")
    - `:requester_id` - Filter by requester
    - `:preload` - List of associations to preload
  """
  def list_requests(opts \\ []) do
    MediaRequest
    |> apply_request_filters(opts)
    |> maybe_preload(opts[:preload])
    |> order_by([r], desc: r.inserted_at)
    |> Repo.all()
  end

  @doc """
  Gets a single media request.

  ## Options
    - `:preload` - List of associations to preload

  Raises `Ecto.NoResultsError` if the request does not exist.
  """
  def get_request!(id, opts \\ []) do
    MediaRequest
    |> maybe_preload(opts[:preload])
    |> Repo.get!(id)
  end

  @doc """
  Creates a media request.

  Performs duplicate detection to check if:
  - The media item already exists
  - There's a pending request for the same media

  Returns `{:error, :duplicate_media}` if media exists.
  Returns `{:error, :duplicate_request}` if pending request exists.
  """
  def create_request(attrs \\ %{}) do
    changeset = MediaRequest.create_changeset(%MediaRequest{}, attrs)

    with :ok <- check_duplicate_media(changeset),
         :ok <- check_duplicate_request(changeset),
         {:ok, request} <- Repo.insert(changeset) do
      {:ok, Repo.preload(request, [:requester])}
    end
  end

  @doc """
  Stores the poster path for a request.

  Used by the request list backfill for rows created before the column
  existed. Deliberately a bare write with no duplicate checks: the poster is
  presentation data and never changes which media the request refers to.
  """
  @spec update_poster_path(MediaRequest.t(), String.t()) ::
          {:ok, MediaRequest.t()} | {:error, Ecto.Changeset.t()}
  def update_poster_path(%MediaRequest{} = request, poster_path) when is_binary(poster_path) do
    request
    |> Ecto.Changeset.change(poster_path: poster_path)
    |> Repo.update()
  end

  @doc """
  Approves a media request and creates the corresponding media item.

  Provider metadata is fetched before the transaction opens, so the media item
  lands with the same poster, overview and provenance an admin-added item gets,
  and no HTTP call is made while a write transaction is held. If the metadata
  relay cannot be reached the request is left untouched and pending, so the
  admin can retry rather than ending up with an artwork-less library entry.

  The insert and the request update remain atomic: if either fails, both roll
  back.

  ## Attributes
    - `approved_by_id` - Required, ID of the admin approving the request
    - `admin_notes` - Optional notes from the admin

  ## Options
    - `:config` - Relay config to fetch with. Defaults to
      `Metadata.default_relay_config/0`. Inject a Bypass config in tests.
  """
  def approve_request(%MediaRequest{} = request, attrs \\ %{}, opts \\ []) do
    with {:ok, media_attrs} <- resolve_media_attrs(request, opts),
         {:ok, result, created?} <- insert_approval(request, media_attrs, attrs, opts) do
      # After the transaction, never inside it. Repo.transaction defers event
      # broadcasts until commit, and a search queued against an uncommitted
      # media item is a race.
      #
      # Only queued when the approval created a new media item. A request
      # that linked to an already-in-library item must not enqueue a search
      # for a row someone else set up; the Add flow makes the same
      # distinction (see MediaAddHelpers.handle_add_media_to_library/5).
      if created? do
        Search.maybe_queue_search(result.media_item, Keyword.get(opts, :search_on_add, false))
      end

      {:ok, result}
    end
  end

  defp resolve_media_attrs(request, opts) do
    ref = MediaRequest.external_ref(request)
    media_type = if request.media_type == "movie", do: :movie, else: :tv_show

    # `monitored` defaults to true when the caller says nothing, which is what
    # approval did unconditionally before the config dialog existed.
    attr_opts =
      opts
      |> Keyword.take([:monitored, :quality_profile_id, :library_path_id])
      |> Keyword.put_new(:monitored, true)

    case Add.resolve_attrs(ref, media_type, opts[:config], attr_opts) do
      {:ok, media_attrs} ->
        {:ok, media_attrs}

      {:error, {:metadata, reason}} ->
        Logger.warning(
          "Cannot approve request #{request.id}: metadata fetch failed: #{inspect(reason)}"
        )

        {:error, {:metadata, reason}}
    end
  end

  # Returns `{:ok, %{request: _, media_item: _}, created?}` on success, where
  # `created?` is false when the request linked to a pre-existing media item
  # rather than creating a new one. `approve_request/3` uses that flag to
  # decide whether to queue a search; a linked request must not queue one for
  # a media item someone else already added.
  defp insert_approval(request, media_attrs, attrs, opts) do
    Multi.new()
    |> Multi.run(:media_item, fn _repo, _changes ->
      case Add.from_attrs(
             media_attrs,
             opts[:config],
             [
               actor_type: :user,
               actor_id: attrs[:approved_by_id],
               exclude_request_id: request.id
             ] ++ Keyword.take(opts, [:season_monitoring])
           ) do
        {:ok, media_item} ->
          {:ok, %{item: media_item, created?: true}}

        # Not a failure: the request is asking for something already in the
        # library. Link the request to the existing row instead of bouncing
        # the approval off a unique constraint the admin can't act on.
        {:error, {:already_in_library, media_item}} ->
          {:ok, %{item: media_item, created?: false}}

        {:error, {:changeset, changeset}} ->
          {:error, changeset}
      end
    end)
    |> Multi.run(:request, fn _repo, %{media_item: %{item: media_item}} ->
      request
      |> MediaRequest.approve_changeset(Map.put(attrs, :media_item_id, media_item.id))
      |> Repo.update()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{request: updated_request, media_item: %{item: media_item, created?: created?}}} ->
        # "linked to", not "created": approval also lands here when the item
        # was already in the library and the request was pointed at it.
        Logger.info(
          "Request #{request.id} approved by user #{attrs[:approved_by_id]}, linked to media #{media_item.id}"
        )

        if not created? do
          auto_approve_matching_requests(
            media_item,
            actor_type: :user,
            actor_id: attrs[:approved_by_id],
            exclude_request_id: request.id
          )
        end

        {:ok, %{request: updated_request, media_item: media_item}, created?}

      {:error, :media_item, changeset, _changes} ->
        Logger.error("Failed to create media item for request #{request.id}")
        {:error, changeset}

      {:error, :request, changeset, _changes} ->
        {:error, changeset}
    end
  end

  @doc """
  Rejects a media request.

  ## Attributes
    - `rejection_reason` - Required, reason for rejection
    - `approved_by_id` - Required, ID of the admin rejecting the request
    - `admin_notes` - Optional additional notes
  """
  def reject_request(%MediaRequest{} = request, attrs \\ %{}) do
    request
    |> MediaRequest.reject_changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated_request} ->
        Logger.info(
          "Request #{request.id} rejected by user #{attrs[:approved_by_id]}: #{attrs[:rejection_reason]}"
        )

        {:ok, updated_request}

      error ->
        error
    end
  end

  @doc """
  Returns the count of pending requests.
  """
  def count_pending_requests do
    MediaRequest
    |> where([r], r.status == "pending")
    |> Repo.aggregate(:count)
  end

  @doc """
  Checks if a request with the given media type and TMDB ID is pending.
  """
  def pending_request_exists?(media_type, tmdb_id)
      when (is_binary(media_type) or is_atom(media_type)) and not is_nil(media_type) and
             is_integer(tmdb_id) do
    type_str = to_string(media_type)

    MediaRequest
    |> where([r], r.media_type == ^type_str and r.tmdb_id == ^tmdb_id and r.status == "pending")
    |> Repo.exists?()
  end

  def pending_request_exists?(_, _), do: false

  # Backward compatibility clause
  def pending_request_exists?(tmdb_id) when is_integer(tmdb_id) do
    MediaRequest
    |> where([r], r.tmdb_id == ^tmdb_id and r.status == "pending")
    |> Repo.exists?()
  end

  def pending_request_exists?(_), do: false

  # Private functions

  defp check_duplicate_media(changeset) do
    media_type = Ecto.Changeset.get_field(changeset, :media_type)
    tmdb_id = Ecto.Changeset.get_field(changeset, :tmdb_id)
    tvdb_id = Ecto.Changeset.get_field(changeset, :tvdb_id)

    cond do
      is_nil(media_type) -> :ok
      tmdb_id && Media.get_media_item_by_tmdb(media_type, tmdb_id) -> {:error, :duplicate_media}
      tvdb_id && Media.get_media_item_by_tvdb(media_type, tvdb_id) -> {:error, :duplicate_media}
      true -> :ok
    end
  end

  defp check_duplicate_request(changeset) do
    media_type = Ecto.Changeset.get_field(changeset, :media_type)
    tmdb_id = Ecto.Changeset.get_field(changeset, :tmdb_id)
    tvdb_id = Ecto.Changeset.get_field(changeset, :tvdb_id)

    cond do
      is_nil(media_type) -> :ok
      tmdb_id && pending_request_exists?(media_type, tmdb_id) -> {:error, :duplicate_request}
      tvdb_id && pending_tvdb_request_exists?(media_type, tvdb_id) -> {:error, :duplicate_request}
      true -> :ok
    end
  end

  defp pending_tvdb_request_exists?(media_type, tvdb_id)
       when (is_binary(media_type) or is_atom(media_type)) and not is_nil(media_type) and
              is_integer(tvdb_id) do
    type_str = to_string(media_type)

    MediaRequest
    |> where([r], r.media_type == ^type_str and r.tvdb_id == ^tvdb_id and r.status == "pending")
    |> Repo.exists?()
  end

  defp pending_tvdb_request_exists?(_, _), do: false

  @doc """
  Automatically approves any pending requests matching the given media item.

  Finds pending requests matching the media item's type (`movie` or `tv_show`)
  and any matching external IDs (`tmdb_id`, `tvdb_id`, or `imdb_id`).
  Links each request to the media item, stamps approval time, and records
  the approver if an actor user ID was provided.

  ## Options
    - `:actor_type` - `:user` or `:system`
    - `:actor_id` - ID of the actor (if a valid user UUID, recorded as approved_by_id)
    - `:approved_by_id` - Explicit user ID to attribute approval to
    - `:exclude_request_id` - Optional request ID to skip (used during manual approval)
    - `:admin_notes` - Optional admin notes (defaults to "Automatically approved: title added to library")
  """
  @spec auto_approve_matching_requests(MediaItem.t(), keyword()) ::
          {:ok, [MediaRequest.t()]} | {:error, term()}
  def auto_approve_matching_requests(%MediaItem{} = media_item, opts \\ []) do
    requests = list_pending_matching_requests(media_item, opts)

    approved_by_id = resolve_approved_by_id(opts)

    default_notes =
      Keyword.get(opts, :admin_notes, "Automatically approved: title added to library")

    Repo.transaction(fn ->
      Enum.reduce_while(requests, [], fn request, acc ->
        query = where(MediaRequest, [r], r.id == ^request.id)
        query = if DB.postgres?(), do: lock(query, "FOR UPDATE"), else: query

        case Repo.one(query) do
          %MediaRequest{status: "pending"} = fresh_request ->
            attrs = %{
              media_item_id: media_item.id,
              approved_by_id: approved_by_id,
              admin_notes: fresh_request.admin_notes || default_notes
            }

            case fresh_request
                 |> MediaRequest.auto_approve_changeset(attrs)
                 |> Repo.update() do
              {:ok, updated} ->
                Logger.info(
                  "Auto-approved request #{fresh_request.id} for media #{media_item.id} (#{media_item.title})"
                )

                {:cont, [updated | acc]}

              {:error, changeset} ->
                Logger.error(
                  "Failed to auto-approve request #{fresh_request.id}: #{inspect(changeset.errors)}"
                )

                Repo.rollback(changeset)
            end

          _other ->
            {:cont, acc}
        end
      end)
    end)
    |> case do
      {:ok, approved_list} -> {:ok, Enum.reverse(approved_list)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Lists pending requests matching a media item's type and external IDs.
  """
  @spec list_pending_matching_requests(MediaItem.t(), keyword()) :: [MediaRequest.t()]
  def list_pending_matching_requests(%MediaItem{} = media_item, opts \\ []) do
    # As documented in lib/mydia/media/add.ex:116-123, IMDb IDs carry no unique
    # index and TVDB's remoteIds can hand split and spin-off series a shared
    # IMDb ID. We match only across stable primary provider IDs (TMDB and TVDB).
    dynamic_cond =
      false
      |> maybe_or_match_id(:tmdb_id, media_item.tmdb_id)
      |> maybe_or_match_id(:tvdb_id, media_item.tvdb_id)

    if dynamic_cond == false do
      []
    else
      query =
        from r in MediaRequest,
          where: r.status == "pending" and r.media_type == ^media_item.type,
          where: ^dynamic_cond

      query =
        case opts[:exclude_request_id] do
          nil -> query
          exclude_id -> where(query, [r], r.id != ^exclude_id)
        end

      Repo.all(query)
    end
  end

  defp maybe_or_match_id(dynamic, _field, nil), do: dynamic
  defp maybe_or_match_id(false, :tmdb_id, val), do: dynamic([r], r.tmdb_id == ^val)
  defp maybe_or_match_id(dynamic, :tmdb_id, val), do: dynamic([r], ^dynamic or r.tmdb_id == ^val)
  defp maybe_or_match_id(false, :tvdb_id, val), do: dynamic([r], r.tvdb_id == ^val)
  defp maybe_or_match_id(dynamic, :tvdb_id, val), do: dynamic([r], ^dynamic or r.tvdb_id == ^val)

  defp resolve_approved_by_id(opts) do
    cond do
      is_binary(opts[:approved_by_id]) and user_exists?(opts[:approved_by_id]) ->
        opts[:approved_by_id]

      opts[:actor_type] == :user and is_binary(opts[:actor_id]) and user_exists?(opts[:actor_id]) ->
        opts[:actor_id]

      true ->
        nil
    end
  end

  defp user_exists?(user_id) do
    Mydia.Accounts.User
    |> where([u], u.id == ^user_id)
    |> Repo.exists?()
  end
end
