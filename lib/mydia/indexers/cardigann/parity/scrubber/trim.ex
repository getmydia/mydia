defmodule Mydia.Indexers.Cardigann.Parity.Scrubber.Trim do
  @moduledoc """
  Cuts a recorded results page down to the rows a definition reads.

  Tracker pages carry sidebars, "popular this week" lists and footers full of
  real titles that no field selector ever reaches, so the scrubber cannot rename
  them (it only learns titles from parsed results). Trimming removes them
  instead. See `Mydia.Indexers.Cardigann.Parity.Scrubber.trim/2` for the rules.

  HTML goes through the native engine's own `Selector`, so a rows selector is
  matched exactly as the native engine matches it, `:contains` included. Every
  element there carries a `data-mydia-nid`, which is how a match is found again
  in the tree; those attributes are stripped before serialising.

  Bodies are decoded with the definition's `encoding` and encoded back into it,
  so a windows-1251 fixture stays windows-1251 and both engines still exercise
  their charset handling. A body whose trimmed text cannot be encoded back is
  kept whole. XML is kept whole too: lexbor parses it as HTML (`<link>` is a
  void element there), so a round trip would corrupt RSS feeds.
  """

  alias Mydia.Indexers.Cardigann.{Charset, Selector}
  alias Mydia.Indexers.Cardigann.Parity.Capture.Exchange

  @nid "data-mydia-nid"
  @doctype ~r/\A\s*(<!doctype[^>]*>)/i
  @simple_path ~r/\A[\w-]+(\.[\w-]+)*\z/u
  @json_selector ~r/\A\$?\.*[\w-]+(\.[\w-]+)*\z/u

  @type outcome :: {:ok, binary()} | :skip | {:untrimmed, String.t()}

  @doc """
  The trimmed body of an exchange, or why it stays whole. `:skip` only for an
  exchange with no body to write (a transport error or an empty body).
  """
  @spec body(Exchange.t(), map(), String.t() | nil, map()) :: outcome()
  def body(ex, rows, encoding, fields \\ %{})

  def body(%Exchange{body: body}, _rows, _encoding, _fields) when body in [nil, ""], do: :skip

  def body(%Exchange{status: status}, _rows, _encoding, _fields) when status not in 200..299,
    do: {:untrimmed, "HTTP #{status} bodies are kept whole"}

  def body(%Exchange{body: body} = ex, rows, encoding, fields) do
    text = Charset.decode(body, encoding)

    result =
      case kind(ex, text) do
        :xml -> {:untrimmed, "XML bodies are kept whole"}
        :json -> json(text, rows, fields)
        :html -> html(text, rows)
      end

    case result do
      {:ok, trimmed} -> encode(trimmed, encoding)
      other -> other
    end
  end

  defp kind(%Exchange{headers: headers}, text) do
    type =
      Enum.find_value(headers, "", fn {k, v} ->
        if String.downcase(k) == "content-type", do: String.downcase(v)
      end)

    head = String.trim_leading(text)

    cond do
      type =~ "json" or String.starts_with?(head, ["{", "["]) -> :json
      String.starts_with?(head, "<?xml") or (type =~ "xml" and not (type =~ "html")) -> :xml
      true -> :html
    end
  end

  defp encode(text, encoding) do
    bytes = Charset.encode(text, encoding)

    # Charset.encode/2 hands the UTF-8 back untouched when a character has no
    # mapping, which would silently change the body's charset.
    if bytes == text and not ascii?(text) and Charset.decode(text, encoding) != text,
      do: {:untrimmed, "trimmed text does not fit #{encoding}"},
      else: {:ok, bytes}
  end

  defp ascii?(text), do: text |> :binary.bin_to_list() |> Enum.all?(&(&1 < 128))

  # -- HTML ---------------------------------------------------------------------

  defp html(text, %{selector: selector} = rows) when is_binary(selector) and selector != "" do
    doc = Selector.parse(text, [selector])

    case Selector.find(doc, :root, selector) do
      [] ->
        {:untrimmed, "the rows selector matches nothing (not a results page, or no results)"}

      matches ->
        keep = matches |> Enum.flat_map(&LazyHTML.attribute(&1, @nid)) |> MapSet.new()
        after_n = after_count(rows)
        tree = doc.root |> LazyHTML.to_tree() |> prune(keep, after_n)
        {:ok, doctype(text) <> LazyHTML.Tree.to_html(tree)}
    end
  rescue
    e in ArgumentError ->
      {:untrimmed,
       "rows selector #{inspect(selector)} cannot be evaluated: #{Exception.message(e)}"}
  end

  defp html(_text, _rows), do: {:untrimmed, "the definition has no rows selector"}

  defp after_count(rows) do
    case Map.get(rows, :after) do
      n when is_integer(n) and n > 0 -> n
      _ -> 0
    end
  end

  defp doctype(text) do
    case Regex.run(@doctype, text) do
      [_, doctype] -> doctype <> "\n"
      nil -> ""
    end
  end

  # Keeps the matched rows (and the `after:` siblings joined to them) whole,
  # their ancestors with every other child dropped, and charset `<meta>` tags so
  # a parser that sniffs the charset still finds it.
  defp prune(nodes, keep, after_n) do
    {kept, _extra} = Enum.reduce(nodes, {[], 0}, &prune_node(&1, &2, keep, after_n))
    Enum.reverse(kept)
  end

  defp prune_node({tag, attrs, children} = node, {acc, extra}, keep, after_n) do
    cond do
      nid(attrs) in keep -> {[strip(node) | acc], after_n}
      extra > 0 -> {[strip(node) | acc], extra - 1}
      charset_meta?(tag, attrs) -> {[strip(node) | acc], extra}
      true -> {prune_children(tag, attrs, children, keep, after_n, acc), extra}
    end
  end

  # Text and comments outside a kept row are dropped.
  defp prune_node(_text_or_comment, acc, _keep, _after_n), do: acc

  defp prune_children(tag, attrs, children, keep, after_n, acc) do
    case prune(children, keep, after_n) do
      [] -> acc
      kids -> [{tag, strip_attrs(attrs), kids} | acc]
    end
  end

  defp nid(attrs) do
    case List.keyfind(attrs, @nid, 0) do
      {_, id} -> id
      nil -> nil
    end
  end

  defp charset_meta?("meta", attrs),
    do: Enum.any?(attrs, fn {k, _} -> String.downcase(k) in ["charset", "http-equiv"] end)

  defp charset_meta?(_tag, _attrs), do: false

  defp strip({tag, attrs, children}),
    do: {tag, strip_attrs(attrs), Enum.map(children, &strip/1)}

  defp strip(other), do: other

  defp strip_attrs(attrs),
    do: Enum.reject(attrs, fn {k, _} -> String.starts_with?(k, "data-mydia-") end)

  # -- JSON ---------------------------------------------------------------------

  defp json(text, rows, fields) do
    with {:ok, decoded} <- Jason.decode(text, objects: :ordered_objects),
         [rows_path | _] = paths <- json_paths(rows) do
      kept =
        case keep_paths(decoded, paths) do
          {:ok, kept} -> {:ok, prune_rows(kept, rows_path, read_keys(rows, fields))}
          :missing -> :missing
        end

      case kept do
        {:ok, ^decoded} -> {:untrimmed, "the JSON holds nothing besides the rows it reads"}
        {:ok, kept} -> {:ok, Jason.encode!(kept)}
        :missing -> {:untrimmed, "the JSON rows path is not in the body"}
      end
    else
      {:error, _} -> {:untrimmed, "body looks like JSON but does not decode"}
      [] -> {:untrimmed, "the JSON rows are the whole body"}
      {:untrimmed, _} = untrimmed -> untrimmed
    end
  end

  # The rows path plus the `rows.count` path, when both are plain dotted keys.
  defp json_paths(rows) do
    case path(Map.get(rows, :selector)) do
      :root ->
        []

      {:ok, rows_path} ->
        count =
          case path(count_selector(rows)) do
            {:ok, count_path} -> [count_path]
            _ -> []
          end

        [rows_path | count]

      :complex ->
        {:untrimmed, "JSON rows path #{inspect(rows[:selector])} is not a plain dotted path"}
    end
  end

  defp count_selector(rows) do
    case Map.get(rows, :count) do
      %{} = count -> Map.get(count, "selector") || Map.get(count, :selector)
      _ -> nil
    end
  end

  defp path(nil), do: :root
  defp path(selector) when not is_binary(selector), do: :complex

  defp path(selector) do
    case selector
         |> String.trim()
         |> String.replace_prefix("$", "")
         |> String.trim_leading(".") do
      "" ->
        :root

      rest ->
        if Regex.match?(@simple_path, rest), do: {:ok, String.split(rest, ".")}, else: :complex
    end
  end

  # The JSON keys the definition can read inside a row: every key named in a
  # field selector (`..title` reads the parent's `title`) and the rows
  # `attribute`. A row object also carries plot summaries and cast lists no
  # field reads, full of real names, so everything else goes. `:all` when a
  # selector is more than dotted keys, since its keys cannot be listed safely.
  defp read_keys(rows, fields) do
    selectors =
      [Map.get(rows, :attribute) | Enum.map(fields, fn {_name, f} -> Map.get(f, :selector) end)]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    if Enum.all?(selectors, &Regex.match?(@json_selector, &1)),
      do:
        selectors |> Enum.flat_map(&Regex.scan(~r/[\w-]+/u, &1)) |> List.flatten() |> MapSet.new(),
      else: :all
  end

  defp prune_rows(value, _path, :all), do: value

  defp prune_rows(%Jason.OrderedObject{values: values} = object, [key | rest], keys) do
    values =
      for {k, v} <- values,
          do: if(k == key, do: {k, prune_rows(v, rest, keys)}, else: {k, v})

    %{object | values: values}
  end

  defp prune_rows(value, [], keys), do: prune_keys(value, keys)
  defp prune_rows(value, _path, _keys), do: value

  defp prune_keys(%Jason.OrderedObject{values: values}, keys),
    do: %Jason.OrderedObject{
      values: for({k, v} <- values, k in keys, do: {k, prune_keys(v, keys)})
    }

  defp prune_keys(list, keys) when is_list(list), do: Enum.map(list, &prune_keys(&1, keys))
  defp prune_keys(value, _keys), do: value

  # Keeps only the keys on one of `paths`. A path that runs into a non-object
  # keeps that value whole; the rows path itself must exist.
  defp keep_paths(value, paths) do
    cond do
      [] in paths -> {:ok, value}
      match?(%Jason.OrderedObject{}, value) -> keep_object_paths(value, paths)
      true -> {:ok, value}
    end
  end

  defp keep_object_paths(%Jason.OrderedObject{values: values}, paths) do
    kept =
      for {key, inner} <- values,
          sub = for([^key | rest] <- paths, do: rest),
          sub != [],
          {:ok, pruned} <- [keep_paths(inner, sub)],
          do: {key, pruned}

    if kept == [], do: :missing, else: {:ok, %Jason.OrderedObject{values: kept}}
  end
end
