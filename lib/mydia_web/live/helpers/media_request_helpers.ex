defmodule MydiaWeb.Live.Helpers.MediaRequestHelpers do
  @moduledoc """
  Shared LiveView helpers for the guest "Request" flow.

  Mirrors `MydiaWeb.Live.Helpers.MediaAddHelpers`: a status map, an enrichment
  pass over trending items, and a submit function. Used by DashboardLive and
  DiscoverLive so the request button behaves identically on both.
  """

  alias Mydia.Media.Add
  alias Mydia.MediaRequests

  # Statuses that should keep the request button disabled. A rejected request
  # leaves the button enabled so a guest can ask again.
  @outstanding ~w(pending approved)

  @doc """
  Maps `tmdb_id` to request status for every outstanding request.

  Deliberately not scoped to a requester. `MediaRequests.create_request/1`
  rejects duplicates globally via `pending_request_exists?/1`, so a per-user map
  would show a second guest an enabled button that errors on click.
  """
  @spec request_status_map() :: %{integer() => String.t()}
  def request_status_map do
    @outstanding
    |> Enum.flat_map(&MediaRequests.list_requests(status: &1))
    |> Enum.reduce(%{}, fn request, acc ->
      case request.tmdb_id do
        nil -> acc
        tmdb_id -> Map.put_new(acc, tmdb_id, request.status)
      end
    end)
  end

  @doc """
  Adds a `:request_status` field to each item, or nil when it has no request.
  """
  def enrich_with_request_status(items, request_status_map) do
    Enum.map(items, fn item ->
      status = Map.get(request_status_map, Add.parse_provider_id(item.provider_id))
      Map.put(item, :request_status, status)
    end)
  end

  @doc """
  Submits a request for a trending card item.

  Returns `{:ok, request, updated_status_map}` or `{:error, reason}` where
  reason is `:duplicate_media`, `:duplicate_request`, or a changeset.

  The card carries no `imdb_id` or `original_title`; approval re-fetches from
  the provider and resolves both, so nothing is lost by not fetching here. That
  keeps the button instant.
  """
  @spec handle_request_media(map(), :movie | :tv_show, String.t()) ::
          {:ok, Mydia.Media.MediaRequest.t(), map()} | {:error, term()}
  def handle_request_media(item, media_type, requester_id) do
    tmdb_id = Add.parse_provider_id(item.provider_id)

    attrs = %{
      media_type: if(media_type == :movie, do: "movie", else: "tv_show"),
      title: item.title,
      year: Map.get(item, :year),
      tmdb_id: tmdb_id,
      requester_id: requester_id
    }

    case MediaRequests.create_request(attrs) do
      {:ok, request} -> {:ok, request, %{tmdb_id => request.status}}
      {:error, reason} -> {:error, reason}
    end
  end
end
