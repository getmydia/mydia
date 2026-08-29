defmodule Mydia.Indexers.CardigannDownload do
  @moduledoc """
  Resolves a Cardigann `download:` block into a concrete torrent input.

  Public DHT crawlers rarely serve a `.torrent` at the link a search row
  carries. The row points at a human-facing landing page, and the definition
  describes how to derive the real download from it:

    * `before` - a preliminary request, usually to a JSON metadata API, whose
      response carries the data the selectors below need.
    * `infohash` - `hash` and `title` selectors that pull a 40-hex infohash and
      a name out of a response, from which a magnet is built. When
      `usebeforeresponse` is set the selectors read the `before` response
      rather than a fresh fetch of the landing page.

  Without this step the grab path fetches the landing page directly and gets
  HTML back, which is neither a torrent nor a magnet. Sites that build their
  magnet in client-side JavaScript cannot be rescued by scraping the HTML,
  because the link is never in the markup to begin with.
  """

  require Logger

  alias Mydia.Downloads.TorrentHash
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.CardigannResultParser
  alias Mydia.Indexers.CardigannSearchEngine
  alias Mydia.Indexers.CardigannTemplate

  @typedoc """
  A resolved download. `:magnet` is ready to hand to a client as-is;
  `:link` still needs to be fetched by the caller.
  """
  @type resolved :: {:magnet, String.t()} | {:link, String.t()}

  # Cardigann definitions use `:root` to mean "the whole response". Jackett gets
  # this for free by parsing every body as HTML and reading the document's text,
  # which for a JSON body is the JSON itself. Matching that explicitly keeps
  # JSON responses working without pretending they are markup.
  @whole_document_selectors [":root", "", nil]

  @doc """
  Resolves `download_url` through the definition's `download:` block.

  `user_config` is passed through to the HTTP layer for cookies, and matches
  the shape `Mydia.Indexers.CardigannSearchEngine.execute_http_request/5`
  expects. Its optional `:config` key carries the operator's settings, which
  are threaded through to the credential scope so a templated absolute path
  (`{{ .Config.apiurl }}` in `search.paths` or `login.path`) resolves against
  the operator's real configuration rather than a definition's shipped
  default. A caller that omits `:config` still gets a scope built from
  `links` plus whatever a shipped default renders, just not the operator's
  actual value.

  Returns `:not_applicable` when the definition has no `download:` block, or has
  one carrying neither a usable `infohash` nor any `selectors`, which lets the
  caller fall back to fetching the link directly.
  """
  @spec resolve(Parsed.t(), String.t(), map()) ::
          {:ok, resolved()} | {:error, term()} | :not_applicable
  def resolve(definition, download_url, user_config \\ %{})

  def resolve(%Parsed{download: download} = definition, download_url, user_config)
      when is_map(download) do
    with {:ok, download_url} <- absolutize_download_url(definition, download_url, user_config) do
      variables = template_variables(download_url)
      infohash = Map.get(download, :infohash)
      selectors = Map.get(download, :selectors) || []

      cond do
        usable_infohash?(infohash) ->
          with {:ok, before_response} <-
                 run_before(definition, Map.get(download, :before), variables, user_config) do
            resolve_infohash(
              definition,
              infohash,
              download_url,
              before_response,
              variables,
              user_config
            )
          end

        selectors != [] ->
          with {:ok, before_response} <-
                 run_before(definition, Map.get(download, :before), variables, user_config) do
            resolve_selectors(
              definition,
              selectors,
              download_url,
              before_response,
              variables,
              user_config
            )
          end

        true ->
          :not_applicable
      end
    end
  end

  def resolve(_definition, _download_url, _user_config), do: :not_applicable

  defp usable_infohash?(%{hash: hash}) when is_map(hash), do: true
  defp usable_infohash?(_), do: false

  # -- before request ---------------------------------------------------------

  defp run_before(_definition, nil, _variables, _user_config), do: {:ok, nil}

  defp run_before(definition, before, variables, user_config) when is_map(before) do
    with {:ok, base_url} <- base_url(definition, user_config),
         {:ok, path} <- render(Map.get(before, :path, ""), variables),
         {:ok, inputs} <- render_inputs(Map.get(before, :inputs) || %{}, variables) do
      url = join_url(base_url, path)

      params = %{
        query_params: inputs,
        headers: [],
        method: http_method(Map.get(before, :method, "get")),
        decode_body: false
      }

      Logger.debug("Cardigann download before-request: #{url} #{inspect(inputs)}")

      CardigannSearchEngine.execute_http_request(
        definition,
        url,
        params,
        user_config,
        scope_config(user_config)
      )
    end
  end

  # -- infohash ---------------------------------------------------------------

  defp resolve_infohash(
         definition,
         infohash,
         download_url,
         before_response,
         variables,
         user_config
       ) do
    with {:ok, response} <-
           infohash_source(definition, infohash, download_url, before_response, user_config),
         {:ok, hash} <- match_selector(response, Map.get(infohash, :hash), variables, "hash"),
         {:ok, title} <- match_title(response, Map.get(infohash, :title), variables) do
      case TorrentHash.build_magnet(hash, title) do
        nil ->
          {:error, {:cardigann_download, "infohash #{inspect(hash)} did not form a valid magnet"}}

        magnet ->
          {:ok, {:magnet, magnet}}
      end
    end
  end

  # `usebeforeresponse` reuses the body already fetched by the before-request
  # instead of spending a second round trip on the landing page.
  defp infohash_source(_definition, %{usebeforeresponse: true}, _url, before_response, _config)
       when is_map(before_response) do
    {:ok, before_response}
  end

  defp infohash_source(definition, _infohash, download_url, _before_response, user_config) do
    fetch(definition, download_url, user_config)
  end

  # A magnet without a display name is still valid, so a title that fails to
  # match costs us nothing but a cosmetic label. Losing the hash is fatal;
  # losing the name is not.
  defp match_title(_response, nil, _variables), do: {:ok, nil}

  defp match_title(response, selector, variables) do
    case match_selector(response, selector, variables, "title") do
      {:ok, title} -> {:ok, title}
      {:error, _reason} -> {:ok, nil}
    end
  end

  # -- selectors --------------------------------------------------------------

  defp resolve_selectors(definition, selectors, download_url, before_response, variables, config) do
    with {:ok, response} <- selector_source(definition, download_url, before_response, config) do
      selectors
      |> Enum.find_value(fn selector ->
        case match_selector(response, selector, variables, "download link") do
          {:ok, link} when is_binary(link) and link != "" -> link
          _ -> nil
        end
      end)
      |> case do
        nil ->
          {:error, {:cardigann_download, "no download selector matched the response"}}

        link ->
          # Many definitions point their download selector straight at a magnet.
          # Handing that back as a link would send the grab path off to fetch a
          # `magnet:` URL over HTTP, which it cannot do.
          case absolute_link(definition, download_url, link, config) do
            "magnet:" <> _ = magnet -> {:ok, {:magnet, magnet}}
            resolved -> {:ok, {:link, resolved}}
          end
      end
    end
  end

  defp selector_source(_definition, _url, before_response, _config) when is_map(before_response),
    do: {:ok, before_response}

  defp selector_source(definition, download_url, _before_response, user_config),
    do: fetch(definition, download_url, user_config)

  # -- selector matching ------------------------------------------------------

  defp match_selector(_response, nil, _variables, label) do
    {:error, {:cardigann_download, "no #{label} selector configured"}}
  end

  defp match_selector(response, selector, variables, label) do
    body = to_body(response)
    filters = Map.get(selector, :filters) || []

    with {:ok, selector_text} <- render(Map.get(selector, :selector), variables),
         {:ok, raw} <- extract(body, selector_text, Map.get(selector, :attribute), label),
         {:ok, value} <- CardigannResultParser.apply_filters(raw, filters, variables) do
      case String.trim(value) do
        "" -> {:error, {:cardigann_download, "#{label} selector matched an empty value"}}
        trimmed -> {:ok, trimmed}
      end
    end
  end

  defp extract(body, selector_text, _attribute, _label)
       when selector_text in @whole_document_selectors do
    {:ok, body}
  end

  defp extract(body, selector_text, attribute, label) do
    with {:ok, document} <- parse_document(body, label) do
      case Floki.find(document, selector_text) do
        [] ->
          {:error, {:cardigann_download, "#{label} selector #{selector_text} matched nothing"}}

        elements ->
          {:ok, element_value(elements, attribute)}
      end
    end
  end

  defp element_value(elements, nil), do: elements |> Floki.text() |> String.trim()

  defp element_value(elements, attribute) do
    case Floki.attribute(elements, attribute) do
      [value | _] -> String.trim(value)
      [] -> ""
    end
  end

  defp parse_document(body, label) do
    case Floki.parse_document(body) do
      {:ok, document} ->
        {:ok, document}

      {:error, reason} ->
        {:error, {:cardigann_download, "could not parse #{label} response: #{inspect(reason)}"}}
    end
  end

  # -- http -------------------------------------------------------------------

  defp fetch(definition, url, user_config) do
    params = %{query_params: %{}, headers: [], method: :get, decode_body: false}

    CardigannSearchEngine.execute_http_request(
      definition,
      url,
      params,
      user_config,
      scope_config(user_config)
    )
  end

  defp to_body(%{body: body}), do: to_body(body)
  defp to_body(body) when is_binary(body), do: body

  # Belt and braces: we ask Req not to decode, but a decoded body must still
  # yield text rather than silently matching nothing.
  defp to_body(body) when is_map(body) or is_list(body) do
    case Jason.encode(body) do
      {:ok, json} -> json
      {:error, _} -> ""
    end
  end

  defp to_body(_), do: ""

  defp http_method(method) when is_binary(method) do
    if String.downcase(method) == "post", do: :post, else: :get
  end

  defp http_method(_), do: :get

  # -- urls and templates -----------------------------------------------------

  # The credential scope needs the operator's settings to render an absolute
  # `{{ .Config.apiurl }}` path. resolve_cardigann_download/2 supplies them under
  # :config; a caller that omits them still gets links plus whatever a shipped
  # default renders, narrower than the operator's real scope, never wider.
  defp scope_config(user_config) when is_map(user_config) do
    case Map.get(user_config, :config) || Map.get(user_config, "config") do
      %{} = config -> config
      _ -> %{}
    end
  end

  defp scope_config(_user_config), do: %{}

  # Phase 1 gave definitions a probed `active_link`; honour it here so a
  # definition that failed over to a mirror resolves its download block against
  # the mirror rather than the dead primary it just abandoned.
  defp base_url(definition, user_config) do
    case Map.get(user_config, :base_url) || Map.get(user_config, "base_url") do
      url when is_binary(url) and url != "" -> {:ok, String.trim_trailing(url, "/")}
      _ -> base_url(definition)
    end
  end

  defp base_url(%Parsed{links: [link | _]}) when is_binary(link) do
    {:ok, String.trim_trailing(link, "/")}
  end

  defp base_url(%Parsed{id: id}),
    do: {:error, {:cardigann_download, "definition #{id} has no site link"}}

  defp absolutize_download_url(_definition, "http://" <> _ = url, _user_config), do: {:ok, url}
  defp absolutize_download_url(_definition, "https://" <> _ = url, _user_config), do: {:ok, url}
  defp absolutize_download_url(_definition, "magnet:" <> _ = url, _user_config), do: {:ok, url}

  defp absolutize_download_url(definition, download_url, user_config)
       when is_binary(download_url) do
    with {:ok, base} <- base_url(definition, user_config) do
      {:ok, join_url(base, download_url)}
    end
  end

  defp join_url(base, path), do: base |> URI.merge(path) |> URI.to_string()

  defp absolute_link(_definition, _download_url, "magnet:" <> _ = magnet, _user_config),
    do: magnet

  defp absolute_link(definition, download_url, link, user_config) do
    base =
      case base_url(definition, user_config) do
        {:ok, site} -> site
        {:error, _} -> download_url
      end

    base |> URI.merge(link) |> URI.to_string()
  end

  # Cardigann exposes the row's link to templates as `.DownloadUri`, which is
  # how a `before` block derives its inputs from the landing page URL.
  defp template_variables(download_url) do
    uri = URI.parse(download_url)

    %{
      "DownloadUri" => %{
        "AbsoluteUri" => download_url,
        "AbsolutePath" => uri.path || "/",
        "Scheme" => uri.scheme,
        "Host" => uri.host,
        "Query" => uri.query || "",
        "PathAndQuery" => path_and_query(uri)
      }
    }
  end

  defp path_and_query(%URI{path: path, query: nil}), do: path || "/"
  defp path_and_query(%URI{path: path, query: query}), do: "#{path || "/"}?#{query}"

  defp render(nil, _variables), do: {:ok, ""}

  defp render(template, variables) when is_binary(template) do
    # Values land in query params and selectors, both of which are escaped
    # downstream; encoding here would double-escape them.
    CardigannTemplate.render(template, variables, url_encode: false)
  end

  defp render(value, _variables), do: {:ok, to_string(value)}

  defp render_inputs(inputs, variables) when is_map(inputs) do
    Enum.reduce_while(inputs, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case render(value, variables) do
        {:ok, rendered} -> {:cont, {:ok, Map.put(acc, to_string(key), rendered)}}
        {:error, reason} -> {:halt, {:error, {:cardigann_download, reason}}}
      end
    end)
  end

  defp render_inputs(_inputs, _variables), do: {:ok, %{}}
end
