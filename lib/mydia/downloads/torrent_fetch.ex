defmodule Mydia.Downloads.TorrentFetch do
  @moduledoc """
  Turns a search result into input a download client accepts: refuses
  banned info hashes, then fetches the `.torrent` file or resolves the
  magnet link, following redirects, indexer-definition download rules,
  FlareSolverr and scoped cookies. Holds no queue state.
  """

  alias Mydia.Downloads.ContentType
  alias Mydia.Downloads.Blacklists
  alias Mydia.Downloads.ReleaseBlacklist
  alias Mydia.Downloads.TorrentHash
  alias Mydia.Indexers
  require Logger

  # Automatic grabs only: the search jobs pass `enforce_blacklist: true`, and a
  # release the operator picks by hand is an explicit override. An indexer that
  # links to a landing page reveals its torrent only once the link resolves, so
  # search time cannot match it by infohash. The ban it hits is copied onto the
  # result's own key, so the next search filters it before ranking and picks
  # another release.
  @doc false
  def refuse_banned_info_hash(torrent_input, search_result, opts) do
    with true <- Keyword.get(opts, :enforce_blacklist, false),
         hash when is_binary(hash) <- prepared_info_hash(torrent_input),
         %ReleaseBlacklist{} = ban <- Blacklists.active_by_info_hash(hash) do
      Logger.info("Blocked grab: infohash is blacklisted",
        indexer: search_result.indexer,
        title: search_result.title,
        info_hash: hash,
        banned_indexer: ban.indexer,
        failure_reason: ban.failure_reason
      )

      case Blacklists.alias_ban(ban, search_result, hash) do
        {:ok, _row} ->
          :ok

        {:error, reason} ->
          Logger.warning("Could not record the ban under this indexer",
            indexer: search_result.indexer,
            reason: inspect(reason)
          )
      end

      {:error, :blacklisted}
    else
      _not_banned -> :ok
    end
  end

  defp prepared_info_hash({:magnet, magnet}), do: Blacklists.info_hash_from_url(magnet)

  defp prepared_info_hash({:file, body, :torrent}) do
    case TorrentHash.extract({:file, body}, case: :lower) do
      {:ok, hash} -> hash
      {:error, _reason} -> nil
    end
  end

  defp prepared_info_hash(_torrent_input), do: nil

  @doc false
  def prepare_torrent_input(url, indexer_name) do
    result =
      cond do
        # Magnet links can be used directly
        String.starts_with?(url, "magnet:") ->
          {:ok, {:magnet, url}}

        # For HTTP(S) URLs, download the torrent file content
        # This avoids redirect issues that download clients can't handle
        String.starts_with?(url, "http://") or String.starts_with?(url, "https://") ->
          resolve_through_indexer_definition(url, indexer_name)

        # Unknown format, try as URL
        true ->
          {:ok, {:url, url}}
      end

    # Every torrent-producing path funnels back through here: the direct magnet
    # link above, a redirect to a magnet, a response body that *is* a magnet, a
    # magnet scraped out of an HTML page, and a `.torrent` file served by the
    # indexer. Enriching once at the exit keeps a trackerless release from
    # reaching the client with DHT as its only peer source, whether it arrived
    # as a magnet or as a file. NZB payloads carry no trackers and are left
    # alone. See `TorrentHash.ensure_trackers/1` and
    # `TorrentHash.ensure_torrent_trackers/1`.
    case result do
      {:ok, {:magnet, magnet}} ->
        {:ok, {:magnet, TorrentHash.ensure_trackers(magnet)}}

      {:ok, {:file, body, :torrent}} ->
        {:ok, {:file, TorrentHash.ensure_torrent_trackers(body), :torrent}}

      other ->
        other
    end
  end

  # A Cardigann definition can describe how to *derive* a download rather than
  # serve one. Public DHT crawlers in particular hand out a landing page as the
  # row's link and assemble the magnet in client-side JavaScript, so fetching
  # that link returns HTML with no magnet in it to scrape. Consulting the
  # definition's `download:` block first is the only way to grab such an
  # indexer at all.
  #
  # A definition that has no block, or whose block fails, falls back to fetching
  # the link directly, which is what every other indexer needs.
  defp resolve_through_indexer_definition(url, indexer_name) do
    case Indexers.resolve_cardigann_download(indexer_name, url) do
      {:ok, {:magnet, magnet}} ->
        Logger.info("Resolved magnet via #{indexer_name} download block")
        {:ok, {:magnet, magnet}}

      {:ok, {:link, link}} ->
        Logger.info("Resolved download link via #{indexer_name} download block")
        download_torrent_file(link, indexer_name)

      :not_applicable ->
        download_torrent_file(url, indexer_name)

      {:error, reason} ->
        Logger.warning(
          "Download block for #{indexer_name} failed (#{inspect(reason)}), " <>
            "falling back to fetching the link directly"
        )

        download_torrent_file(url, indexer_name)
    end
  end

  defp download_torrent_file(url, indexer_name) do
    Logger.info("Downloading file from #{log_origin(url)}")

    # Get download config for the indexer (cookies and FlareSolverr setting)
    download_config = get_indexer_download_config(indexer_name)

    if download_config.flaresolverr_enabled do
      Logger.info("Using FlareSolverr for download from: #{indexer_name}")
      download_via_flaresolverr(url, indexer_name, download_config.cookies)
    else
      download_direct(url, indexer_name, download_config.cookie_header)
    end
  end

  # A release URL from a private tracker carries the member's credential:
  # Gazelle puts `torrent_pass` and `authkey` in the query, UNIT3D puts the
  # rsskey in the path (`/torrent/download/<id>.<rsskey>`). `redact_url/1` can
  # only see the first, so log lines name the host and nothing after it.
  defp log_origin(url) do
    case URI.parse(url) do
      %URI{scheme: scheme, host: host, port: port} when is_binary(scheme) and is_binary(host) ->
        URI.to_string(%URI{scheme: scheme, host: host, port: port})

      _ ->
        "(unparseable URL)"
    end
  end

  # Encodes a URL to ensure special characters in the path are properly escaped.
  # This handles URLs with spaces, brackets, and other characters that would
  # otherwise cause Req to fail with :invalid_request_target.
  # Example: "http://host/path/Movie Title (2008).nzb" becomes
  #          "http://host/path/Movie%20Title%20%282008%29.nzb"
  defp encode_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{path: nil} = uri ->
        # No path to encode
        URI.to_string(uri)

      %URI{path: path} = uri ->
        # Encode only the path portion, preserving the rest
        # Split path into segments and encode each one
        encoded_path =
          path
          |> String.split("/")
          |> Enum.map_join("/", fn segment ->
            # URI.encode/2 encodes special characters but preserves already-encoded ones
            URI.encode(segment, &URI.char_unreserved?/1)
          end)

        URI.to_string(%{uri | path: encoded_path})
    end
  end

  # Download directly with cookies
  defp download_direct(url, indexer_name, cookie_header) do
    if cookie_header != "" do
      Logger.debug("Using auth cookies for download")
    end

    # Encode the URL to handle special characters (spaces, brackets, etc.)
    encoded_url = encode_url(url)

    # First check if the URL redirects to a magnet link
    # by manually following redirects (Req can't handle magnet: scheme)
    case follow_to_final_url(encoded_url, indexer_name, cookie_header) do
      {:ok, {:magnet, magnet_url}} ->
        Logger.debug("URL redirected to magnet link")
        {:ok, {:magnet, magnet_url}}

      {:ok, {:http, final_url}} ->
        # Download the actual torrent file with auth cookies, scoped to this
        # indexer's own hosts (the final URL may be a different host than the
        # one the request started at).
        scoped_cookie_header = scoped_cookie_header(final_url, indexer_name, cookie_header)

        # Req strips only `authorization` on a cross-origin redirect, never a
        # manual `cookie` header, so a request carrying the cookie must not
        # follow redirects: a 3xx here is a failed download.
        req_opts =
          if scoped_cookie_header != "",
            do: [headers: [{"cookie", scoped_cookie_header}], redirect: false],
            else: []

        case Req.get(final_url, req_opts) do
          {:ok, %{status: 200, body: body}} when is_binary(body) ->
            # No body preview: a private torrent's announce URL holds the passkey.
            Logger.info("Successfully downloaded file (#{byte_size(body)} bytes)")
            classify_body(body)

          {:ok, %{status: status, body: body}} ->
            # Log the response body for debugging - it often contains error details
            body_preview =
              if is_binary(body) and byte_size(body) > 0 do
                String.slice(to_string(body), 0, 1000)
              else
                "(empty body)"
              end

            Logger.error(
              "Failed to download torrent file: HTTP #{status}, response: #{body_preview}"
            )

            {:error, {:download_failed, "HTTP #{status}: #{body_preview}"}}

          {:error, exception} ->
            Logger.error("Failed to download torrent file: #{inspect(exception)}")
            {:error, {:download_failed, "Connection error: #{inspect(exception)}"}}
        end

      {:error, :too_many_redirects} ->
        Logger.error("Too many redirects when downloading from: #{log_origin(url)}")
        {:error, {:download_failed, "Too many redirects (maximum 10)"}}

      {:error, {:redirect_error, message}} ->
        Logger.error("Redirect error for #{log_origin(url)}: #{message}")
        {:error, {:download_failed, "Redirect error: #{message}"}}

      {:error, {:http_error, exception}} ->
        Logger.error("HTTP error when downloading from #{log_origin(url)}: #{inspect(exception)}")
        {:error, {:download_failed, "Connection failed: #{inspect(exception)}"}}

      {:error, {:unexpected_status, status}} ->
        Logger.error("Unexpected HTTP status #{status} when downloading from: #{log_origin(url)}")
        {:error, {:download_failed, "Unexpected HTTP status: #{status}"}}
    end
  end

  # Download via FlareSolverr for Cloudflare-protected sites
  defp download_via_flaresolverr(url, indexer_name, cookies) do
    alias Mydia.Indexers.FlareSolverr

    if FlareSolverr.enabled?() do
      # Pass cookies to FlareSolverr request, scoped to this indexer's own
      # hosts. FlareSolverr used to receive the session unconditionally for
      # any url at all; it now consults the same scope the direct path does.
      cookies =
        if cookies != [] and
             not Indexers.cardigann_download_credential_allowed?(indexer_name, url) do
          Logger.warning(
            "Withholding indexer session cookies from #{log_origin(url)}: not a trusted origin for #{indexer_name}"
          )

          []
        else
          cookies
        end

      flaresolverr_opts =
        if cookies != [] do
          [cookies: cookies]
        else
          []
        end

      case FlareSolverr.get(url, flaresolverr_opts) do
        {:ok, response} ->
          body = response.solution.response

          if is_binary(body) and byte_size(body) > 0 do
            Logger.info("FlareSolverr downloaded file (#{byte_size(body)} bytes)")
            classify_body(body)
          else
            Logger.error("FlareSolverr returned empty response for: #{log_origin(url)}")
            {:error, {:download_failed, "Empty response from FlareSolverr"}}
          end

        {:error, reason} ->
          Logger.error("FlareSolverr download failed: #{inspect(reason)}")
          {:error, {:download_failed, flaresolverr_error_text(reason)}}
      end
    else
      Logger.error("FlareSolverr required but not enabled/configured")
      {:error, {:download_failed, "FlareSolverr required but not configured"}}
    end
  end

  defp flaresolverr_error_text({category, message})
       when is_atom(category) and is_binary(message),
       do: "FlareSolverr: #{message}"

  defp flaresolverr_error_text(:flaresolverr_busy),
    do: "FlareSolverr: busy with other indexers; no request slot freed up in time"

  defp flaresolverr_error_text(reason), do: "FlareSolverr error: #{inspect(reason)}"

  defp follow_to_final_url(url, indexer_name, cookie_header, redirects_remaining \\ 10)

  defp follow_to_final_url(_url, _indexer_name, _cookie_header, 0),
    do: {:error, :too_many_redirects}

  defp follow_to_final_url(url, indexer_name, cookie_header, redirects_remaining) do
    # Build request options with cookies scoped to this hop's own host - a
    # cookie trusted at the previous hop must not follow a redirect off the
    # indexer's origin.
    req_opts =
      [redirect: false] ++
        cookie_header_opt(scoped_cookie_header(url, indexer_name, cookie_header))

    # Try HEAD request first - use redirect: false to get redirect responses directly
    # instead of following them, which avoids exception handling
    case Req.head(url, req_opts) do
      {:ok, %{status: status} = response} when status in 301..308 ->
        # This is a redirect response
        case get_location_header(response.headers) do
          nil ->
            Logger.error(
              "Redirect (#{status}) missing Location header for URL: #{log_origin(url)}"
            )

            {:error, {:redirect_error, "Redirect missing Location header"}}

          location ->
            if String.starts_with?(location, "magnet:") do
              {:ok, {:magnet, location}}
            else
              # Follow the redirect, encoding the location URL to handle special characters
              follow_to_final_url(
                encode_url(location),
                indexer_name,
                cookie_header,
                redirects_remaining - 1
              )
            end
        end

      {:ok, %{status: 200}} ->
        # No redirect, this is the final URL
        {:ok, {:http, url}}

      {:ok, %{status: 405}} ->
        # HEAD not allowed, try GET as fallback
        follow_to_final_url_with_get(url, indexer_name, cookie_header, redirects_remaining)

      {:ok, %{status: status, body: body}} ->
        body_preview =
          if is_binary(body) and byte_size(body) > 0 do
            String.slice(to_string(body), 0, 500)
          else
            "(empty body)"
          end

        Logger.error(
          "Unexpected HTTP status #{status} during redirect check for URL: #{log_origin(url)}, response: #{body_preview}"
        )

        {:error, {:unexpected_status, status}}

      {:error, exception} ->
        {:error, {:http_error, exception}}
    end
  end

  defp follow_to_final_url_with_get(url, indexer_name, cookie_header, redirects_remaining) do
    # Fallback to GET when HEAD is not allowed
    # Build request options with cookies scoped to this hop's own host
    req_opts =
      [redirect: false] ++
        cookie_header_opt(scoped_cookie_header(url, indexer_name, cookie_header))

    case Req.get(url, req_opts) do
      {:ok, %{status: status} = response} when status in 301..308 ->
        # This is a redirect response
        case get_location_header(response.headers) do
          nil ->
            Logger.error(
              "Redirect (#{status}) missing Location header for URL: #{log_origin(url)}"
            )

            {:error, {:redirect_error, "Redirect missing Location header"}}

          location ->
            if String.starts_with?(location, "magnet:") do
              {:ok, {:magnet, location}}
            else
              # Follow the redirect, encoding the location URL to handle special characters
              follow_to_final_url(
                encode_url(location),
                indexer_name,
                cookie_header,
                redirects_remaining - 1
              )
            end
        end

      {:ok, %{status: 200}} ->
        # No redirect, this is the final URL
        {:ok, {:http, url}}

      {:ok, %{status: status, body: body}} ->
        body_preview =
          if is_binary(body) and byte_size(body) > 0 do
            String.slice(to_string(body), 0, 500)
          else
            "(empty body)"
          end

        Logger.error(
          "Unexpected HTTP status #{status} during GET redirect check for URL: #{log_origin(url)}, response: #{body_preview}"
        )

        {:error, {:unexpected_status, status}}

      {:error, exception} ->
        {:error, {:http_error, exception}}
    end
  end

  # Withholds the indexer's session cookie header from a request whose target
  # is not one of the indexer's own hosts, per
  # Indexers.cardigann_download_credential_allowed?/2. `download_url` is
  # remote content chosen by the indexer's own search results (or a redirect
  # from them), so this is consulted before every request that would carry
  # the cookie - including once per redirect hop, since a hop can move the
  # request off the indexer's origin. The request still goes out; withhold
  # and continue rather than failing the download.
  defp scoped_cookie_header(_url, _indexer_name, ""), do: ""

  defp scoped_cookie_header(url, indexer_name, cookie_header) do
    if Indexers.cardigann_download_credential_allowed?(indexer_name, url) do
      cookie_header
    else
      Logger.warning(
        "Withholding indexer session cookie from #{log_origin(url)}: not a trusted origin for #{indexer_name}"
      )

      ""
    end
  end

  defp cookie_header_opt(""), do: []
  defp cookie_header_opt(cookie_header), do: [headers: [{"cookie", cookie_header}]]

  defp get_location_header(headers) do
    Enum.find_value(headers, fn
      {key, [value | _]} when key in ["location", "Location"] -> value
      {key, value} when key in ["location", "Location"] and is_binary(value) -> value
      _ -> nil
    end)
  end

  @doc false
  def maybe_add_opt(opts, _key, nil), do: opts
  def maybe_add_opt(opts, key, value), do: Keyword.put(opts, key, value)

  # Get download configuration for an indexer by name
  # Returns a map with cookies (formatted as header string) and flaresolverr_enabled flag
  defp get_indexer_download_config(nil) do
    %{cookie_header: "", cookies: [], flaresolverr_enabled: false}
  end

  defp get_indexer_download_config(indexer_name) when is_binary(indexer_name) do
    case Mydia.Indexers.get_cardigann_download_config(indexer_name) do
      nil ->
        %{cookie_header: "", cookies: [], flaresolverr_enabled: false}

      config ->
        %{
          cookie_header: format_cookies_for_header(config.cookies),
          cookies: config.cookies,
          flaresolverr_enabled: config.flaresolverr_enabled
        }
    end
  end

  # Convert cookie list to header string
  # Handles both map format (from FlareSolverr) and string format
  defp format_cookies_for_header([]), do: ""

  defp format_cookies_for_header(cookies) when is_list(cookies) do
    cookies
    |> Enum.map(&format_single_cookie/1)
    |> Enum.filter(&(&1 != nil))
    |> Enum.join("; ")
  end

  defp format_single_cookie(%{"name" => name, "value" => value}) when is_binary(name) do
    "#{name}=#{value}"
  end

  defp format_single_cookie(%{name: name, value: value}) when is_binary(name) do
    "#{name}=#{value}"
  end

  defp format_single_cookie(cookie) when is_binary(cookie) do
    # Already a string like "name=value" or "name=value; path=/"
    # Extract just the name=value part
    cookie |> String.split(";") |> List.first() |> String.trim()
  end

  defp format_single_cookie(_), do: nil

  # Classifies a downloaded response body into a magnet link, a torrent/NZB
  # file, or an HTML page from which a magnet link can be scraped.
  #
  # Detection is structural (see ContentType) so trackerless torrents — whose
  # bencode dictionaries do not begin with `8:announce` — are recognised.
  defp classify_body(body) when is_binary(body) and byte_size(body) > 0 do
    case ContentType.detect(body) do
      :magnet ->
        {:ok, {:magnet, String.trim(body)}}

      type when type in [:torrent, :nzb] ->
        Logger.info("Detected #{type} file (#{byte_size(body)} bytes)")
        {:ok, {:file, body, type}}

      :unknown ->
        case extract_magnet_from_html(body) do
          {:ok, magnet_url} ->
            Logger.info("Extracted magnet link from HTML page")
            {:ok, {:magnet, magnet_url}}

          {:error, :no_magnet_found} ->
            Logger.error(
              "Downloaded body was not a recognised torrent/NZB/magnet, and no magnet link was found inside it"
            )

            {:error,
             {:download_failed, "Downloaded content was not a torrent, NZB, or magnet link"}}
        end
    end
  end

  defp classify_body(_),
    do: {:error, {:download_failed, "Empty response body"}}

  # Extracts a magnet link from HTML content
  # This is used when FlareSolverr returns an HTML page (e.g., 1337x torrent detail page)
  # instead of a torrent file
  defp extract_magnet_from_html(html) when is_binary(html) do
    # Parse HTML and look for magnet links
    case Floki.parse_document(html) do
      {:ok, document} ->
        # Try multiple strategies to find magnet links

        # Strategy 1: Look for anchor tags with href starting with "magnet:"
        magnet_links =
          document
          |> Floki.find("a[href^='magnet:']")
          |> Floki.attribute("href")

        # Strategy 2: Also check for data attributes or onclick handlers that might contain magnet
        magnet_from_data =
          if magnet_links == [] do
            document
            |> Floki.find("[data-href^='magnet:'], [data-url^='magnet:']")
            |> Floki.attribute("data-href")
            |> Kernel.++(
              document
              |> Floki.find("[data-href^='magnet:'], [data-url^='magnet:']")
              |> Floki.attribute("data-url")
            )
          else
            []
          end

        all_magnets = magnet_links ++ magnet_from_data

        # Strategy 3: Regex fallback - look for magnet links in raw HTML
        all_magnets =
          if all_magnets == [] do
            case Regex.scan(~r/magnet:\?xt=urn:[a-zA-Z0-9]+:[a-zA-Z0-9]+[^"'\s<>]*/, html) do
              [] -> []
              matches -> Enum.map(matches, fn [match] -> match end)
            end
          else
            all_magnets
          end

        case all_magnets do
          [magnet | _] ->
            # Clean up the magnet link (decode HTML entities)
            cleaned_magnet =
              magnet
              |> String.replace("&amp;", "&")
              |> String.trim()

            {:ok, cleaned_magnet}

          [] ->
            {:error, :no_magnet_found}
        end

      {:error, _reason} ->
        # Try regex fallback if Floki can't parse the HTML
        case Regex.run(~r/magnet:\?xt=urn:[a-zA-Z0-9]+:[a-zA-Z0-9]+[^"'\s<>]*/, html) do
          [magnet | _] ->
            cleaned_magnet =
              magnet
              |> String.replace("&amp;", "&")
              |> String.trim()

            {:ok, cleaned_magnet}

          nil ->
            {:error, :no_magnet_found}
        end
    end
  end
end
