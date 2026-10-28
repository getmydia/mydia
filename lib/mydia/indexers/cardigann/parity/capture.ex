defmodule Mydia.Indexers.Cardigann.Parity.Capture do
  @moduledoc """
  On-disk format for recorded HTTP exchanges used by the Cardigann parity oracle.

  A capture directory holds `exchanges.json` plus one raw body file per
  response (`001.html`, `002.json`, ...). Bodies are written as raw bytes and
  never transcoded, so charset handling is exercised on replay. Redaction is
  the recorder's job (see `redact_headers/1`); `write!/2` stores what it is given.
  """

  alias Mydia.Indexers.Cardigann.Parity.RequestKey

  @format_version 1
  @redacted_headers ["cookie", "set-cookie", "authorization"]
  @query_kinds %{"generic" => :generic, "movie" => :movie, "tv" => :tv, "rss" => :rss}
  @errors %{
    "timeout" => :timeout,
    "closed" => :closed,
    "econnrefused" => :econnrefused,
    "nxdomain" => :nxdomain
  }

  defmodule Exchange do
    @moduledoc "One recorded request and its response (or transport error)."
    @enforce_keys [:request]
    defstruct [:request, :status, :body, :error, headers: []]

    @type t :: %__MODULE__{
            request: RequestKey.t(),
            status: non_neg_integer() | nil,
            headers: [{String.t(), String.t()}],
            body: binary() | nil,
            error: atom() | nil
          }
  end

  @enforce_keys [:definition, :ref, :query]
  defstruct [:definition, :ref, :query, format_version: 1, exchanges: []]

  @type t :: %__MODULE__{
          format_version: 1,
          definition: String.t(),
          ref: String.t(),
          query: %{kind: :generic | :movie | :tv | :rss, term: String.t()},
          exchanges: [Exchange.t()]
        }

  @doc "Blanks the values of credential-bearing headers."
  @spec redact_headers([{String.t(), String.t()}]) :: [{String.t(), String.t()}]
  def redact_headers(headers) do
    Enum.map(headers, fn {name, value} ->
      if String.downcase(name) in @redacted_headers, do: {name, "<redacted>"}, else: {name, value}
    end)
  end

  @spec write!(t(), Path.t()) :: :ok
  def write!(%__MODULE__{} = capture, dir) do
    File.mkdir_p!(dir)

    exchanges =
      capture.exchanges
      |> Enum.with_index(1)
      |> Enum.map(fn {exchange, n} -> encode_exchange(exchange, n, dir) end)

    json = %{
      "format_version" => capture.format_version,
      "definition" => capture.definition,
      "ref" => capture.ref,
      "query" => %{"kind" => Atom.to_string(capture.query.kind), "term" => capture.query.term},
      "exchanges" => exchanges
    }

    File.write!(Path.join(dir, "exchanges.json"), Jason.encode!(json, pretty: true))
  end

  @spec read!(Path.t()) :: t()
  def read!(dir) do
    json = dir |> Path.join("exchanges.json") |> File.read!() |> Jason.decode!()

    case json do
      %{"format_version" => @format_version} ->
        decode(json, dir)

      other ->
        raise ArgumentError,
              "unsupported capture format_version #{inspect(Map.get(other, "format_version"))} in #{dir}"
    end
  end

  defp encode_exchange(%Exchange{} = ex, n, dir) do
    %{"request" => encode_request(ex.request), "response" => encode_response(ex, n, dir)}
  end

  defp encode_request(%RequestKey{} = key) do
    body =
      cond do
        is_nil(key.body) -> %{"body" => nil}
        String.valid?(key.body) -> %{"body" => key.body}
        true -> %{"body_base64" => Base.encode64(key.body)}
      end

    Map.merge(%{"method" => key.method, "url" => key.url}, body)
  end

  defp encode_response(%Exchange{error: error}, _n, _dir) when not is_nil(error),
    do: %{"error" => Atom.to_string(error)}

  defp encode_response(%Exchange{} = ex, n, dir) do
    file = body_file_name(n, ex.headers)
    File.write!(Path.join(dir, file), ex.body || "")

    %{
      "status" => ex.status,
      "headers" => Enum.map(ex.headers, fn {k, v} -> [k, v] end),
      "body_file" => file
    }
  end

  defp body_file_name(n, headers) do
    num = n |> Integer.to_string() |> String.pad_leading(3, "0")
    "#{num}.#{extension(headers)}"
  end

  defp extension(headers) do
    type =
      Enum.find_value(headers, "", fn {k, v} ->
        if String.downcase(k) == "content-type", do: String.downcase(v)
      end)

    cond do
      type =~ "html" -> "html"
      type =~ "json" -> "json"
      type =~ "xml" -> "xml"
      true -> "bin"
    end
  end

  defp decode(json, dir) do
    %{"definition" => definition, "ref" => ref, "query" => query, "exchanges" => exchanges} = json

    %__MODULE__{
      definition: definition,
      ref: ref,
      query: %{kind: Map.fetch!(@query_kinds, query["kind"]), term: query["term"]},
      exchanges: Enum.map(exchanges, &decode_exchange(&1, dir))
    }
  end

  defp decode_exchange(%{"request" => req, "response" => resp}, dir) do
    key = RequestKey.new(req["method"], req["url"], decode_body(req))
    exchange = %Exchange{request: key}

    case resp do
      %{"error" => error} ->
        %{exchange | error: Map.get(@errors, error, :unknown)}

      %{"status" => status, "headers" => headers, "body_file" => file} ->
        %{
          exchange
          | status: status,
            headers: Enum.map(headers, fn [k, v] -> {k, v} end),
            body: File.read!(Path.join(dir, file))
        }
    end
  end

  defp decode_body(%{"body_base64" => b64}), do: Base.decode64!(b64)
  defp decode_body(req), do: req["body"]
end
