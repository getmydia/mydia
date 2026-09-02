defmodule Mydia.ImportLists.Provider.CustomURL do
  @moduledoc """
  Custom URL provider for import lists.

  Fetches items from user-provided JSON endpoints. Supports flexible JSON formats:

  ## Supported Formats

  1. Array of objects with tmdb_id:
     ```json
     [
       {"tmdb_id": 123, "title": "Movie Name", "year": 2024},
       {"tmdb_id": 456, "title": "Another Movie"}
     ]
     ```

  2. Object with items/results array:
     ```json
     {"items": [{"tmdb_id": 123, "title": "..."}]}
     {"results": [{"tmdb_id": 123, "title": "..."}]}
     ```

  3. Radarr/Sonarr export format:
     ```json
     [{"tmdbId": 123, "title": "..."}, ...]
     ```

  Required fields: tmdb_id (or tmdbId)
  Optional fields: title, year, poster_path

  ## Server-Side Request Forgery (SSRF) protection

  `list_url` is an admin-configured value that this module fetches directly, so it
  is validated before every request:

    * only `http` and `https` schemes are allowed. This is always enforced and is
      not affected by the config switch below.
    * the *resolved* IP address (via DNS, not just the literal host text) must not
      be loopback, an RFC1918 private range, carrier-grade NAT (`100.64.0.0/10`),
      link-local (including the `169.254.169.254` cloud metadata address),
      multicast or reserved (`224.0.0.0/4`, `240.0.0.0/4`), unique-local IPv6
      (`fc00::/7`), unspecified, or broadcast. IPv4-mapped IPv6 forms of these
      (e.g. `::ffff:127.0.0.1`) are unwrapped and checked too. A hostname that
      fails to resolve is rejected.
    * Req's automatic redirect following is disabled and redirects are followed
      manually, so every hop is revalidated against the same rules, up to 5 hops.

  Self-hosted operators legitimately point `list_url` at something on their own
  LAN or container network (a JSON file served by a NAS, say). To allow that, set:

      config :mydia, :import_lists_allow_private_destinations, true

  This defaults to `false`, meaning private/internal destinations are blocked. It
  only relaxes the destination check; the scheme allowlist above is always
  enforced. It is read via `Application.get_env/3` at call time, not a module
  attribute, so it can be changed at runtime and overridden in tests. Operators
  running the container set it with `IMPORT_LISTS_ALLOW_PRIVATE_DESTINATIONS=true`.

  ### Residual risk

  Validation resolves the hostname and then Req resolves it again when it
  connects, so a hostile DNS server that answers differently between those two
  lookups (DNS rebinding) can still get a request sent to a blocked address.
  Closing that means connecting to the validated IP directly and carrying the
  original hostname in the `Host` header plus TLS SNI, which Req does not make
  easy. The guard is defence in depth on an admin-only field, so the simpler
  check is the deliberate trade-off here rather than an oversight.
  """

  @behaviour Mydia.ImportLists.Provider

  import Bitwise

  require Logger

  @allowed_schemes ~w(http https)
  @max_redirects 5
  # Req 0.7.1 has no `max_response_size` request option (see check_response_size/1
  # for the residual risk of the content-length fallback used instead).
  @max_response_bytes 20 * 1024 * 1024

  @impl true
  def supports?("custom_url"), do: true
  def supports?(_), do: false

  @impl true
  def fetch_items(%{type: "custom_url", config: config, media_type: media_type}) do
    url = get_in(config, ["list_url"])

    case url do
      nil ->
        {:error, "No URL configured"}

      url when is_binary(url) ->
        fetch_from_url(url, media_type)
    end
  end

  def fetch_items(_), do: {:error, "Invalid import list type for CustomURL provider"}

  @doc false
  # Exposed (but undocumented in public docs) so tests can exercise the SSRF
  # guard directly against literal addresses and hostnames without needing a
  # live server for every case.
  @spec validate_url(String.t()) :: :ok | {:error, String.t()}
  def validate_url(url) do
    with :ok <- validate_scheme(url) do
      validate_destination(url)
    end
  end

  ## Private Functions

  defp fetch_from_url(url, media_type) do
    Logger.info("[CustomURL] Fetching from URL", url: url)

    with {:ok, response} <- fetch_with_redirects(url, @max_redirects) do
      handle_response(response, media_type)
    end
  end

  defp fetch_with_redirects(url, redirects_remaining) do
    with :ok <- validate_url(url),
         {:ok, response} <- do_get(url) do
      maybe_follow_redirect(response, url, redirects_remaining)
    end
  end

  defp maybe_follow_redirect(%{status: status}, _url, 0)
       when status in [301, 302, 303, 307, 308] do
    {:error, "Too many redirects (max #{@max_redirects}) while fetching import list URL"}
  end

  defp maybe_follow_redirect(%{status: status} = response, url, redirects_remaining)
       when status in [301, 302, 303, 307, 308] do
    with {:ok, location} <- get_redirect_location(response),
         {:ok, next_url} <- resolve_redirect_url(url, location) do
      Logger.debug("[CustomURL] Following redirect", from: url, to: next_url)
      fetch_with_redirects(next_url, redirects_remaining - 1)
    end
  end

  defp maybe_follow_redirect(response, _url, _redirects_remaining), do: {:ok, response}

  defp get_redirect_location(response) do
    case Req.Response.get_header(response, "location") do
      [location | _] -> {:ok, location}
      [] -> {:error, "Redirect response is missing a Location header"}
    end
  end

  defp resolve_redirect_url(base_url, location) do
    next_url =
      base_url
      |> URI.parse()
      |> URI.merge(location)
      |> URI.to_string()

    {:ok, next_url}
  end

  defp do_get(url) do
    req =
      Req.new(
        url: url,
        headers: [
          {"accept", "application/json"},
          {"user-agent", "Mydia/1.0"}
        ],
        receive_timeout: 30_000,
        # Redirects are followed manually in `fetch_with_redirects/2` so each hop
        # can be revalidated; Req would otherwise follow them itself before we
        # get a chance to check the destination.
        redirect: false
      )

    case Req.get(req) do
      {:ok, response} -> check_response_size(response)
      {:error, %{reason: reason}} -> {:error, "Request failed: #{inspect(reason)}"}
      {:error, error} -> {:error, "Request failed: #{inspect(error)}"}
    end
  end

  # Req 0.7.1 does not expose a `max_response_size` request option, and by the
  # time a response reaches here Req has already buffered the whole body, so
  # this only stops a badly-behaved-but-honest server that declares an
  # oversized body up front via `content-length`. A server that omits or lies
  # about `content-length`, or streams via chunked transfer-encoding, can still
  # force a large allocation before this check runs. Fully closing that gap
  # would need streaming consumption with a running byte cap (Req's `into: fun`
  # option), which is a bigger change than this guard warrants today.
  defp check_response_size(response) do
    case declared_content_length(response) do
      size when is_integer(size) and size > @max_response_bytes ->
        {:error, "Response body too large (#{size} bytes declared, max #{@max_response_bytes})"}

      _ ->
        {:ok, response}
    end
  end

  defp declared_content_length(response) do
    case Req.Response.get_header(response, "content-length") do
      [value | _] -> parse_int(value)
      [] -> nil
    end
  end

  defp handle_response(%{status: 200, body: body}, media_type) when is_list(body) do
    parse_items(body, media_type)
  end

  defp handle_response(%{status: 200, body: %{"items" => items}}, media_type)
       when is_list(items) do
    parse_items(items, media_type)
  end

  defp handle_response(%{status: 200, body: %{"results" => results}}, media_type)
       when is_list(results) do
    parse_items(results, media_type)
  end

  defp handle_response(%{status: 200, body: body}, _media_type) do
    Logger.warning("[CustomURL] Unexpected response format", body: inspect(body))
    {:error, "Unexpected JSON format - expected array or object with items/results key"}
  end

  defp handle_response(%{status: status, body: body}, _media_type) do
    {:error, "HTTP #{status}: #{inspect(body)}"}
  end

  ## Destination validation (SSRF guard)

  defp validate_scheme(url) do
    case URI.parse(url).scheme do
      scheme when scheme in @allowed_schemes ->
        :ok

      scheme ->
        {:error, "Unsupported URL scheme #{inspect(scheme)}; only http and https are allowed"}
    end
  end

  defp validate_destination(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" ->
        with {:ok, addrs} <- resolve_host(host) do
          reject_blocked_addresses(addrs, host)
        end

      _ ->
        {:error, "URL is missing a host"}
    end
  end

  defp resolve_host(host) do
    charlist = String.to_charlist(host)
    addrs = getaddrs(charlist, :inet) ++ getaddrs(charlist, :inet6)

    case addrs do
      [] -> {:error, "Could not resolve host #{host}"}
      addrs -> {:ok, addrs}
    end
  end

  defp getaddrs(charlist, family) do
    case :inet.getaddrs(charlist, family) do
      {:ok, addrs} -> addrs
      {:error, _reason} -> []
    end
  end

  defp reject_blocked_addresses(addrs, host) do
    if allow_private_destinations?() do
      :ok
    else
      case Enum.find(addrs, &(not public_address?(&1))) do
        nil ->
          :ok

        blocked ->
          {:error,
           "Refusing to fetch #{host}: resolves to a private/internal address (#{format_ip(blocked)})"}
      end
    end
  end

  defp allow_private_destinations? do
    Application.get_env(:mydia, :import_lists_allow_private_destinations, false)
  end

  defp format_ip(ip), do: ip |> :inet.ntoa() |> to_string()

  defp public_address?(ip) when tuple_size(ip) == 4, do: public_ipv4?(ip)
  defp public_address?(ip) when tuple_size(ip) == 8, do: public_ipv6?(ip)

  defp public_ipv4?({0, 0, 0, 0}), do: false
  defp public_ipv4?({255, 255, 255, 255}), do: false
  defp public_ipv4?({127, _, _, _}), do: false
  defp public_ipv4?({10, _, _, _}), do: false
  defp public_ipv4?({172, b, _, _}) when b in 16..31, do: false
  defp public_ipv4?({192, 168, _, _}), do: false
  defp public_ipv4?({169, 254, _, _}), do: false
  # 100.64.0.0/10 - carrier-grade NAT. Plenty of home ISPs hand these out, so
  # for a self-hosted install this is neighbouring equipment, not the internet.
  defp public_ipv4?({100, b, _, _}) when b in 64..127, do: false
  # 198.18.0.0/15 - benchmarking range, routed internally on some networks.
  defp public_ipv4?({198, b, _, _}) when b in 18..19, do: false
  # 224.0.0.0/4 multicast and 240.0.0.0/4 reserved. Never a valid list host.
  defp public_ipv4?({a, _, _, _}) when a in 224..255, do: false
  defp public_ipv4?(_), do: true

  defp public_ipv6?({0, 0, 0, 0, 0, 0, 0, 0}), do: false
  defp public_ipv6?({0, 0, 0, 0, 0, 0, 0, 1}), do: false

  # IPv4-mapped IPv6 (::ffff:a.b.c.d): unwrap and validate the embedded IPv4
  # address so a blocked address cannot be smuggled past the IPv6-only checks
  # below (e.g. ::ffff:127.0.0.1).
  defp public_ipv6?({0, 0, 0, 0, 0, 0xFFFF, hi, lo}), do: public_ipv4?(embedded_ipv4(hi, lo))

  # fc00::/7 - unique local addresses.
  defp public_ipv6?({h1, _, _, _, _, _, _, _}) when (h1 &&& 0xFE00) == 0xFC00, do: false
  # fe80::/10 - link-local addresses.
  defp public_ipv6?({h1, _, _, _, _, _, _, _}) when (h1 &&& 0xFFC0) == 0xFE80, do: false
  # fec0::/10 - deprecated site-local, still routed on some internal networks.
  defp public_ipv6?({h1, _, _, _, _, _, _, _}) when (h1 &&& 0xFFC0) == 0xFEC0, do: false
  # ff00::/8 - multicast. Never a valid list host.
  defp public_ipv6?({h1, _, _, _, _, _, _, _}) when (h1 &&& 0xFF00) == 0xFF00, do: false
  defp public_ipv6?(_), do: true

  defp embedded_ipv4(hi, lo), do: {hi >>> 8, hi &&& 0xFF, lo >>> 8, lo &&& 0xFF}

  ## JSON item parsing

  defp parse_items(items, media_type) do
    parsed =
      items
      |> Enum.map(&parse_item(&1, media_type))
      |> Enum.filter(&(&1 != nil))

    Logger.info("[CustomURL] Parsed #{length(parsed)} items from #{length(items)} entries")
    {:ok, parsed}
  end

  defp parse_item(item, media_type) when is_map(item) do
    # Try different field name conventions
    tmdb_id = get_tmdb_id(item)

    if tmdb_id do
      %{
        tmdb_id: tmdb_id,
        title: get_title(item),
        year: get_year(item),
        poster_path: get_poster_path(item),
        media_type: media_type
      }
    else
      Logger.debug("[CustomURL] Skipping item without tmdb_id", item: inspect(item))
      nil
    end
  end

  defp parse_item(_, _), do: nil

  # Support multiple field naming conventions for tmdb_id
  defp get_tmdb_id(item) do
    cond do
      is_integer(item["tmdb_id"]) -> item["tmdb_id"]
      is_integer(item["tmdbId"]) -> item["tmdbId"]
      is_integer(item["id"]) -> item["id"]
      is_binary(item["tmdb_id"]) -> parse_int(item["tmdb_id"])
      is_binary(item["tmdbId"]) -> parse_int(item["tmdbId"])
      is_binary(item["id"]) -> parse_int(item["id"])
      true -> nil
    end
  end

  defp get_title(item) do
    item["title"] || item["name"] || item["originalTitle"] || "Unknown"
  end

  defp get_year(item) do
    cond do
      is_integer(item["year"]) ->
        item["year"]

      is_binary(item["year"]) ->
        parse_int(item["year"])

      is_binary(item["release_date"]) and byte_size(item["release_date"]) >= 4 ->
        parse_int(String.slice(item["release_date"], 0, 4))

      is_binary(item["first_air_date"]) and byte_size(item["first_air_date"]) >= 4 ->
        parse_int(String.slice(item["first_air_date"], 0, 4))

      is_binary(item["releaseDate"]) and byte_size(item["releaseDate"]) >= 4 ->
        parse_int(String.slice(item["releaseDate"], 0, 4))

      true ->
        nil
    end
  end

  defp get_poster_path(item) do
    item["poster_path"] || item["posterPath"] || item["poster"]
  end

  defp parse_int(str) when is_binary(str) do
    case Integer.parse(str) do
      {int, _} -> int
      :error -> nil
    end
  end

  defp parse_int(_), do: nil
end
