defmodule Mydia.Indexers.Cardigann.Parity.RequestKey do
  @moduledoc """
  The replay lookup key for a recorded HTTP exchange.

  Two engines build the same logical request with different parameter order
  and percent-encoding, so the key normalises both. Headers are deliberately
  excluded: they differ between engines (user agent, cookies) and must not
  change which recorded response is served.
  """

  @enforce_keys [:method, :url]
  defstruct [:method, :url, :body]

  @type t :: %__MODULE__{method: String.t(), url: String.t(), body: String.t() | nil}

  @spec new(String.t() | atom(), String.t(), binary() | nil) :: t()
  def new(method, url, body) do
    %__MODULE__{
      method: method |> to_string() |> String.upcase(),
      url: normalise_url(url),
      body: normalise_body(body)
    }
  end

  defp normalise_url(url) do
    uri = URI.parse(url)
    scheme = String.downcase(uri.scheme || "")
    host = String.downcase(uri.host || "")

    port =
      if uri.port in [nil, URI.default_port(scheme)], do: "", else: ":#{uri.port}"

    query =
      case uri.query do
        nil -> ""
        "" -> ""
        q -> "?" <> normalise_query(q)
      end

    "#{scheme}://#{host}#{port}#{uri.path || ""}#{query}"
  end

  # Malformed percent-encoding cannot be sorted; keep the query as sent so one
  # bad recording does not crash the replay lookup.
  defp normalise_query(q) do
    q |> decode_pairs() |> encode_sorted()
  rescue
    ArgumentError -> q
  end

  defp decode_pairs(query), do: query |> URI.query_decoder(:www_form) |> Enum.to_list()

  defp encode_sorted(pairs), do: pairs |> Enum.sort() |> URI.encode_query(:www_form)

  defp normalise_body(nil), do: nil

  defp normalise_body(body) when is_binary(body) do
    if form?(body), do: body |> decode_pairs() |> encode_sorted(), else: body
  rescue
    # Malformed percent-encoding: not a form, keep it as sent.
    ArgumentError -> body
  end

  # Only treat a body as a form when every segment is name=value; plain text
  # and JSON must survive byte for byte.
  defp form?(body) do
    trimmed = String.trim_leading(body)

    trimmed != "" and not String.starts_with?(trimmed, ["{", "["]) and String.valid?(body) and
      body |> String.split("&") |> Enum.all?(&String.contains?(&1, "="))
  end
end
