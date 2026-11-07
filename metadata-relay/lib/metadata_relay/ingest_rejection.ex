defmodule MetadataRelay.IngestRejection do
  @moduledoc """
  Records why an ingest request (`POST /crashes/report`, `POST /feedback`) was
  turned away: a counter, plus one log line saying who sent it.

  The request log alone reads `POST /crashes/report` then `Sent 400`, so a
  stream of rejections says nothing about its cause. In November 2026 one such
  stream turned out to be Meta's crawler posting 10 to 49 byte probe bodies,
  and finding that out took the ingress access log.

  ## The counter

  `metadata_relay_ingest_rejected_total{endpoint, reason}`. Both labels come
  from closed sets, because these endpoints are unauthenticated:

    * `endpoint`: `crash_reports`, `feedback`, or `other` for any other path
      whose JSON body failed to parse.
    * `reason`: `validation`, `message_too_long`, `not_json`, `too_large`,
      `rate_limited`, `store_failed`.

  ## The log line

  One `[Ingest] rejected` line per rejection, at warning (error for
  `store_failed`). A `rate_limited` rejection is counted but not logged: it
  only happens in a flood, and the request log already shows the 429.

  The line carries the body's size, content type, user agent, the
  `CF-Connecting-IP` header, the peer `MetadataRelay.ClientIp` resolved, and
  the body's `source` and `version` fields when they are strings. Never the
  body itself: a crash report can hold whatever the client failed to scrub.
  `CF-Connecting-IP` is logged as the caller sent it. A request reaching the
  origin without Cloudflare can set it to anything, so it identifies, and
  never authorizes.
  """

  require Logger

  alias MetadataRelay.Metrics

  @metric "metadata_relay_ingest_rejected_total"

  @endpoints %{"/crashes/report" => "crash_reports", "/feedback" => "feedback"}

  @reasons ~w(validation message_too_long not_json too_large rate_limited store_failed)a

  @doc """
  Counts and logs one rejection. `detail` is a short server-written
  explanation, such as the validation errors sent back to the caller.
  """
  @spec record(Plug.Conn.t(), atom(), pos_integer(), term()) :: :ok
  def record(conn, reason, status, detail \\ nil) when reason in @reasons do
    endpoint = endpoint(conn.request_path)
    Metrics.inc(@metric, endpoint: endpoint, reason: Atom.to_string(reason))
    log(conn, endpoint, reason, status, detail)
  end

  @doc """
  Counts and logs a body the endpoint's `Plug.Parsers` refused, given the
  exception the error renderer received. Any other exception is ignored.
  """
  @spec record_parser_error(Plug.Conn.t(), term()) :: :ok
  def record_parser_error(conn, %Plug.Parsers.ParseError{}), do: record(conn, :not_json, 400)

  def record_parser_error(conn, %Plug.Parsers.RequestTooLargeError{}),
    do: record(conn, :too_large, 413)

  def record_parser_error(_conn, _reason), do: :ok

  defp log(_conn, _endpoint, :rate_limited, _status, _detail), do: :ok

  defp log(conn, endpoint, reason, status, detail) do
    level = if reason == :store_failed, do: :error, else: :warning

    Logger.log(level, fn ->
      [
        "[Ingest] rejected",
        "endpoint=#{endpoint}",
        "status=#{status}",
        "reason=#{reason}",
        field("path", conn.request_path, 100),
        field("detail", detail, 300),
        field("bytes", header(conn, "content-length"), 20),
        field("content_type", header(conn, "content-type"), 100),
        field("user_agent", header(conn, "user-agent"), 200),
        field("cf_connecting_ip", header(conn, "cf-connecting-ip"), 64),
        # The rightmost X-Forwarded-For hop when the peer is a trusted proxy,
        # which can be text the caller wrote. Quoted like every other field.
        field("client_ip", MetadataRelay.ClientIp.resolve(conn), 64),
        field("source", body_field(conn, "source"), 40),
        field("version", body_field(conn, "version"), 40)
      ]
      |> Enum.reject(&is_nil/1)
      |> Enum.join(" ")
    end)
  end

  defp endpoint(path), do: Map.get(@endpoints, path, "other")

  # Absent values are left out rather than printed as `nil`. Present ones are
  # quoted and escaped by `inspect`, so a caller-chosen value cannot break the
  # line in two or forge another field.
  defp field(_name, nil, _limit), do: nil
  defp field(name, value, limit), do: "#{name}=#{text(value, limit)}"

  defp header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  # A parse failure leaves body_params as %Plug.Conn.Unfetched{}.
  defp body_field(%Plug.Conn{body_params: %{} = params}, key) when not is_struct(params) do
    case Map.get(params, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp body_field(_conn, _key), do: nil

  defp text(value, limit) when is_binary(value), do: inspect(String.slice(value, 0, limit))
  defp text(value, limit), do: value |> inspect(limit: 20, printable_limit: limit)
end
