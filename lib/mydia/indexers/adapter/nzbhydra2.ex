defmodule Mydia.Indexers.Adapter.NzbHydra2 do
  @moduledoc """
  NZBHydra2 indexer adapter.

  NZBHydra2 is a meta search aggregator for Usenet NZB indexers. It provides
  a unified Newznab-compatible API to search across multiple NZB indexers.

  ## API Documentation

  NZBHydra2 API: https://github.com/theotherp/nzbhydra2/wiki/API

  ## Authentication

  Authentication is done via the `apikey` query parameter.

  ## Search Endpoint

  The search endpoint returns results in Newznab XML format by default,
  or JSON with `o=json` parameter:
  - `GET /api?apikey={key}&t=search&q={query}`
  - `GET /api?apikey={key}&t=search&q={query}&o=json`

  ## Example Usage

      config = %{
        type: :nzbhydra2,
        name: "NZBHydra2",
        host: "localhost",
        port: 5076,
        api_key: "your-api-key",
        use_ssl: false,
        options: %{
          timeout: 30_000
        }
      }

      {:ok, results} = NzbHydra2.search(config, "Ubuntu 22.04")
  """

  @behaviour Mydia.Indexers.Adapter

  alias Mydia.Indexers.{SearchResult, QualityParser}
  alias Mydia.Indexers.Adapter.Error

  import SweetXml

  require Logger

  @connect_timeout 10_000

  # Newznab XML namespace
  @newznab_ns "http://www.newznab.com/DTD/2010/feeds/attributes/"

  @impl true
  def test_connection(config) do
    url = build_url(config, "/api")
    params = [{"apikey", config.api_key}, {"t", "caps"}]
    query_string = URI.encode_query(params)
    full_url = "#{url}?#{query_string}"

    Logger.debug("NZBHydra2 test connection: #{full_url}")

    case Req.get(full_url, receive_timeout: 10_000, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        parse_caps_response(body)

      {:ok, %Req.Response{status: 401}} ->
        {:error, Error.authentication_failed("Invalid API key")}

      {:ok, %Req.Response{status: 403}} ->
        {:error, Error.authentication_failed("Access forbidden - check API key")}

      {:ok, %Req.Response{status: status}} ->
        {:error, Error.connection_failed("HTTP #{status}")}

      {:error, %Req.TransportError{reason: reason}} ->
        {:error, Error.connection_failed("Connection failed: #{inspect(reason)}")}

      {:error, reason} ->
        {:error, Error.connection_failed("Request failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def search(config, query, opts \\ []) do
    url = build_search_url(config, query, opts)
    timeout = get_in(config, [:options, :timeout]) || 30_000

    Logger.debug("NZBHydra2 search: #{url}")

    case Req.get(url,
           receive_timeout: timeout,
           connect_options: [timeout: @connect_timeout],
           retry: false
         ) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        parse_search_response(body, config.name)

      {:ok, %Req.Response{status: 401}} ->
        {:error, Error.authentication_failed("Invalid API key")}

      {:ok, %Req.Response{status: 403}} ->
        {:error, Error.authentication_failed("Access forbidden")}

      {:ok, %Req.Response{status: 429}} ->
        {:error, Error.rate_limited("Rate limit exceeded")}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("NZBHydra2 search failed with status #{status}: #{inspect(body)}")
        {:error, Error.search_failed("HTTP #{status}")}

      {:error, %Req.TransportError{reason: :timeout}} ->
        {:error, Error.timeout("Request timeout")}

      {:error, reason} ->
        {:error, Error.search_failed("Request failed: #{inspect(reason)}")}
    end
  end

  @impl true
  def get_capabilities(config) do
    case test_connection(config) do
      {:ok, caps} when is_map(caps) and not is_map_key(caps, :name) ->
        {:ok, caps}

      {:ok, %{name: _}} ->
        fetch_capabilities(config)

      {:error, reason} ->
        {:error, reason}
    end
  end

  ## Private Functions

  defp build_url(config, path) do
    scheme = if Map.get(config, :use_ssl, false), do: "https", else: "http"
    base_path = get_in(config, [:options, :base_path]) || ""
    "#{scheme}://#{config.host}:#{config.port}#{base_path}#{path}"
  end

  defp build_search_url(config, query, opts) do
    categories = opts[:categories] || get_in(config, [:options, :categories]) || []
    limit = opts[:limit] || 100

    params =
      [
        {"apikey", config.api_key},
        {"t", "search"},
        {"q", query}
      ]
      |> maybe_add_param("limit", limit)
      |> maybe_add_list_param("cat", categories)

    base_url = build_url(config, "/api")
    query_string = URI.encode_query(params)

    "#{base_url}?#{query_string}"
  end

  defp maybe_add_param(params, _key, nil), do: params
  defp maybe_add_param(params, _key, ""), do: params
  defp maybe_add_param(params, key, value), do: params ++ [{key, value}]

  defp maybe_add_list_param(params, _key, []), do: params

  defp maybe_add_list_param(params, key, list) when is_list(list) do
    params ++ [{key, Enum.join(list, ",")}]
  end

  defp parse_caps_response(body) when is_binary(body) do
    try do
      doc = SweetXml.parse(body)

      server = xpath(doc, ~x"//caps/server/@appname"s)
      version = xpath(doc, ~x"//caps/server/@version"s)

      {:ok,
       %{
         name: if(server != "", do: server, else: "NZBHydra2"),
         version: if(version != "", do: version, else: "unknown"),
         app_name: "NZBHydra2"
       }}
    rescue
      error ->
        Logger.error("Failed to parse NZBHydra2 caps response: #{inspect(error)}")
        {:ok, %{name: "NZBHydra2", version: "unknown", app_name: "NZBHydra2"}}
    end
  end

  defp fetch_capabilities(config) do
    url = build_url(config, "/api")
    params = [{"apikey", config.api_key}, {"t", "caps"}]
    query_string = URI.encode_query(params)
    full_url = "#{url}?#{query_string}"

    case Req.get(full_url, receive_timeout: 10_000, retry: false) do
      {:ok, %Req.Response{status: 200, body: body}} ->
        parse_capabilities_xml(body)

      {:ok, %Req.Response{status: status}} ->
        {:error, Error.connection_failed("HTTP #{status}")}

      {:error, reason} ->
        {:error, Error.connection_failed("Request failed: #{inspect(reason)}")}
    end
  end

  defp parse_capabilities_xml(body) when is_binary(body) do
    try do
      doc = SweetXml.parse(body)

      categories =
        doc
        |> xpath(
          ~x"//categories/category"l,
          id: ~x"./@id"s,
          name: ~x"./@name"s
        )
        |> Enum.map(fn cat ->
          %{
            id: String.to_integer(cat.id),
            name: cat.name
          }
        end)

      {:ok,
       %{
         searching: %{
           search: %{available: true, supported_params: ["q"]},
           tv_search: %{available: true, supported_params: ["q", "season", "ep", "tvdbid", "rid"]},
           movie_search: %{available: true, supported_params: ["q", "imdbid", "tmdbid"]}
         },
         categories: categories
       }}
    rescue
      error ->
        Logger.error("Failed to parse NZBHydra2 capabilities: #{inspect(error)}")
        {:error, Error.parse_error("Failed to parse capabilities XML")}
    end
  end

  defp parse_search_response(body, indexer_name) when is_binary(body) do
    try do
      doc = SweetXml.parse(body)

      results =
        doc
        |> xpath(
          ~x"//channel/item"l,
          title: ~x"./title/text()"s,
          link: ~x"./link/text()"s,
          guid: ~x"./guid/text()"s,
          comments: ~x"./comments/text()"s,
          pub_date: ~x"./pubDate/text()"s,
          size: ~x"./enclosure/@length"s,
          enclosure_url: ~x"./enclosure/@url"s,
          # Newznab attributes
          size_attr:
            ~x"./newznab:attr[@name='size']/@value"s |> add_namespace("newznab", @newznab_ns),
          grabs:
            ~x"./newznab:attr[@name='grabs']/@value"s |> add_namespace("newznab", @newznab_ns),
          category:
            ~x"./newznab:attr[@name='category']/@value"s |> add_namespace("newznab", @newznab_ns),
          tmdb_id:
            ~x"./newznab:attr[@name='tmdbid']/@value"s |> add_namespace("newznab", @newznab_ns),
          imdb_id:
            ~x"./newznab:attr[@name='imdbid']/@value"s |> add_namespace("newznab", @newznab_ns),
          tvdb_id:
            ~x"./newznab:attr[@name='tvdbid']/@value"s |> add_namespace("newznab", @newznab_ns),
          indexer:
            ~x"./newznab:attr[@name='indexer']/@value"s |> add_namespace("newznab", @newznab_ns),
          usenetdate:
            ~x"./newznab:attr[@name='usenetdate']/@value"s
            |> add_namespace("newznab", @newznab_ns),
          completion:
            ~x"./newznab:attr[@name='completion']/@value"s
            |> add_namespace("newznab", @newznab_ns)
        )
        |> Enum.map(fn item ->
          parse_result_item(item, indexer_name)
        end)
        |> Enum.reject(&is_nil/1)

      {:ok, results}
    rescue
      error ->
        Logger.error("Failed to parse NZBHydra2 search response: #{inspect(error)}")
        Logger.debug("Body: #{inspect(body)}")
        {:error, Error.parse_error("Failed to parse search results XML")}
    end
  end

  defp parse_result_item(item, indexer_name) do
    try do
      title = item.title

      # Size from enclosure or newznab attr
      size =
        cond do
          item.size_attr != "" -> String.to_integer(item.size_attr)
          item.size != "" -> String.to_integer(item.size)
          true -> 0
        end

      # Grabs count (NZB popularity indicator - not a seeder analogue)
      nzb_grabs =
        case item.grabs do
          "" -> nil
          grabs_str -> String.to_integer(grabs_str)
        end

      # Usenet posting date (some Usenet indexers expose this distinctly from pubDate)
      usenet_date =
        case item.usenetdate do
          "" -> nil
          date_string -> parse_datetime(date_string)
        end

      # Article completion ratio (0.0..1.0) when reported
      nzb_completion = parse_completion(item.completion)

      # Download URL - prefer enclosure, fall back to link
      download_url =
        cond do
          item.enclosure_url != "" -> item.enclosure_url
          item.link != "" -> item.link
          true -> ""
        end

      # Info URL - prefer comments, fall back to guid
      info_url =
        cond do
          item.comments != "" -> item.comments
          item.guid != "" -> item.guid
          true -> nil
        end

      # Indexer - prefer item indexer attribute, fall back to configured name
      indexer =
        if item.indexer != "", do: item.indexer, else: indexer_name

      # Category
      category =
        case item.category do
          "" -> nil
          cat_str -> String.to_integer(cat_str)
        end

      # Parse published date
      published_at =
        case item.pub_date do
          "" -> nil
          date_string -> parse_datetime(date_string)
        end

      # Parse quality from title
      quality = QualityParser.parse(title)

      # Parse TMDB ID
      tmdb_id =
        case item.tmdb_id do
          "" -> nil
          id_str -> String.to_integer(id_str)
        end

      # Parse TVDB ID
      tvdb_id =
        case item.tvdb_id do
          "" -> nil
          id_str -> String.to_integer(id_str)
        end

      # Parse IMDB ID
      imdb_id =
        case item.imdb_id do
          "" -> nil
          id_str -> normalize_imdb_id(id_str)
        end

      # Skip results without download URL
      if download_url == "" do
        Logger.debug("Skipping result without download URL: #{title}")
        nil
      else
        # Stable release identifier used by the release blacklist (#123).
        guid =
          cond do
            item.guid != "" -> item.guid
            item.comments != "" -> item.comments
            true -> nil
          end

        SearchResult.new(
          title: title,
          size: size,
          # NZB results have no seeders/leechers concept - keep nil so consumers
          # don't conflate Usenet "grabs" with torrent seeders. NZB-specific
          # popularity lives in :nzb_grabs.
          seeders: nil,
          leechers: nil,
          download_url: download_url,
          info_url: info_url,
          indexer: indexer,
          category: category,
          published_at: published_at,
          quality: quality,
          tmdb_id: tmdb_id,
          tvdb_id: tvdb_id,
          imdb_id: imdb_id,
          # Always NZB protocol for NZBHydra2
          download_protocol: :nzb,
          usenet_date: usenet_date,
          nzb_completion: nzb_completion,
          nzb_grabs: nzb_grabs,
          guid: guid
        )
      end
    rescue
      error ->
        Logger.error("Failed to parse NZBHydra2 result item: #{inspect(error)}")
        Logger.debug("Item: #{inspect(item)}")
        nil
    end
  end

  defp parse_datetime(date_string) do
    # Newznab uses RFC 2822 date format (like RSS)
    # Example: "Mon, 02 Jan 2006 15:04:05 -0700"
    case Timex.parse(date_string, "{RFC1123}") do
      {:ok, datetime} ->
        datetime

      {:error, _reason} ->
        # Some Usenet indexers expose usenetdate as a Unix timestamp.
        parse_unix_timestamp(date_string)
    end
  end

  defp parse_unix_timestamp(""), do: nil

  defp parse_unix_timestamp(value) when is_binary(value) do
    case Integer.parse(value) do
      {seconds, ""} ->
        case DateTime.from_unix(seconds) do
          {:ok, datetime} -> datetime
          _ -> nil
        end

      _ ->
        nil
    end
  end

  # Newznab "completion" attribute is typically an integer 0..100 (percent) but
  # some indexers expose it as 0.0..1.0. Normalize to a 0.0..1.0 float.
  defp parse_completion(""), do: nil

  defp parse_completion(value) when is_binary(value) do
    case Float.parse(value) do
      {n, _} when n > 1.0 -> Float.round(n / 100.0, 4)
      {n, _} when n >= 0.0 -> Float.round(n, 4)
      _ -> nil
    end
  end

  # Normalizes IMDB ID to standard format (tt1234567)
  defp normalize_imdb_id(id_str) do
    trimmed = String.trim(id_str)

    cond do
      # Already in correct format
      String.starts_with?(trimmed, "tt") -> trimmed
      # Just the numeric part - add tt prefix
      String.match?(trimmed, ~r/^\d+$/) -> "tt#{trimmed}"
      # Invalid format
      true -> trimmed
    end
  end
end
