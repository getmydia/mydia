defmodule MetadataRelay.PlayerLogs.Query do
  @moduledoc """
  The filters `GET /logs/raw` accepts, and the line format it prints.

  Times are epoch milliseconds, the unit of every record's `t`. A device
  query with no `since` covers the last hour; a report query covers the whole
  report.
  """

  @levels %{"debug" => 0, "info" => 1, "warn" => 2, "error" => 3}
  @units %{"s" => 1_000, "m" => 60_000, "h" => 3_600_000, "d" => 86_400_000}
  @default_since_ms 3_600_000
  @default_max_lines 200_000

  defstruct [
    :device,
    :code,
    :since_ms,
    :until_ms,
    :session,
    :grep,
    min_level: 0,
    tags: [],
    max_lines: @default_max_lines
  ]

  @type t :: %__MODULE__{
          device: String.t() | nil,
          code: String.t() | nil,
          since_ms: integer() | nil,
          until_ms: integer() | nil,
          session: String.t() | nil,
          grep: String.t() | nil,
          min_level: non_neg_integer(),
          tags: [String.t()],
          max_lines: pos_integer()
        }

  @spec parse(map(), integer()) :: {:ok, t()} | {:error, String.t()}
  def parse(params, now_ms) do
    with {:ok, {device, code}} <- target(params),
         {:ok, since} <- time(params["since"], now_ms),
         {:ok, until} <- time(params["until"], now_ms),
         {:ok, min_level} <- level(params["level"]) do
      {:ok,
       %__MODULE__{
         device: device,
         code: code,
         since_ms: if(is_nil(since) and device, do: now_ms - @default_since_ms, else: since),
         until_ms: until,
         session: blank_to_nil(params["session"]),
         grep: params["grep"] |> blank_to_nil() |> downcase(),
         min_level: min_level,
         tags: tags(params["tag"]),
         max_lines: max_lines()
       }}
    end
  end

  @doc "A duration before `now_ms` (`30s`, `30m`, `2h`, `3d`) or an ISO 8601 time."
  @spec time(String.t() | nil, integer()) :: {:ok, integer() | nil} | {:error, String.t()}
  def time(nil, _now_ms), do: {:ok, nil}
  def time("", _now_ms), do: {:ok, nil}

  def time(value, now_ms) when is_binary(value) do
    case Regex.run(~r/\A(\d+)([smhd])\z/, value) do
      [_all, amount, unit] ->
        {:ok, now_ms - String.to_integer(amount) * Map.fetch!(@units, unit)}

      nil ->
        case DateTime.from_iso8601(value) do
          {:ok, datetime, _offset} ->
            {:ok, DateTime.to_unix(datetime, :millisecond)}

          {:error, _reason} ->
            {:error,
             "Could not read #{inspect(value)} as a duration (30m, 2h, 3d) or an ISO 8601 time"}
        end
    end
  end

  def time(value, _now_ms), do: {:error, "Could not read #{inspect(value)} as a time"}

  @spec matches?(map() | nil, t()) :: boolean()
  def matches?(%{"t" => t, "l" => level, "tag" => tag, "msg" => msg} = record, %__MODULE__{} = q)
      when is_integer(t) and is_binary(msg) do
    (is_nil(q.since_ms) or t >= q.since_ms) and
      (is_nil(q.until_ms) or t <= q.until_ms) and
      Map.get(@levels, level, 0) >= q.min_level and
      (q.tags == [] or tag in q.tags) and
      (is_nil(q.session) or record["sid"] == q.session) and
      (is_nil(q.grep) or String.contains?(String.downcase(msg), q.grep))
  end

  def matches?(_record, _query), do: false

  @spec format_line(map()) :: iodata()
  def format_line(%{"t" => t, "l" => level, "tag" => tag, "msg" => msg} = record) do
    time =
      case DateTime.from_unix(t, :millisecond) do
        {:ok, datetime} -> Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S.%f")
        {:error, _reason} -> Integer.to_string(t)
      end

    [
      time,
      " ",
      level |> String.upcase() |> String.pad_trailing(5),
      " [",
      tag,
      "] sid=",
      record["sid"] || "-",
      " ",
      msg,
      "\n"
    ]
  end

  defp target(%{"code" => code}) when is_binary(code) and code != "",
    do: {:ok, {nil, String.upcase(code)}}

  defp target(%{"device" => device}) when is_binary(device) and device != "",
    do: {:ok, {device, nil}}

  defp target(_params), do: {:error, "Pass device=<id or name> or code=<LOG-...>"}

  defp level(nil), do: {:ok, 0}
  defp level(""), do: {:ok, 0}

  defp level(value) when is_binary(value) do
    case Map.fetch(@levels, String.downcase(value)) do
      {:ok, rank} -> {:ok, rank}
      :error -> {:error, "level must be debug, info, warn or error"}
    end
  end

  defp level(_value), do: {:error, "level must be debug, info, warn or error"}

  defp tags(value) when is_binary(value) do
    value
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp tags(_value), do: []

  defp blank_to_nil(value) when is_binary(value) and value != "", do: value
  defp blank_to_nil(_value), do: nil

  defp downcase(nil), do: nil
  defp downcase(value), do: String.downcase(value)

  defp max_lines do
    Application.fetch_env!(:metadata_relay, :player_logs)
    |> Keyword.get(:raw_max_lines, @default_max_lines)
  end
end
