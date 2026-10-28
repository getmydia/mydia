defmodule Mydia.Indexers.Cardigann.Parity.Scrubber do
  @moduledoc """
  Turns a cached live capture into a fixture that is safe to commit.

  Real release titles may not appear in the repository, so `seed/3` trims each
  page to the rows the definition reads (`trim/2`), renames every title's work
  name to an invented one in each form it can be encoded in (`rename/3`), and
  replays the result through the wasm engine to prove two things before writing
  anything (`verify/5`): parsing is unchanged apart from the renamed text, and
  none of the real work names survived.

  The wasm engine is the reference here because it recorded the capture; the
  native engine has no bearing on whether scrubbing preserved parsing.

  Works come from the titles the wasm engine parsed. Text no field selector
  reaches (a sidebar on a page with no rows, a login page) is never learned, so
  trimming is what keeps it out; a page that is kept untrimmed is reported by
  `seed/3` so the person seeding can look at it.
  """

  alias Mydia.Indexers.Cardigann.Parity.{Capture, RequestKey, Runner}
  alias Mydia.Indexers.Cardigann.Parity.Capture.Exchange
  alias Mydia.Indexers.Cardigann.Parity.Scrubber.{Names, Trim}
  alias Mydia.Indexers.CardigannDefinition.Parsed
  alias Mydia.Indexers.CardigannParser

  @size_cap 512 * 1024
  @min_work_length 3
  # Compared fields, minus the ones that carry the renamed title.
  @struct_fields ~w(size seeders leechers category published_at imdb_id tmdb_id tvdb_id)a
  @metadata_fields ~w(info_hash download_volume_factor upload_volume_factor)a
  @date_tolerance_seconds 60

  @doc """
  Splits a release title into its work name and the rest, at the first token
  (separated by space, `.`, `_` or `-`, brackets ignored) that is a year, an
  episode or season marker, a resolution or a source. A title with no such
  token is all work.
  """
  @spec split_title(String.t()) :: {String.t(), String.t()}
  defdelegate split_title(title), to: Names

  @doc "`trim_with_notes/2` without the notes."
  @spec trim(Capture.t(), Parsed.t()) :: Capture.t()
  def trim(capture, parsed), do: capture |> trim_with_notes(parsed) |> elem(0)

  @doc """
  Keeps only the parts of each successful body the definition reads: for HTML,
  the `rows.selector` matches (with their `after:` siblings) and their
  ancestors; for JSON, the rows path (and `rows.count` path). Failed exchanges,
  pages with no rows and bodies that cannot be trimmed safely are left whole;
  the last kind comes back as a note.
  """
  @spec trim_with_notes(Capture.t(), Parsed.t()) :: {Capture.t(), [String.t()]}
  def trim_with_notes(%Capture{} = capture, %Parsed{search: search, encoding: encoding}) do
    rows = Map.get(search, :rows, %{})

    {exchanges, notes} =
      capture.exchanges
      |> Enum.with_index(1)
      |> Enum.map_reduce([], fn {ex, n}, notes ->
        case Trim.body(ex, rows, encoding) do
          {:ok, body} ->
            {put_body(ex, body), notes}

          :skip ->
            {ex, notes}

          {:untrimmed, why} ->
            {ex, ["exchange #{n} (#{ex.request.url}) untrimmed: #{why}" | notes]}
        end
      end)

    {%{capture | exchanges: exchanges}, Enum.reverse(notes)}
  end

  @doc """
  Replaces the work name of every title, in every form it is written in, with
  its `Fictional` name in the same form. Returns the works, longest first.

  Matching ignores ASCII case. An all-lowercase occurrence gets a lowercase
  replacement; any other gets the capitalised one.

  Request URLs and bodies are renamed too, so a link the engine follows out of
  a renamed page still finds its recorded exchange. Pass `encoding:` for a
  non-UTF-8 definition so the work's bytes in that charset are matched as well,
  and `keep:` for words that must not be renamed (see `seed/3`).
  """
  @spec rename(Capture.t(), [String.t()], keyword()) :: {Capture.t(), [String.t()]}
  def rename(%Capture{} = capture, titles, opts \\ []) do
    keep = opts |> Keyword.get(:keep, []) |> MapSet.new(&Names.fold/1)
    works = titles |> Names.works() |> Enum.reject(&(Names.fold(&1) in keep))
    matcher = Names.matcher(works, opts[:encoding])

    exchanges = Enum.map(capture.exchanges, &rename_exchange(&1, matcher))
    {%{capture | exchanges: exchanges}, works}
  end

  defp rename_exchange(%Exchange{} = ex, matcher) do
    replace = &Names.replace(&1, matcher)

    request =
      RequestKey.new(ex.request.method, replace.(ex.request.url), replace.(ex.request.body))

    headers =
      Enum.map(ex.headers, fn {k, v} ->
        if String.downcase(k) == "content-length", do: {k, v}, else: {k, replace.(v)}
      end)

    ex = %{ex | request: request, headers: headers}
    if is_binary(ex.body), do: put_body(ex, replace.(ex.body)), else: ex
  end

  defp put_body(%Exchange{} = ex, body) do
    headers =
      Enum.map(ex.headers, fn {k, v} ->
        if String.downcase(k) == "content-length",
          do: {k, Integer.to_string(byte_size(body))},
          else: {k, v}
      end)

    %{ex | body: body, headers: headers}
  end

  @doc """
  Checks a scrubbed replay against the original one: the wasm engine finds the
  same number of results, every compared field other than the title-bearing
  ones (`title download_url info_url guid`) agrees pairwise, no work of three or
  more characters is left in any body or request URL in any of its forms
  (ignoring case), and the bodies total at most #{@size_cap} bytes.
  """
  @spec verify(Runner.result(), Runner.result(), [String.t()], Capture.t(), keyword()) ::
          :ok | {:error, [String.t()]}
  def verify(original, scrubbed, works, %Capture{} = capture, opts \\ []) do
    errors =
      parsing_errors(original, scrubbed) ++
        leftover_errors(capture, works, opts[:encoding]) ++ size_errors(capture)

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp parsing_errors(original, scrubbed) do
    misses =
      for %RequestKey{url: url} <- scrubbed.wasm_misses, do: "wasm requested unrecorded #{url}"

    misses ++ result_errors(original, scrubbed)
  end

  defp result_errors(%{wasm: {:ok, before}}, %{wasm: {:ok, now}}) do
    count =
      if length(before) == length(now),
        do: [],
        else: ["wasm found #{length(now)} results, originally #{length(before)}"]

    fields =
      for {{a, b}, i} <- before |> Enum.zip(now) |> Enum.with_index(1),
          field <- @struct_fields ++ @metadata_fields,
          not equal?(field, value(a, field), value(b, field)) do
        "result #{i} #{field}: #{inspect(value(a, field))} became #{inspect(value(b, field))}"
      end

    count ++ fields
  end

  defp result_errors(%{wasm: before}, %{wasm: now}),
    do: [
      "wasm outcome changed or failed: #{inspect(before, limit: 5)} -> #{inspect(now, limit: 5)}"
    ]

  defp value(result, field) when field in @metadata_fields do
    meta = result.metadata || %{}
    Map.get(meta, field, Map.get(meta, Atom.to_string(field)))
  end

  defp value(result, field), do: Map.get(result, field)

  # Relative dates ("2 hours ago") resolve against the clock at replay time.
  defp equal?(:published_at, %DateTime{} = a, %DateTime{} = b),
    do: abs(DateTime.diff(a, b)) <= @date_tolerance_seconds

  defp equal?(_field, a, b), do: a == b

  defp leftover_errors(capture, works, encoding) do
    texts =
      capture.exchanges
      |> Enum.with_index(1)
      |> Enum.flat_map(fn {ex, n} ->
        [{"request #{n} URL", ex.request.url}, {"body #{n}", ex.body || ""}]
      end)
      |> Enum.map(fn {label, text} -> {label, Names.fold(text)} end)

    for work <- works,
        String.length(work) >= @min_work_length,
        needles = Names.needles(work, encoding),
        {label, text} <- texts,
        Enum.any?(needles, &String.contains?(text, &1)) do
      "#{label} still contains #{inspect(work)}"
    end
  end

  defp size_errors(capture) do
    total = capture.exchanges |> Enum.map(&byte_size(&1.body || "")) |> Enum.sum()

    if total > @size_cap,
      do: ["bodies total #{total} bytes, over the #{@size_cap}-byte cap"],
      else: []
  end

  @doc """
  Scrubs the cached capture in `capture_dir` (whose parent holds
  `definition.yml`) into `out_dir`: `out_dir/definition.yml` and
  `out_dir/<kind>/`. Nothing is written unless verification passes.

  Returns notes on success: pages kept untrimmed and works left as they were.
  Options: `trim: false` skips trimming.
  """
  @spec seed(Path.t(), Path.t(), keyword()) :: {:ok, [String.t()]} | {:error, [String.t()]}
  def seed(capture_dir, out_dir, opts \\ []) do
    yaml_path = Path.join(Path.dirname(capture_dir), "definition.yml")

    with {:ok, yaml} <- read(yaml_path),
         {:ok, parsed} <- parse(yaml),
         capture = Capture.read!(capture_dir),
         :ok <- prepare(capture.definition, yaml) do
      scrub(capture, parsed, yaml, Path.join(out_dir, Path.basename(capture_dir)), opts)
    end
  end

  defp scrub(capture, parsed, yaml, kind_dir, opts) do
    original = Runner.replay(capture)
    encoding = parsed.encoding
    vocabulary = vocabulary(parsed)

    with {:ok, titles} <- titles(original),
         {:ok, trimmed, notes} <- maybe_trim(capture, parsed, original, opts),
         {renamed, works} = rename(trimmed, titles, encoding: encoding, keep: vocabulary),
         :ok <- verify(original, Runner.replay(renamed), works, renamed, encoding: encoding) do
      File.mkdir_p!(Path.dirname(kind_dir))
      File.write!(Path.join(Path.dirname(kind_dir), "definition.yml"), yaml)
      File.rm_rf!(kind_dir)
      Capture.write!(renamed, kind_dir)
      {:ok, notes ++ kept_notes(titles, vocabulary)}
    end
  end

  # A work that is also a category the definition maps by name ("SparkyLinux" on
  # a distro tracker) is tracker vocabulary, not a title. Renaming it would also
  # rename the category label so the row stops mapping, and the name is already
  # committed in definition.yml.
  defp vocabulary(%Parsed{capabilities: caps}) do
    for %{"desc" => desc} <- Map.get(caps || %{}, :categorymappings, []),
        is_binary(desc),
        do: desc
  end

  defp kept_notes(titles, vocabulary) do
    keep = MapSet.new(vocabulary, &Names.fold/1)

    for work <- Names.works(titles), Names.fold(work) in keep do
      "kept #{inspect(work)}: it is a category name in the definition"
    end
  end

  defp maybe_trim(capture, parsed, original, opts) do
    if Keyword.get(opts, :trim, true) do
      {trimmed, notes} = trim_with_notes(capture, parsed)

      case parsing_errors(original, Runner.replay(trimmed)) do
        [] -> {:ok, trimmed, notes}
        errors -> {:error, Enum.map(errors, &("after trim: " <> &1))}
      end
    else
      {:ok, capture, []}
    end
  end

  defp titles(%{wasm: {:ok, results}}), do: {:ok, Enum.map(results, & &1.title)}

  defp titles(%{wasm: other}),
    do: {:error, ["wasm failed on the original capture: #{inspect(other, limit: 5)}"]}

  defp read(path) do
    case File.read(path) do
      {:ok, yaml} -> {:ok, yaml}
      {:error, reason} -> {:error, ["cannot read #{path}: #{:file.format_error(reason)}"]}
    end
  end

  defp parse(yaml) do
    case CardigannParser.parse_definition(yaml) do
      {:ok, parsed} -> {:ok, parsed}
      {:error, reason} -> {:error, ["definition does not parse: #{inspect(reason)}"]}
    end
  end

  defp prepare(id, yaml) do
    case Runner.prepare_definition(id, yaml) do
      :ok -> :ok
      {:error, reason} -> {:error, ["cannot load definition #{id}: #{inspect(reason)}"]}
    end
  end
end
