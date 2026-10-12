defmodule Mydia.Indexers.Cardigann.LinkResolver do
  @moduledoc false
  # Turns the link a result row carries into an absolute URL.

  alias Mydia.Indexers.CardigannSearchEngine
  alias Mydia.Indexers.CardigannTemplate

  @scheme ~r/^[a-zA-Z][a-zA-Z0-9+.-]*:/

  @doc """
  The base that relative links resolve against.

  Cardigann resolves a relative link (`download.php?id=1`) against the URL of the
  search page, not the site root: nnmclub searches `forum/tracker.php` and links
  to `forum/download.php`. When the caller passes the search path, the base is
  that page's URL (`{:page, url}`). Without it links keep joining onto the base
  URL.
  """
  @spec base(String.t(), keyword(), map()) :: String.t() | {:page, String.t()}
  def base(base_url, opts, template_context) when is_binary(base_url) and base_url != "" do
    with %{path: path} when is_binary(path) <- Keyword.get(opts, :search_path),
         {:ok, rendered} <- CardigannTemplate.render(path, template_context) do
      {:page, CardigannSearchEngine.build_full_url(String.trim_trailing(base_url, "/"), rendered)}
    else
      _ -> base_url
    end
  end

  def base(base_url, _opts, _template_context), do: base_url

  @doc "Resolves `url` against `base` (a URL string or `{:page, url}`)."
  @spec resolve(String.t() | nil, String.t() | {:page, String.t()}) :: String.t() | nil
  def resolve(nil, _base), do: nil
  def resolve("", _base), do: nil

  def resolve(url, {:page, page_url}) do
    if absolute?(url) or String.starts_with?(url, "//") do
      resolve(url, page_url)
    else
      page_url |> URI.merge(url) |> to_string()
    end
  rescue
    _ -> resolve(url, page_url)
  end

  def resolve(url, base_url) do
    cond do
      absolute?(url) -> url
      String.starts_with?(url, "//") -> "https:" <> url
      String.starts_with?(url, "/") -> with_host(url, base_url)
      true -> join(base_url, url)
    end
  end

  # Already absolute (http, https, magnet, ...).
  defp absolute?(url), do: String.match?(url, @scheme)

  # Absolute path (/path/to/file) onto the base's origin.
  defp with_host(url, base_url) do
    case URI.parse(base_url) do
      %URI{scheme: scheme, host: host, port: port} when not is_nil(host) ->
        port_str = if port && port not in [80, 443], do: ":#{port}", else: ""
        "#{scheme || "https"}://#{host}#{port_str}#{url}"

      _ ->
        url
    end
  end

  defp join("", url), do: url
  defp join(base, url), do: "#{String.trim_trailing(base, "/")}/#{url}"
end
