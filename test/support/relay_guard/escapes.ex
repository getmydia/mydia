defmodule Mydia.RelayGuard.Escapes do
  @moduledoc """
  Records the outbound HTTP requests `Mydia.RelayGuard` refused, and formats the
  end-of-suite report.

  The table is public and named because an escape is recorded from whatever
  process made the request, which for a detail-page lookup is a LiveView
  `start_async` task rather than the test process. `test_helper.exs` sets
  `max_cases` to `System.schedulers_online()` on PostgreSQL, so those writes are
  genuinely concurrent.

  The report names the *lookup*, not the test. A LiveView process in a connected
  `Phoenix.LiveViewTest` mount is not a `$callers` descendant of the test
  process, so there is no reliable way to attribute an escape to a test. The
  app-only stack frames plus the nine-digit provider id are enough to find it.
  """

  @table :mydia_relay_guard_escapes

  @collection_path ~r{^/tmdb/collections/(?<id>\d+)}
  @movie_path ~r{^/tmdb/movies/(?<id>\d+)}
  @tv_path ~r{^/tmdb/tv/shows/(?<id>\d+)}

  @app_prefixes ["Elixir.Mydia.", "Elixir.MydiaWeb."]
  @self_prefix "Elixir.Mydia.RelayGuard."

  @doc "Creates the escape table. Idempotent."
  def setup do
    case :ets.whereis(@table) do
      :undefined ->
        :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
        :ok

      _tid ->
        :ok
    end
  end

  @doc """
  Records one refused request.

  A no-op when the table does not exist, so `Mydia.RelayGuard` can be exercised
  in isolation without suite-level setup.
  """
  def record(%Req.Request{} = req) do
    if :ets.whereis(@table) != :undefined do
      frames = app_frames()
      key = {req.method, req.url.host, req.url.path, req.url.query}
      default = {key, 0, URI.to_string(req.url), frames}

      :ets.update_counter(@table, key, {2, 1}, default)
    end

    :ok
  end

  @doc "Every recorded escape, most frequent first."
  def all do
    case :ets.whereis(@table) do
      :undefined ->
        []

      _tid ->
        @table
        |> :ets.tab2list()
        |> Enum.sort_by(fn {_key, count, _url, _frames} -> -count end)
    end
  end

  @doc "Empties the table."
  def reset do
    if :ets.whereis(@table) != :undefined do
      :ets.delete_all_objects(@table)
    end

    :ok
  end

  @doc """
  The `Mydia.MetadataCacheHelpers` call that would have prevented this escape,
  or nil.

  `/tmdb/movies/:id` is reachable from two different lookups, so the
  `append_to_response` query parameter disambiguates them: an exact
  `append_to_response=recommendations` value is the recommendations lookup,
  anything else is the details lookup. Anything unrecognised returns nil: a
  wrong suggestion is worse than none.
  """
  def suggest(path, query) when is_binary(path) and (is_nil(query) or is_binary(query)) do
    cond do
      caps = Regex.named_captures(@collection_path, path) ->
        "warm_collection_cache(#{caps["id"]}, parts)"

      caps = Regex.named_captures(@tv_path, path) ->
        "warm_recommendations_cache(#{caps["id"]}, :tv_show, results)"

      caps = Regex.named_captures(@movie_path, path) ->
        if recommendations_query?(query) do
          "warm_recommendations_cache(#{caps["id"]}, :movie, results)"
        else
          "warm_movie_details_cache(#{caps["id"]})"
        end

      true ->
        nil
    end
  end

  def suggest(_path, _query), do: nil

  @doc "The end-of-suite report."
  def format(escapes) do
    entries = Enum.map_join(escapes, "\n", &format_one/1)

    """

    ================================================================================
    #{length(escapes)} outbound HTTP request(s) escaped to the network during this run.

    Tests must not depend on the network. Warm the metadata cache with
    Mydia.MetadataCacheHelpers, or serve the response from Bypass on localhost.
    #{entries}
    ================================================================================
    """
  end

  defp recommendations_query?(nil), do: false

  defp recommendations_query?(query) when is_binary(query) do
    case URI.decode_query(query) do
      %{"append_to_response" => "recommendations"} -> true
      _other -> false
    end
  end

  defp format_one({{method, _host, path, _query}, count, url, frames}) do
    query = URI.parse(url).query

    fix =
      case suggest(path, query) do
        nil -> ""
        call -> "\n      fix: #{call}\n"
      end

    trace =
      Enum.map_join(frames, "\n", fn {mod, fun, arity, loc} ->
        file = Keyword.get(loc, :file, ~c"")
        line = Keyword.get(loc, :line, 0)
        "        #{inspect(mod)}.#{fun}/#{arity} #{file}:#{line}"
      end)

    """

      #{method |> to_string() |> String.upcase()} #{url} (#{count}x)
    #{fix}
    #{trace}
    """
  end

  defp app_frames do
    {:current_stacktrace, frames} = Process.info(self(), :current_stacktrace)

    frames
    |> Enum.filter(fn
      {mod, _fun, _arity, _loc} -> app_module?(mod) and not self_module?(mod)
      _other -> false
    end)
    |> Enum.take(5)
  end

  defp app_module?(mod) when is_atom(mod) do
    mod |> Atom.to_string() |> String.starts_with?(@app_prefixes)
  end

  defp app_module?(_mod), do: false

  defp self_module?(Mydia.RelayGuard), do: true

  defp self_module?(mod) when is_atom(mod) do
    mod |> Atom.to_string() |> String.starts_with?(@self_prefix)
  end

  defp self_module?(_mod), do: false
end
