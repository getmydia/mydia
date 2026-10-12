defmodule Mydia.Indexers.Cardigann.BlockPage do
  @moduledoc """
  Recognises pages a dead or seized mirror serves with HTTP 200: ISP block
  notices, parked domains and domains for sale.

  They used to read as "search worked, zero results", so mirror failover never
  moved past them and the health check showed green. Four public definitions
  served the same ISP notice and one a for-sale page on 2026-10-11.

  A title match alone is not enough: a tracker could title a listing "Blocked".
  `blocked?/2` also requires the definition's row selector to match nothing, and
  only looks at 200 responses so Cloudflare 403/503 challenges still reach
  FlareSolverr.
  """

  alias Mydia.Indexers.Adapter.Error
  alias Mydia.Indexers.Cardigann.Selector
  alias Mydia.Indexers.CardigannDefinition.Parsed

  @markers [
    ~r/website is blocked/i,
    ~r/site (has been|is) blocked/i,
    ~r/(domain|website|site) (is )?for sale/i,
    ~r/domain (is )?parked/i,
    ~r/buy this domain/i
  ]

  @doc "The page title when `body` is an HTML page with a block, parked or for-sale title."
  @spec fingerprint(term()) :: String.t() | nil
  def fingerprint(body) when is_binary(body) do
    with [_, title] <- Regex.run(~r/<title[^>]*>(.*?)<\/title>/is, body),
         title = String.trim(title),
         true <- Enum.any?(@markers, &Regex.match?(&1, title)) do
      title
    else
      _ -> nil
    end
  end

  def fingerprint(_body), do: nil

  @doc "True when a 200 response is fingerprinted and the row selector matches nothing."
  @spec blocked?(Parsed.t(), map()) :: boolean()
  def blocked?(%Parsed{} = definition, %{status: 200, body: body}) when is_binary(body) do
    case fingerprint(body) do
      nil -> false
      _title -> no_rows?(definition, body)
    end
  end

  def blocked?(_definition, _response), do: false

  @doc """
  Turns a blocked search response into an error, so mirror failover moves on
  instead of reporting "search worked, no results". Anything else passes through.
  """
  @spec reject(Parsed.t(), term()) :: term()
  def reject(definition, {:ok, response} = ok), do: reject(definition, ok, response)
  def reject(definition, {:ok, response, _markers} = ok), do: reject(definition, ok, response)
  def reject(_definition, other), do: other

  defp reject(definition, ok, response) do
    if blocked?(definition, response) do
      {:error, Error.search_failed("Blocked page: #{fingerprint(response.body)}")}
    else
      ok
    end
  end

  defp no_rows?(definition, body) do
    case get_in(definition.search || %{}, [:rows, :selector]) do
      selector when is_binary(selector) and selector != "" ->
        doc = Selector.parse(body, [selector])
        Selector.find(doc, :root, selector) == []

      _ ->
        true
    end
  rescue
    # An unrendered selector (for example one holding "{{") may not parse. On a
    # fingerprinted page that is as good as no rows.
    e in ArgumentError ->
      if Selector.selector_error?(e), do: true, else: reraise(e, __STACKTRACE__)
  end
end
