defmodule Mydia.Indexers.Cardigann.LiveCheck do
  @moduledoc """
  Runs one Cardigann definition against its live site the way the app does, and
  says which of a fixed set of buckets it lands in.

  Order per definition: mirror probe (`probe_candidates/2`), a search with the
  probe query through `execute_search/4` (mirror failover included), a recheck
  with an empty query when the probe query returns no rows (so "nothing matched"
  is not mistaken for "broken"), then a grab of the first row's download.

  This is a developer and operator tool behind `mix mydia.cardigann_health`. It
  talks to real trackers, so it never runs in CI or on a schedule.
  """

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.LiveCheck.Outcome
  alias Mydia.Indexers.Cardigann.TemplateContext
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.CardigannDownload
  alias Mydia.Indexers.CardigannHealthCheck
  alias Mydia.Indexers.CardigannParser
  alias Mydia.Indexers.CardigannResultParser
  alias Mydia.Indexers.CardigannSearchEngine

  @grab_timeout 15_000
  @max_grab_hops 3

  @spec check(String.t(), keyword()) :: Outcome.t()
  def check(yaml, opts \\ []) when is_binary(yaml) do
    started = System.monotonic_time(:millisecond)

    outcome =
      case CardigannParser.parse_definition(yaml) do
        {:ok, parsed} -> check_parsed(parsed, yaml, opts)
        {:error, reason} -> %Outcome{bucket: :unsupported_definition, error: inspect(reason)}
      end

    %{outcome | ms: System.monotonic_time(:millisecond) - started}
  end

  defp check_parsed(%Parsed{} = parsed, yaml, opts) do
    config = Keyword.get(opts, :config, %{})
    capture_dir = Keyword.get(opts, :capture)

    base_url =
      case CardigannHealthCheck.probe_candidates(parsed, config) do
        {:ok, link, _status} -> link
        {:error, _status} -> List.first(parsed.links)
      end

    search = search(parsed, config, base_url, CardigannHealthCheck.probe_query(parsed))

    empty =
      if match?({:ok, [], _, _, _}, search), do: search(parsed, config, base_url, ""), else: nil

    first = first_result(search, empty)

    grab =
      if Keyword.get(opts, :grab, true), do: grab(parsed, config, first), else: nil

    observations = %{search: summarize(search), empty: summarize(empty), grab: grab}

    outcome = %Outcome{
      id: parsed.id,
      name: parsed.name,
      bucket: classify(observations),
      base_url: winner(search) || base_url,
      rows: row_count(search),
      dropped: dropped_count(search),
      rows_empty_query: if(empty, do: row_count(empty)),
      grab: if(grab, do: grab |> inspect() |> String.slice(0, 200)),
      error: error_message(search)
    }

    if capture_dir do
      capture(capture_dir, parsed, yaml, search, empty, outcome)
      capture_details_page(capture_dir, parsed, first)
    end

    outcome
  end

  # -- search -----------------------------------------------------------------

  # Mirrors CardigannHealthCheck.probe_search/3 but keeps the parsed rows and the
  # raw response, which the grab leg and --capture need.
  defp search(parsed, config, base_url, query) do
    opts = [
      query: query,
      categories: [],
      config: config,
      settings: parsed.settings,
      base_url: base_url,
      on_promote: &send(self(), {:live_check_promoted, &1})
    ]

    with {:ok, response} <-
           normalize(CardigannSearchEngine.execute_search(parsed, opts, config, %{})),
         winner = served_by(base_url),
         :ok <- CardigannSearchEngine.validate_response(response),
         {:ok, path} <- CardigannSearchEngine.select_search_path(parsed, opts),
         {:ok, results, stats} <-
           CardigannResultParser.parse_results_with_stats(parsed, response, parsed.name,
             template_context: TemplateContext.build(parsed, opts),
             base_url: winner,
             search_path: path
           ) do
      {:ok, results, winner, response, stats}
    else
      {:error, %Error{message: message}} -> CardigannHealthCheck.classify_probe_error(message)
      {:error, other} -> {:error, inspect(other)}
    end
  end

  defp normalize({:ok, response}), do: {:ok, response}
  defp normalize({:ok, response, _markers}), do: {:ok, response}
  defp normalize(other), do: other

  defp served_by(default) do
    receive do
      {:live_check_promoted, url} -> url
    after
      0 -> default
    end
  end

  defp summarize(nil), do: nil

  defp summarize({:ok, results, _winner, _response, stats}),
    do: {:ok, length(results), stats.dropped}

  defp summarize(other), do: other

  defp row_count({:ok, results, _, _, _}), do: length(results)
  defp row_count(_), do: 0

  defp dropped_count({:ok, _, _, _, stats}), do: stats.dropped
  defp dropped_count(_), do: 0

  defp winner({:ok, _, winner, _, _}), do: winner
  defp winner(_), do: nil

  defp error_message({:error, message}), do: message
  defp error_message({:cloudflare, message}), do: message
  defp error_message(_), do: nil

  defp first_result({:ok, [first | _], _, _, _}, _empty), do: first
  defp first_result(_search, {:ok, [first | _], _, _, _}), do: first
  defp first_result(_, _), do: nil

  # -- grab -------------------------------------------------------------------

  defp grab(_parsed, _config, nil), do: nil

  defp grab(_parsed, _config, %{download_url: "magnet:" <> _ = magnet}), do: {:magnet, magnet}

  defp grab(parsed, config, %{download_url: url}) when is_binary(url) do
    case CardigannDownload.resolve(parsed, url, config) do
      {:ok, {:magnet, magnet}} -> {:magnet, magnet}
      {:ok, {:link, link}} -> fetch_torrent(link, @max_grab_hops)
      :not_applicable -> fetch_torrent(url, @max_grab_hops)
      {:error, reason} -> {:error, inspect(reason)}
    end
  end

  defp grab(_parsed, _config, _result), do: {:error, "first row has no download url"}

  defp fetch_torrent(_url, 0), do: {:error, "too many redirects"}

  defp fetch_torrent(url, hops) do
    case Req.get(url,
           redirect: false,
           retry: false,
           decode_body: false,
           receive_timeout: @grab_timeout
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        if torrent_body?(body),
          do: {:torrent, byte_size(body)},
          else: {:error, "not a torrent body"}

      {:ok, %Req.Response{status: status} = response} when status in 300..399 ->
        case Req.Response.get_header(response, "location") do
          ["magnet:" <> _ = magnet | _] ->
            {:magnet, magnet}

          [location | _] ->
            fetch_torrent(url |> URI.merge(location) |> URI.to_string(), hops - 1)

          [] ->
            {:error, "redirect without Location"}
        end

      {:ok, %Req.Response{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, exception} ->
        {:error, Exception.message(exception)}
    end
  end

  defp torrent_body?(body),
    do: String.starts_with?(body, "d") and String.contains?(body, "4:info")

  # -- classify ---------------------------------------------------------------

  @spec classify(map()) :: Outcome.bucket()
  def classify(%{search: {:cloudflare, _}}), do: :cloudflare
  def classify(%{search: {:error, message}}), do: classify_error(message)
  def classify(%{search: {:ok, n, _dropped}, grab: grab}) when n > 0, do: with_grab(:ok, grab)

  def classify(%{search: {:ok, 0, _dropped}, empty: {:ok, n, _}, grab: grab}) when n > 0,
    do: with_grab(:ok_empty_query, grab)

  def classify(%{search: {:ok, 0, dropped}}) when dropped > 0, do: :rows_dropped
  def classify(%{search: {:ok, 0, _dropped}}), do: :no_rows

  defp with_grab(bucket, {:magnet, _}), do: bucket
  defp with_grab(bucket, {:torrent, _}), do: bucket
  defp with_grab(bucket, nil), do: bucket
  defp with_grab(_bucket, _failed), do: :grab_failed

  defp classify_error(message) do
    cond do
      message =~ ~r/failed to render|parse error at line/i -> :template_error
      message =~ ~r/Failed to parse (HTML|XML|JSON)/ -> :parse_error
      message =~ ~r/invalid_request_target|^HTTP 4(?!04)\d\d/ -> :http_4xx
      true -> :unreachable
    end
  end

  # -- capture ----------------------------------------------------------------

  defp capture(dir, parsed, yaml, search, empty, outcome) do
    target = Path.join(dir, parsed.id)
    File.mkdir_p!(target)
    File.write!(Path.join(target, "definition.yml"), yaml)

    case best_response(search, empty, CardigannHealthCheck.probe_query(parsed)) do
      {query, %{body: body}} ->
        {name, bytes} = response_file(body)
        File.write!(Path.join(target, name), bytes)

        File.write!(
          Path.join(target, "metadata.json"),
          Jason.encode!(
            %{
              indexer_id: parsed.id,
              query: query,
              base_url: outcome.base_url,
              bucket: outcome.bucket,
              captured_at: DateTime.utc_now()
            },
            pretty: true
          )
        )

      nil ->
        File.write!(Path.join(target, "metadata.json"), Jason.encode!(outcome, pretty: true))
    end
  end

  defp best_response({:ok, [_ | _], _, response, _}, _empty, query), do: {query, response}
  defp best_response(_search, {:ok, _, _, response, _}, _query), do: {"", response}
  defp best_response({:ok, _, _, response, _}, _empty, query), do: {query, response}
  defp best_response(_, _, _), do: nil

  # The details page a download block reads, so grab fixtures can be reduced.
  defp capture_details_page(dir, %Parsed{id: id, download: download}, %{download_url: url})
       when is_map(download) and is_binary(url) do
    if not String.starts_with?(url, "magnet:") do
      case Req.get(url, retry: false, decode_body: false, receive_timeout: @grab_timeout) do
        {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
          File.write!(Path.join([dir, id, "download_response.html"]), body)

        _ ->
          :ok
      end
    end
  end

  defp capture_details_page(_dir, _parsed, _result), do: :ok

  defp response_file(body) when is_map(body) or is_list(body),
    do: {"response.json", Jason.encode!(body)}

  defp response_file(body) when is_binary(body) do
    if String.starts_with?(String.trim_leading(body), "<?xml"),
      do: {"response.xml", body},
      else: {"response.html", body}
  end
end
