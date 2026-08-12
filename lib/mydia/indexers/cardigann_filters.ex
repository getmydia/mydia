defmodule Mydia.Indexers.CardigannFilters do
  @moduledoc """
  Cardigann filter engine implementing all supported Prowlarr/Jackett filters.

  Filters transform extracted field values during Cardigann result parsing.
  They are applied in sequence, with each filter's output becoming the next
  filter's input.

  ## Implemented Filters

  ### String Manipulation
  - `replace` - String replacement: `{name: "replace", args: ["old", "new"]}`
  - `re_replace` - Regex replacement: `{name: "re_replace", args: ["pattern", "replacement"]}`
  - `regexp` - Regex extraction (first capture group): `{name: "regexp", args: ["pattern"]}`
  - `append` - Append string: `{name: "append", args: ["suffix"]}`
  - `prepend` - Prepend string: `{name: "prepend", args: ["prefix"]}`
  - `trim` - Trim whitespace: `{name: "trim"}`
  - `split` - Split and return part: `{name: "split", args: ["delimiter", "index"]}`
  - `tolower` - Lowercase: `{name: "tolower"}`
  - `toupper` - Uppercase: `{name: "toupper"}`

  ### Encoding
  - `urlencode` - URL-encode: `{name: "urlencode"}`
  - `urldecode` - URL-decode: `{name: "urldecode"}`
  - `htmldecode` - Decode HTML entities: `{name: "htmldecode"}`

  ### Date/Time
  - `dateparse`/`timeparse` - Parse with Go format layout: `{name: "dateparse", args: ["2006-01-02"]}`
  - `timeago`/`reltime` - Parse relative time: `{name: "timeago"}`
  - `fuzzytime` - Parse various date formats: `{name: "fuzzytime"}`

  ### URL
  - `querystring` - Extract URL query parameter: `{name: "querystring", args: ["param"]}`

  ### Sanitization
  - `validfilename` - Strip invalid filename characters: `{name: "validfilename"}`
  - `diacritics` - Remove accents/diacritics: `{name: "diacritics"}`

  ### JSON
  - `jsonjoinarray` - Parse JSON, navigate path, join array: `{name: "jsonjoinarray", args: ["path", "separator"]}`

  ### Row Filtering
  - `andmatch` - Row-level filter (matches search words in title). Special: not a value filter.

  ### Debug
  - `strdump`/`hexdump` - Log value for debugging (pass through): `{name: "strdump"}`
  """

  require Logger

  @implemented_filters ~w(
    replace re_replace append prepend trim split urldecode
    regexp dateparse timeparse timeago reltime fuzzytime
    tolower toupper urlencode htmldecode querystring
    validfilename diacritics jsonjoinarray strdump hexdump
    andmatch
  )

  @doc """
  Returns the list of all implemented filter names.
  """
  @spec implemented_filters() :: [String.t()]
  def implemented_filters, do: @implemented_filters

  @doc """
  Returns true if the named filter is implemented.
  """
  @spec implemented?(String.t()) :: boolean()
  def implemented?(name), do: name in @implemented_filters

  @doc """
  Applies a single filter to a value.

  The filter map can use either atom or string keys - they are normalized
  internally. Returns `{:ok, new_value}` on success.

  ## Examples

      iex> apply(%{name: "trim"}, "  hello  ")
      {:ok, "hello"}

      iex> apply(%{"name" => "replace", "args" => ["foo", "bar"]}, "foobar")
      {:ok, "barbar"}
  """
  @spec apply(map(), String.t()) :: {:ok, String.t()}
  def apply(filter, value) when is_map(filter) and is_binary(value) do
    {name, args} = normalize_filter(filter)
    apply_filter(name, args, value)
  end

  def apply(_filter, value), do: {:ok, value}

  # Normalize filter map to consistent {name, args} tuple
  defp normalize_filter(filter) do
    name = to_string(Map.get(filter, :name) || Map.get(filter, "name", "unknown"))

    args =
      case Map.get(filter, :args) || Map.get(filter, "args") do
        nil -> []
        args when is_list(args) -> args
        arg when is_binary(arg) -> [arg]
        other -> [other]
      end

    {name, args}
  end

  # String manipulation filters

  defp apply_filter("replace", [pattern, replacement], value) do
    {:ok, String.replace(value, pattern, replacement)}
  end

  defp apply_filter("re_replace", [pattern, replacement], value) do
    apply_re_replace(value, pattern, replacement)
  end

  defp apply_filter("regexp", [pattern], value) do
    apply_regexp(value, pattern)
  end

  defp apply_filter("append", [suffix], value) do
    {:ok, value <> suffix}
  end

  defp apply_filter("prepend", [prefix], value) do
    {:ok, prefix <> value}
  end

  defp apply_filter("trim", _args, value) do
    {:ok, String.trim(value)}
  end

  defp apply_filter("split", [delimiter, index], value) do
    parts = String.split(value, delimiter)
    idx = if is_binary(index), do: String.to_integer(index), else: index

    case Enum.at(parts, idx) do
      nil -> {:ok, ""}
      part -> {:ok, part}
    end
  end

  defp apply_filter("tolower", _args, value) do
    {:ok, String.downcase(value)}
  end

  defp apply_filter("toupper", _args, value) do
    {:ok, String.upcase(value)}
  end

  # Encoding filters

  defp apply_filter("urlencode", _args, value) do
    {:ok, URI.encode_www_form(value)}
  end

  defp apply_filter("urldecode", _args, value) do
    {:ok, URI.decode(value)}
  end

  defp apply_filter("htmldecode", _args, value) do
    apply_htmldecode(value)
  end

  # Date/time filters

  defp apply_filter(name, [layout], value) when name in ["dateparse", "timeparse"] do
    apply_dateparse(value, layout)
  end

  defp apply_filter(name, _args, value) when name in ["timeago", "reltime"] do
    apply_timeago(value)
  end

  defp apply_filter("fuzzytime", _args, value) do
    apply_fuzzytime(value)
  end

  # URL filters

  defp apply_filter("querystring", [param], value) do
    apply_querystring(value, param)
  end

  # Sanitization filters

  defp apply_filter("validfilename", _args, value) do
    # Strip characters invalid in filenames
    cleaned =
      value
      |> String.replace(~r/[<>:\"\/\\|?*\x00-\x1f]/, "")
      |> String.trim()

    {:ok, cleaned}
  end

  defp apply_filter("diacritics", _args, value) do
    # Remove diacritical marks via Unicode NFD normalization
    # Decompose -> strip combining marks (Unicode category "Mn") -> recompose
    normalized =
      value
      |> String.normalize(:nfd)
      |> String.replace(~r/\p{Mn}/u, "")

    {:ok, normalized}
  end

  # JSON filter

  defp apply_filter("jsonjoinarray", args, value) do
    {path, separator} =
      case args do
        [path, sep] -> {path, sep}
        [path] -> {path, ", "}
        _ -> {"$", ", "}
      end

    case Jason.decode(value) do
      {:ok, json} ->
        result = navigate_json_and_join(json, path, separator)
        {:ok, result}

      {:error, _} ->
        {:ok, value}
    end
  end

  # andmatch - pass-through at filter level, actual matching done at row level
  defp apply_filter("andmatch", _args, value) do
    {:ok, value}
  end

  # Debug filters - log and pass through

  defp apply_filter("strdump", _args, value) do
    Logger.debug("[CardigannFilters] strdump: #{inspect(value)}")
    {:ok, value}
  end

  defp apply_filter("hexdump", _args, value) do
    hex = Base.encode16(value, case: :lower)
    Logger.debug("[CardigannFilters] hexdump: #{hex}")
    {:ok, value}
  end

  # Catch-all for unknown filters

  defp apply_filter(name, _args, value) do
    Logger.warning("Skipping unimplemented Cardigann filter: #{name}")
    {:ok, value}
  end

  # ---- Filter implementation helpers ----

  # regexp - extract first capture group
  defp apply_regexp(value, pattern) do
    pcre_pattern = convert_go_regex_to_pcre(pattern)

    case Regex.compile(pcre_pattern, [:unicode]) do
      {:ok, regex} ->
        case Regex.run(regex, value, capture: :all) do
          [_full | [first_group | _]] -> {:ok, first_group}
          [_full] -> {:ok, ""}
          nil -> {:ok, ""}
        end

      {:error, reason} ->
        Logger.warning(
          "Skipping invalid regexp filter: #{inspect(reason)} for pattern: #{inspect(pattern)}"
        )

        {:ok, value}
    end
  end

  # re_replace - regex replacement with Go-to-PCRE conversion
  defp apply_re_replace(value, pattern, replacement) do
    pcre_pattern = convert_go_regex_to_pcre(pattern)
    elixir_replacement = convert_go_backrefs_to_elixir(replacement)

    case Regex.compile(pcre_pattern, [:unicode]) do
      {:ok, regex} ->
        {:ok, Regex.replace(regex, value, elixir_replacement)}

      {:error, reason} ->
        Logger.warning(
          "Skipping invalid regex filter: #{inspect(reason)} for pattern: #{inspect(pattern)}"
        )

        {:ok, value}
    end
  end

  # dateparse - parse date with Go format layout
  defp apply_dateparse(value, layout) do
    normalized = value |> String.trim() |> String.replace(~r/\s+/, " ")

    result =
      case parse_with_go_layout(normalized, layout) do
        {:ok, _} = ok ->
          ok

        {:error, _} ->
          case DateTime.from_iso8601(normalized) do
            {:ok, dt, _offset} -> {:ok, dt}
            _ -> :error
          end
      end

    case result do
      {:ok, datetime} ->
        {:ok, DateTime.to_iso8601(datetime)}

      _ ->
        Logger.warning(
          "dateparse filter failed for value: #{inspect(value)} with layout: #{inspect(layout)}"
        )

        {:ok, value}
    end
  end

  @doc false
  def parse_with_go_layout(value, go_layout) do
    strftime_format = go_layout_to_strftime(go_layout)

    case Timex.parse(value, strftime_format, :strftime) do
      {:ok, %NaiveDateTime{} = ndt} ->
        {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}

      {:ok, %DateTime{} = dt} ->
        {:ok, dt}

      {:error, _} = error ->
        error
    end
  end

  # Go time format layout → strftime conversion using regex tokenizer.
  # Go reference time: Mon Jan 2 15:04:05 MST 2006
  #
  # The tokenizer matches all Go reference tokens greedily (longest first),
  # then maps each token to its strftime equivalent. This avoids the ordering
  # conflicts that sequential String.replace calls cause with ambiguous values
  # like bare "1" (month), "2" (day), "3" (12h hour).
  @go_token_map %{
    # Timezone patterns
    "Z07:00" => "%:z",
    "Z0700" => "%z",
    "-07:00" => "%:z",
    "-0700" => "%z",
    "-07" => "%z",
    "MST" => "%Z",
    # Year
    "2006" => "%Y",
    "06" => "%y",
    # Month name
    "January" => "%B",
    "Jan" => "%b",
    # Month numeric
    "01" => "%m",
    "1" => "%-m",
    # Day of week
    "Monday" => "%A",
    "Mon" => "%a",
    # Day numeric
    "02" => "%d",
    "_2" => "%e",
    "2" => "%-d",
    # Hour
    "15" => "%H",
    "03" => "%I",
    "3" => "%-I",
    # AM/PM
    "PM" => "%p",
    "pm" => "%P",
    # Minute
    "04" => "%M",
    "4" => "%-M",
    # Second
    "05" => "%S",
    "5" => "%-S",
    # Fractional seconds
    ".000000000" => "%N",
    ".000000" => "%f",
    ".000" => "%L",
    ".0" => "%1N"
  }

  # Build regex that matches all Go tokens, longest first to ensure greedy matching
  @go_token_regex (
                    tokens =
                      @go_token_map
                      |> Map.keys()
                      |> Enum.sort_by(&byte_size/1, :desc)
                      |> Enum.map_join("|", &Regex.escape/1)

                    {:ok, regex} = Regex.compile(tokens)
                    regex
                  )

  defp go_layout_to_strftime(layout) do
    Regex.replace(@go_token_regex, layout, fn match ->
      Map.get(@go_token_map, match, match)
    end)
  end

  # timeago - parse relative time strings
  defp apply_timeago(value) do
    now = DateTime.utc_now()
    input = value |> String.downcase() |> String.trim()

    if String.contains?(input, "now") do
      {:ok, DateTime.to_iso8601(now)}
    else
      cleaned =
        input
        |> String.replace(",", "")
        |> String.replace("ago", "")
        |> String.replace("and", "")
        |> String.trim()

      matches = Regex.scan(~r/([\d.]+)\s*([a-z]+)/, cleaned)

      if matches == [] do
        {:ok, DateTime.to_iso8601(now)}
      else
        total_seconds =
          Enum.reduce(matches, 0.0, fn [_full, num_str, unit], acc ->
            {num, _} = Float.parse(num_str)
            acc + timeago_unit_seconds(unit, num)
          end)

        result = DateTime.add(now, -round(total_seconds), :second)
        {:ok, DateTime.to_iso8601(result)}
      end
    end
  end

  defp timeago_unit_seconds(unit, num) do
    cond do
      String.starts_with?(unit, "sec") or unit == "s" ->
        num

      String.starts_with?(unit, "min") or unit == "m" ->
        num * 60

      String.starts_with?(unit, "hour") or String.starts_with?(unit, "hr") or unit == "h" ->
        num * 3600

      String.starts_with?(unit, "day") or unit == "d" ->
        num * 86_400

      String.starts_with?(unit, "week") or String.starts_with?(unit, "wk") or unit == "w" ->
        num * 604_800

      String.starts_with?(unit, "month") or unit == "mo" ->
        num * 2_592_000

      String.starts_with?(unit, "year") or unit == "y" ->
        num * 31_536_000

      true ->
        Logger.warning("timeago: unknown unit #{inspect(unit)}")
        0.0
    end
  end

  # fuzzytime - parse various date formats
  defp apply_fuzzytime(value) do
    now = DateTime.utc_now()
    input = value |> String.trim() |> String.replace(~r/\s+/, " ")

    result =
      cond do
        Regex.match?(~r/^\d+$/, input) ->
          parse_unix_timestamp(input)

        String.contains?(String.downcase(input), "now") ->
          {:ok, now}

        Regex.match?(~r/(?i)\bago\b/, input) ->
          case apply_timeago(input) do
            {:ok, iso} ->
              case DateTime.from_iso8601(iso) do
                {:ok, dt, _offset} -> {:ok, dt}
                _ -> :error
              end

            _ ->
              :error
          end

        Regex.match?(~r/(?i)^today/i, input) ->
          parse_relative_day(input, ~r/(?i)^today[\s,]*(at\s+)?/i, 0, now)

        Regex.match?(~r/(?i)^yesterday/i, input) ->
          parse_relative_day(input, ~r/(?i)^yesterday[\s,]*(at\s+)?/i, -1, now)

        Regex.match?(~r/(?i)^tomorrow/i, input) ->
          parse_relative_day(input, ~r/(?i)^tomorrow[\s,]*(at\s+)?/i, 1, now)

        true ->
          try_common_date_formats(input)
      end

    case result do
      {:ok, %DateTime{} = dt} ->
        {:ok, DateTime.to_iso8601(dt)}

      {:ok, iso} when is_binary(iso) ->
        {:ok, iso}

      _ ->
        Logger.warning("fuzzytime: failed to parse #{inspect(value)}")
        {:ok, value}
    end
  end

  defp parse_unix_timestamp(str) do
    case Integer.parse(str) do
      {ts, ""} ->
        dt =
          if ts > 10_000_000_000 do
            DateTime.from_unix!(div(ts, 1000))
          else
            DateTime.from_unix!(ts)
          end

        {:ok, dt}

      _ ->
        :error
    end
  end

  defp parse_relative_day(input, prefix_regex, day_offset, now) do
    time_str = Regex.replace(prefix_regex, input, "") |> String.trim()
    today = DateTime.to_date(now)
    target_date = Date.add(today, day_offset)

    time =
      if time_str == "" do
        ~T[00:00:00]
      else
        case Time.from_iso8601(time_str) do
          {:ok, t} ->
            t

          _ ->
            case Regex.run(~r/^(\d{1,2}):(\d{2})(?::(\d{2}))?$/, time_str) do
              [_, h, m] ->
                Time.new!(String.to_integer(h), String.to_integer(m), 0)

              [_, h, m, s] ->
                Time.new!(String.to_integer(h), String.to_integer(m), String.to_integer(s))

              _ ->
                ~T[00:00:00]
            end
        end
      end

    {:ok, ndt} = NaiveDateTime.new(target_date, time)
    {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
  end

  defp try_common_date_formats(input) do
    formats = [
      "{RFC1123z}",
      "{RFC1123}",
      "{RFC3339}",
      "{ISO:Extended}",
      "{ISO:Extended:Z}",
      "{YYYY}-{0M}-{0D} {h24}:{0m}:{0s}",
      "{YYYY}-{0M}-{0D}T{h24}:{0m}:{0s}",
      "{0D}/{0M}/{YYYY} {h24}:{0m}:{0s}",
      "{0M}/{0D}/{YYYY} {h24}:{0m}:{0s}",
      "{0D} {Mshort} {YYYY} {h24}:{0m}:{0s}",
      "{0D}-{Mshort}-{YYYY} {h24}:{0m}:{0s}",
      "{YYYY}-{0M}-{0D}"
    ]

    Enum.find_value(formats, :error, fn format ->
      case Timex.parse(input, format) do
        {:ok, %NaiveDateTime{} = ndt} -> {:ok, DateTime.from_naive!(ndt, "Etc/UTC")}
        {:ok, %DateTime{} = dt} -> {:ok, dt}
        _ -> nil
      end
    end)
  end

  # htmldecode helper
  defp apply_htmldecode(value) do
    decoded =
      value
      |> String.replace("&amp;", "&")
      |> String.replace("&lt;", "<")
      |> String.replace("&gt;", ">")
      |> String.replace("&quot;", "\"")
      |> String.replace("&apos;", "'")
      |> String.replace("&#39;", "'")
      |> String.replace("&nbsp;", " ")
      |> decode_numeric_entities()
      |> decode_hex_entities()

    {:ok, decoded}
  end

  defp decode_numeric_entities(value) do
    Regex.replace(~r/&#(\d+);/, value, fn _full, num_str ->
      case Integer.parse(num_str) do
        {codepoint, ""} when codepoint >= 0 and codepoint <= 0x10FFFF ->
          <<codepoint::utf8>>

        _ ->
          "&##{num_str};"
      end
    end)
  end

  defp decode_hex_entities(value) do
    Regex.replace(~r/&#x([0-9a-fA-F]+);/, value, fn _full, hex_str ->
      case Integer.parse(hex_str, 16) do
        {codepoint, ""} when codepoint >= 0 and codepoint <= 0x10FFFF ->
          <<codepoint::utf8>>

        _ ->
          "&#x#{hex_str};"
      end
    end)
  end

  # querystring helper
  defp apply_querystring(value, param) do
    case URI.parse(value) do
      %URI{query: query} when is_binary(query) ->
        params = URI.decode_query(query)
        {:ok, Map.get(params, param, "")}

      _ ->
        if String.contains?(value, "=") do
          params = URI.decode_query(value)
          {:ok, Map.get(params, param, "")}
        else
          {:ok, ""}
        end
    end
  end

  # Go regex conversion helpers

  defp convert_go_regex_to_pcre(pattern) when is_binary(pattern) do
    pattern
    # \p{IsX} → \p{X} (Go Unicode property names)
    |> then(&Regex.replace(~r/\\p\{Is(\w+)\}/, &1, "\\p{\\1}"))
    # (?P<name> → (?<name> (Go named capture groups)
    |> String.replace("(?P<", "(?<")
  end

  defp convert_go_regex_to_pcre(pattern), do: pattern

  defp convert_go_backrefs_to_elixir(replacement) when is_binary(replacement) do
    replacement
    # ${N} → \N (braced backreferences)
    |> then(&Regex.replace(~r/\$\{(\d+)\}/, &1, "\\\\\\1"))
    # $N → \N (standard backreferences)
    |> then(&Regex.replace(~r/\$(\d)/, &1, "\\\\\\1"))
  end

  defp convert_go_backrefs_to_elixir(replacement), do: replacement

  # JSON navigation helper for jsonjoinarray
  defp navigate_json_and_join(json, path, separator) do
    parts = path |> String.trim_leading("$.") |> String.split(".")

    result =
      Enum.reduce_while(parts, json, fn part, acc ->
        cond do
          part == "" or part == "$" ->
            {:cont, acc}

          is_map(acc) ->
            case Map.get(acc, part) do
              nil -> {:halt, nil}
              value -> {:cont, value}
            end

          true ->
            {:halt, nil}
        end
      end)

    case result do
      list when is_list(list) ->
        Enum.map_join(list, separator, &to_string/1)

      nil ->
        ""

      other ->
        to_string(other)
    end
  end

  @doc """
  Applies `search.keywordsfilters` to a query before any `{{ .Keywords }}` substitution.

  Trackers use this to strip years, punctuation, or article prefixes their search
  engine cannot handle.
  """
  @spec apply_keywords_filters(String.t(), map()) :: String.t()
  def apply_keywords_filters(query, %{search: %{keywordsfilters: filters}})
      when is_list(filters) and filters != [] and is_binary(query) do
    Enum.reduce(filters, query, fn filter, acc ->
      case __MODULE__.apply(normalize_keywords_filter(filter), acc) do
        {:ok, filtered} -> filtered
        _ -> acc
      end
    end)
  end

  def apply_keywords_filters(query, _definition) when is_binary(query), do: query
  def apply_keywords_filters(query, _definition), do: query || ""

  defp normalize_keywords_filter(filter) when is_map(filter), do: filter
  defp normalize_keywords_filter(filter), do: %{name: to_string(filter)}
end
