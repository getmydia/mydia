defmodule Mydia.Indexers.Cardigann.Bench.Corpus do
  @moduledoc """
  The set of definitions the Cardigann benchmark runs, and the queries for each.

  Public v11 definitions come from Prowlarr/Indexers on GitHub at one commit
  (`:ref`, default the current head of `master`, resolved to a SHA), cached under
  `<cache_dir>/<ref>/` so repeated runs do not refetch. The cache lives outside
  the repository. Private and semi-private definitions are included only when
  `:credentials` (a map of definition id to settings) has an entry for them.

  Queries are generic text searches, never real titles: one chosen by the
  definition's capabilities (`movie-search` then `tv-search`, else generic),
  plus the empty RSS query.

  ## Options

    * `:ref` - Prowlarr/Indexers commit or branch to pin
    * `:cache_dir` - cache root (default `~/.cache/mydia-cardigann-bench`)
    * `:credentials` - `%{"id" => %{"username" => ..., ...}}`
    * `:only` - list of definition ids
    * `:limit` - first N runnable definitions, in id order
    * `:list_fn` - `(ref -> {:ok, [%{"name", "download_url"}]} | {:error, term})`
    * `:fetch_fn` - `(download_url -> {:ok, yaml} | {:error, term})`
  """

  @repo "Prowlarr/Indexers"
  @definitions_path "definitions/v11"
  @api "https://api.github.com"
  @user_agent "Mydia-cardigann-bench/1.0"
  @fetch_concurrency 8

  @movie_term "1080p"
  @tv_term "S01E01"
  @generic_term "2024"

  @type definition :: %{
          id: String.t(),
          name: String.t(),
          yaml: String.t(),
          type: String.t(),
          queries: [map()],
          settings: map(),
          credentials?: boolean()
        }

  @spec default_cache_dir() :: String.t()
  def default_cache_dir, do: Path.expand("~/.cache/mydia-cardigann-bench")

  @spec load(keyword()) :: {:ok, [definition()], map()} | {:error, term()}
  def load(opts \\ []) do
    cache_dir = Keyword.get(opts, :cache_dir, default_cache_dir())
    list_fn = Keyword.get(opts, :list_fn, &github_list/1)
    fetch_fn = Keyword.get(opts, :fetch_fn, &github_fetch/1)

    with {:ok, ref} <- resolve_ref(opts[:ref]),
         ref_dir = Path.join(cache_dir, ref),
         :ok <- File.mkdir_p(ref_dir),
         {:ok, files} <- cached_listing(ref_dir, ref, list_fn) do
      files = select_files(files, opts[:only])
      {defs, skipped} = build(files, ref_dir, fetch_fn, opts)
      {:ok, defs, %{ref: ref, skipped: skipped, cache_dir: ref_dir, listed: length(files)}}
    end
  end

  # -- selection -------------------------------------------------------------

  defp select_files(files, nil), do: sort_files(files)

  defp select_files(files, only) do
    wanted = MapSet.new(only)
    files |> Enum.filter(&MapSet.member?(wanted, file_id(&1))) |> sort_files()
  end

  defp sort_files(files), do: Enum.sort_by(files, &file_id/1)

  defp file_id(%{"name" => name}), do: Path.rootname(name)

  # Fetches in chunks (concurrently), stopping once `:limit` runnable
  # definitions are in hand, so `--limit 10` downloads about 10 files.
  defp build(files, ref_dir, fetch_fn, opts) do
    credentials = Keyword.get(opts, :credentials, %{})
    limit = opts[:limit]

    {defs, skipped} =
      files
      |> Stream.chunk_every(@fetch_concurrency)
      |> Enum.reduce_while({[], []}, fn chunk, {defs, skipped} ->
        entries = fetch_chunk(chunk, ref_dir, fetch_fn)

        {defs, skipped} =
          Enum.reduce(entries, {defs, skipped}, fn entry, {d, s} ->
            case to_definition(entry, credentials) do
              {:ok, definition} -> {[definition | d], s}
              {:skip, info} -> {d, [info | s]}
            end
          end)

        if limit && length(defs) >= limit,
          do: {:halt, {defs, skipped}},
          else: {:cont, {defs, skipped}}
      end)

    defs = defs |> Enum.reverse() |> Enum.sort_by(& &1.id) |> maybe_take(limit)
    {defs, Enum.reverse(skipped)}
  end

  defp maybe_take(defs, nil), do: defs
  defp maybe_take(defs, limit), do: Enum.take(defs, limit)

  defp fetch_chunk(chunk, ref_dir, fetch_fn) do
    chunk
    |> Task.async_stream(&fetch_one(&1, ref_dir, fetch_fn),
      max_concurrency: @fetch_concurrency,
      timeout: 60_000,
      on_timeout: :kill_task
    )
    |> Enum.zip(chunk)
    |> Enum.map(fn
      {{:ok, entry}, _file} -> entry
      {{:exit, reason}, file} -> {file_id(file), {:error, {:fetch, reason}}}
    end)
  end

  defp fetch_one(file, ref_dir, fetch_fn) do
    id = file_id(file)
    path = Path.join(ref_dir, file["name"])

    case File.read(path) do
      {:ok, yaml} ->
        {id, {:ok, yaml}}

      {:error, _} ->
        case fetch_fn.(file["download_url"]) do
          {:ok, yaml} when is_binary(yaml) ->
            File.write!(path, yaml)
            {id, {:ok, yaml}}

          {:error, reason} ->
            {id, {:error, {:fetch, reason}}}
        end
    end
  end

  defp to_definition({id, {:error, reason}}, _credentials), do: {:skip, %{id: id, reason: reason}}

  defp to_definition({file_id, {:ok, yaml}}, credentials) do
    case YamlElixir.read_from_string(yaml) do
      {:ok, %{} = doc} ->
        id = to_string(doc["id"] || file_id)
        type = to_string(doc["type"] || "public")
        settings = Map.get(credentials, id) || Map.get(credentials, file_id)

        if type != "public" and settings == nil do
          {:skip, %{id: id, reason: :no_credentials}}
        else
          {:ok,
           %{
             id: id,
             name: to_string(doc["name"] || id),
             yaml: yaml,
             type: type,
             queries: queries(doc),
             settings: settings || %{},
             credentials?: settings not in [nil, %{}]
           }}
        end

      _ ->
        {:skip, %{id: file_id, reason: :unparseable}}
    end
  end

  # -- queries ---------------------------------------------------------------

  defp queries(doc) do
    modes = mode_names(doc)

    {label, term} =
      cond do
        "movie-search" in modes -> {"movie", @movie_term}
        "tv-search" in modes -> {"tv", @tv_term}
        true -> {"generic", @generic_term}
      end

    [query(label, term), query("rss", "")]
  end

  defp query(label, term) do
    %{
      kind: :search,
      label: label,
      term: term,
      categories: [],
      imdb_id: nil,
      tmdb_id: nil,
      tvdb_id: nil,
      season: nil,
      episode: nil,
      limit: nil,
      offset: nil
    }
  end

  defp mode_names(doc) do
    case get_in(doc, ["caps", "modes"]) do
      %{} = modes -> Map.keys(modes)
      _ -> []
    end
  end

  # -- GitHub ----------------------------------------------------------------

  defp resolve_ref(ref) when is_binary(ref) and ref != "", do: {:ok, ref}

  defp resolve_ref(_) do
    url = "#{@api}/repos/#{@repo}/commits/master"

    case Req.get(url, headers: github_headers(), receive_timeout: 30_000) do
      {:ok, %{status: 200, body: %{"sha" => sha}}} -> {:ok, sha}
      {:ok, %{status: status}} -> {:error, {:resolve_ref, status}}
      {:error, reason} -> {:error, {:resolve_ref, reason}}
    end
  end

  defp cached_listing(ref_dir, ref, list_fn) do
    path = Path.join(ref_dir, "_listing.json")

    with {:ok, body} <- File.read(path),
         {:ok, files} when is_list(files) <- Jason.decode(body) do
      {:ok, files}
    else
      _ ->
        with {:ok, files} <- list_fn.(ref) do
          File.write!(path, Jason.encode!(files))
          {:ok, files}
        end
    end
  end

  defp github_list(ref) do
    url = "#{@api}/repos/#{@repo}/contents/#{@definitions_path}"

    case Req.get(url, params: [ref: ref], headers: github_headers(), receive_timeout: 30_000) do
      {:ok, %{status: 200, body: files}} when is_list(files) ->
        {:ok,
         for(
           %{"type" => "file", "name" => name} = f <- files,
           String.ends_with?(name, ".yml"),
           do: Map.take(f, ["name", "download_url"])
         )}

      {:ok, %{status: status}} ->
        {:error, {:list_definitions, status}}

      {:error, reason} ->
        {:error, {:list_definitions, reason}}
    end
  end

  defp github_fetch(url) do
    case Req.get(url, headers: [{"user-agent", @user_agent}], receive_timeout: 30_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:status, status}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp github_headers do
    [{"accept", "application/vnd.github.v3+json"}, {"user-agent", @user_agent}]
  end
end
