defmodule Mydia.Plugins.Shelves.Verifier do
  @moduledoc """
  Turns the picks a plugin returned into items the host is willing to show.

  A plugin's picks are untrusted: a model may invent an id, repeat itself, or
  propose something the user owns, already asked for, dismissed, or may not
  see. Every pick is resolved against the metadata relay, which also supplies
  the title, year and poster the rail renders, so nothing unverified is ever
  stored.

  A title the user has watched needs no check of its own. Watch state hangs
  off library rows, so a watched title is an owned one.
  """

  alias Mydia.Accounts.Scope
  alias Mydia.Accounts.User
  alias Mydia.Media
  alias Mydia.Media.CategoryClassifier
  alias Mydia.Media.ContentRating
  alias Mydia.Media.MediaRequest
  alias Mydia.Media.ProviderKey
  alias Mydia.Media.Restrictions
  alias Mydia.MediaRequests
  alias Mydia.Metadata
  alias Mydia.Plugins.Shelves.Pick

  @min_items 3
  @default_limit 12
  @reason_max 140
  # Requests in these states already claim a title.
  @outstanding ~w(pending approved)

  @type item_attrs :: %{
          media_type: :movie | :tv_show,
          provider: :tmdb | :tvdb,
          provider_id: integer(),
          reason: String.t() | nil,
          title: String.t(),
          year: integer() | nil,
          poster_path: String.t() | nil
        }

  @doc """
  Returns the picks worth storing, in the plugin's order, cut to `:limit`.

  `{:error, :too_few}` when fewer than #{@min_items} survive, so a thin result
  never replaces a full shelf. `{:error, :relay_unavailable}` when candidates
  existed and not one resolved, which is a relay outage rather than a list of
  bad ids.

  Options: `:dismissed` (provider keys the user dismissed), `:limit`, and
  `:resolver`, a `(ref, media_type) -> {:ok, metadata} | {:error, term}` that
  tests inject instead of touching the relay.
  """
  @spec verify([Pick.t()], User.t(), keyword()) ::
          {:ok, [item_attrs()]} | {:error, :too_few | :relay_unavailable}
  def verify(picks, %User{} = user, opts \\ []) when is_list(picks) do
    limit = Keyword.get(opts, :limit, @default_limit)
    resolver = Keyword.get(opts, :resolver) || (&resolve/2)
    scope = Scope.for_user(user)

    taken =
      MapSet.new()
      |> MapSet.union(Keyword.get(opts, :dismissed, MapSet.new()))
      |> MapSet.union(owned_keys())
      |> MapSet.union(requested_keys())

    candidates =
      picks
      |> Enum.flat_map(&keyed/1)
      |> Enum.uniq_by(fn {key, _pick} -> key end)
      |> Enum.reject(fn {key, _pick} -> MapSet.member?(taken, key) end)

    resolved = Enum.map(candidates, &resolve_candidate(&1, resolver))

    items =
      for {:ok, metadata, key, pick} <- resolved,
          allowed?(metadata, scope),
          do: attrs(metadata, key, pick)

    cond do
      candidates != [] and not Enum.any?(resolved, &match?({:ok, _, _, _}, &1)) ->
        {:error, :relay_unavailable}

      length(items) < @min_items ->
        {:error, :too_few}

      true ->
        {:ok, Enum.take(items, limit)}
    end
  end

  # TMDB first; a TVDB id is only meaningful for a show. Anything else,
  # including an imdb-only pick, cannot be keyed and is dropped.
  defp keyed(%Pick{media_type: type, tmdb_id: id} = pick)
       when type in [:movie, :tv_show] and is_integer(id),
       do: [{ProviderKey.new(type, :tmdb, id), pick}]

  defp keyed(%Pick{media_type: :tv_show, tvdb_id: id} = pick) when is_integer(id),
    do: [{ProviderKey.new(:tv_show, :tvdb, id), pick}]

  defp keyed(_pick), do: []

  # The whole library, not the user's restricted view of it: a title the user
  # may not see is still not something to suggest adding.
  defp owned_keys do
    Scope.system() |> Media.get_library_status_map() |> Map.keys() |> MapSet.new()
  end

  defp requested_keys do
    for status <- @outstanding,
        request <- MediaRequests.list_requests(status: status),
        {provider, id} <- List.wrap(MediaRequest.external_ref(request)),
        into: MapSet.new() do
      ProviderKey.new(MediaRequest.media_type_atom(request), provider, id)
    end
  end

  defp resolve_candidate({{type, provider, id} = key, pick}, resolver) do
    case resolver.({provider, id}, type) do
      {:ok, metadata} -> {:ok, metadata, key, pick}
      _error -> :unresolved
    end
  end

  defp resolve(ref, media_type) do
    Metadata.fetch_by_ref_cached(Metadata.default_relay_config(), ref, media_type: media_type)
  end

  defp allowed?(metadata, %Scope{} = scope) do
    category =
      metadata.media_type |> CategoryClassifier.classify_from_metadata(metadata) |> to_string()

    Restrictions.allowed?(category, ContentRating.min_age(metadata.content_rating), scope)
  end

  defp attrs(metadata, {type, provider, id}, %Pick{reason: reason}) do
    %{
      media_type: type,
      provider: provider,
      provider_id: id,
      reason: clean_reason(reason),
      title: metadata.title || "",
      year: metadata.year,
      poster_path: metadata.poster_path
    }
  end

  # One line of plain text: collapse every run of whitespace, including
  # newlines and tabs, then clip.
  defp clean_reason(reason) when is_binary(reason) do
    case reason |> String.split() |> Enum.join(" ") do
      "" -> nil
      text -> String.slice(text, 0, @reason_max)
    end
  end

  defp clean_reason(_), do: nil
end
