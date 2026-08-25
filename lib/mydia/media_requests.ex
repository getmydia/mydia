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
  alias Mydia.Media.MediaRequest
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
    with {:ok, media_attrs} <- resolve_media_attrs(request, opts) do
      insert_approval(request, media_attrs, attrs, opts)
    end
  end

  defp resolve_media_attrs(request, opts) do
    {provider_id, provider} = request_provider(request)
    media_type = if request.media_type == "movie", do: :movie, else: :tv_show

    case Add.resolve_attrs(provider_id, media_type, opts[:config],
           provider: provider,
           monitored: true
         ) do
      {:ok, media_attrs} ->
        {:ok, media_attrs}

      {:error, {:metadata, reason}} ->
        Logger.warning(
          "Cannot approve request #{request.id}: metadata fetch failed: #{inspect(reason)}"
        )

        {:error, {:metadata, reason}}
    end
  end

  # A request may carry a TVDB id with no TMDB counterpart (the series search
  # page stores whichever the provider returned). Sending a TVDB id down the
  # TMDB path would fetch the wrong show.
  defp request_provider(%MediaRequest{tmdb_id: tmdb_id}) when is_integer(tmdb_id),
    do: {tmdb_id, :tmdb}

  defp request_provider(%MediaRequest{tvdb_id: tvdb_id}) when is_integer(tvdb_id),
    do: {tvdb_id, :tvdb}

  defp request_provider(_request), do: {nil, :tmdb}

  defp insert_approval(request, media_attrs, attrs, opts) do
    Multi.new()
    |> Multi.run(:media_item, fn _repo, _changes ->
      case Add.from_attrs(media_attrs, opts[:config],
             actor_type: :user,
             actor_id: attrs[:approved_by_id]
           ) do
        {:ok, media_item} ->
          {:ok, media_item}

        # Not a failure: the request is asking for something already in the
        # library. Link the request to the existing row instead of bouncing
        # the approval off a unique constraint the admin can't act on.
        {:error, {:already_in_library, media_item}} ->
          {:ok, media_item}

        {:error, {:changeset, changeset}} ->
          {:error, changeset}
      end
    end)
    |> Multi.run(:request, fn _repo, %{media_item: media_item} ->
      request
      |> MediaRequest.approve_changeset(Map.put(attrs, :media_item_id, media_item.id))
      |> Repo.update()
    end)
    |> Repo.transaction()
    |> case do
      {:ok, %{request: updated_request, media_item: media_item}} ->
        # "linked to", not "created": approval also lands here when the item
        # was already in the library and the request was pointed at it.
        Logger.info(
          "Request #{request.id} approved by user #{attrs[:approved_by_id]}, linked to media #{media_item.id}"
        )

        {:ok, %{request: updated_request, media_item: media_item}}

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
  Checks if a request with the given TMDB ID is pending.
  """
  def pending_request_exists?(tmdb_id) when is_integer(tmdb_id) do
    MediaRequest
    |> where([r], r.tmdb_id == ^tmdb_id and r.status == "pending")
    |> Repo.exists?()
  end

  def pending_request_exists?(_), do: false

  # Private functions

  defp check_duplicate_media(changeset) do
    tmdb_id = Ecto.Changeset.get_field(changeset, :tmdb_id)

    if tmdb_id && Media.get_media_item_by_tmdb(tmdb_id) do
      {:error, :duplicate_media}
    else
      :ok
    end
  end

  defp check_duplicate_request(changeset) do
    tmdb_id = Ecto.Changeset.get_field(changeset, :tmdb_id)

    if tmdb_id && pending_request_exists?(tmdb_id) do
      {:error, :duplicate_request}
    else
      :ok
    end
  end
end
