defmodule Mydia.Indexers.Cardigann.CredentialScope do
  @moduledoc """
  Decides which origins may receive a definition's session cookies and login
  credentials.

  A Cardigann session cookie is a bearer credential for a tracker account. It is
  scoped to the origins a definition names as its own site: every entry in
  `links`, plus the origin of any `search.paths` or `login.path` that renders to
  an absolute URL. Those absolute paths are operator-configurable settings such
  as `{{ .Config.apiurl }}`, and every one shipped in the v11 corpus resolves to
  a sibling subdomain of the site (`api.v3x.club` beside `v3x.club`).

  `legacylinks` are deliberately excluded. `Mydia.Indexers.Cardigann.Links`
  offers them as failover targets, which is a public tracker recovery path, but
  they are by construction stale rotated domains: 149 of the 545 shipped v11
  definitions carry a legacy host absent from their `links`, 95 of them private.
  A re-registered legacy domain must not be handed a live session.

  Matching is an exact, case-insensitive origin comparison: host and port both
  have to agree. There is deliberately no eTLD+1 and no subdomain-suffix rule.
  `limetorrents.proxyninja.net` and `extratorrent.ninjaproxy1.com` are shipped
  `links` entries on shared proxy services that front many unrelated trackers,
  so a suffix rule would admit `sometracker.proxyninja.net` and leak one
  tracker's session to a neighbour.
  """

  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.CardigannTemplate

  # Read under both spellings. `definition.config` is a
  # `Mydia.Settings.JsonMapType` and comes back string-keyed from
  # `Jason.decode/1`, while a session map built in code is atom-keyed.
  @credential_keys [:cookies, :cookie, :username, :password, :api_key, :apikey, :passkey]

  @doc """
  Returns the normalized `"host:port"` origins this definition's credentials
  may be sent to.
  """
  @spec trusted_origins(Parsed.t(), map()) :: MapSet.t(String.t())
  def trusted_origins(%Parsed{} = parsed, config) when is_map(config) do
    link_origins =
      parsed.links
      |> List.wrap()
      |> Enum.flat_map(&origin_of/1)

    template_origins =
      parsed
      |> absolute_templates()
      |> Enum.flat_map(&rendered_origin(&1, parsed, config))

    MapSet.new(link_origins ++ template_origins)
  end

  def trusted_origins(%Parsed{} = parsed, _config), do: trusted_origins(parsed, %{})

  @doc """
  True when `url`'s origin is in `origins`. A url without a parseable host is
  never allowed.
  """
  @spec allows?(MapSet.t(String.t()), String.t()) :: boolean()
  def allows?(%MapSet{} = origins, url) when is_binary(url) do
    case origin_of(url) do
      [origin] -> MapSet.member?(origins, origin)
      [] -> false
    end
  end

  def allows?(_hosts, _url), do: false

  @doc """
  True when the map carries a credential worth protecting.

  Blank values do not count. The admin form submits untouched fields as "", and
  an empty cookie list is not a credential, which is the distinction that made
  every private indexer skip its form login before #601.
  """
  @spec credentialed?(map()) :: boolean()
  def credentialed?(config) when is_map(config) do
    Enum.any?(@credential_keys, fn key -> config |> lookup(key) |> present?() end)
  end

  def credentialed?(_config), do: false

  defp lookup(map, key) when is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp present?(nil), do: false
  defp present?([]), do: false
  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: true

  # Scope is an origin, not a bare host. `URI.parse/1` already fills in the
  # scheme's default port (443 for https, 80 for http), so an explicit
  # `https://x:443` and a bare `https://x` normalize to the same origin.
  #
  # Ports matter because Mydia is self-hosted: several services behind one host
  # on different ports is the normal deployment, and the corpus ships that shape
  # already (bitmagnet lists 127.0.0.1). Matching on the host alone would let a
  # session for one local service be handed to another service on the same host,
  # the same failure that rules out subdomain-suffix matching for the shared
  # proxy domains in `links`.
  defp origin_of(url) when is_binary(url) do
    case URI.parse(String.trim(url)) do
      %URI{host: host, port: port} when is_binary(host) and host != "" ->
        ["#{String.downcase(host)}:#{port || 0}"]

      _ ->
        []
    end
  end

  defp origin_of(_url), do: []

  defp absolute_templates(%Parsed{} = parsed) do
    search_paths =
      parsed.search
      |> case do
        %{} = search -> Map.get(search, :paths) || Map.get(search, "paths") || []
        _ -> []
      end
      |> List.wrap()
      |> Enum.map(fn
        %{} = path -> Map.get(path, :path) || Map.get(path, "path")
        _ -> nil
      end)

    login_path =
      case parsed.login do
        %{} = login -> Map.get(login, :path) || Map.get(login, "path")
        _ -> nil
      end

    [login_path | search_paths]
    |> Enum.filter(fn template -> is_binary(template) and absolute_template?(template) end)
  end

  # Only a template that already opens with a scheme can render to another host.
  # A relative path can never introduce one, so it is skipped without being
  # rendered at all.
  defp absolute_template?(template), do: Regex.match?(~r{^https?://}i, template)

  defp rendered_origin(template, %Parsed{} = parsed, config) do
    context = %{
      keywords: "",
      config: config,
      query: %{series: "", season: nil, episode: nil, imdb_id: nil, tmdb_id: nil, tvdb_id: nil},
      categories: [],
      settings: parsed.settings
    }

    # url_encode: false because only the origin is wanted and percent-encoding a
    # config value would corrupt it. A template that will not render contributes
    # no origin, which withholds rather than leaks.
    case CardigannTemplate.render(template, context, url_encode: false) do
      {:ok, rendered} -> origin_of(rendered)
      _ -> []
    end
  end
end
