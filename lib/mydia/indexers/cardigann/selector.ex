defmodule Mydia.Indexers.Cardigann.Selector do
  @moduledoc """
  HTML parsing and CSS selection for Cardigann definitions, on lexbor (LazyHTML).

  Definitions are written against goquery (Jackett) and AngleSharp (Prowlarr),
  both of which build an HTML5 tree and implement modern CSS. Floki does
  neither: it inserts no implied `<tbody>` and mis-evaluates nested `:has()` and
  `:not(:has())`, which left acgrip, rutor, torrentkitty, byrutor and
  torrentdownloads with zero or wrong rows. lexbor gets all of them right.

  The one non-standard pseudo-class Cardigann uses is `:contains("text")`. lexbor
  rejects it, so `parse/2` takes every selector the caller will use, collects the
  needles, and stamps a `data-mydia-cN` attribute on every element whose text
  contains needle N. `find/3` rewrites `:contains("text")` to `[data-mydia-cN]`
  and the query stays native, including inside `:has()` and `:not()`.

  Every element also gets a `data-mydia-nid` so `without/3` can drop exactly the
  nodes a `remove:` selector matched. Because of these attributes, callers must
  not enumerate attribute lists or serialize nodes expecting the source HTML.
  """

  alias Mydia.Indexers.Cardigann.Selector.Document

  @contains ~r/:contains\(\s*(?:"((?:[^"\\]|\\.)*)"|'((?:[^'\\]|\\.)*)'|([^()]*?))\s*\)/
  @nid "data-mydia-nid"

  @spec parse(String.t(), [String.t() | nil]) :: Document.t()
  def parse(html, selectors) when is_binary(html) do
    markers =
      selectors
      |> Enum.flat_map(&needles/1)
      |> Enum.uniq()
      |> Enum.with_index()
      |> Map.new(fn {needle, i} -> {needle, "data-mydia-c#{i}"} end)

    tree = html |> LazyHTML.from_document() |> LazyHTML.to_tree()
    {annotated, _next_id} = annotate(tree, markers, 0)

    %Document{root: LazyHTML.from_tree(annotated), markers: markers}
  end

  @spec find(Document.t(), LazyHTML.t() | :root, String.t() | nil) :: [LazyHTML.t()]
  def find(%Document{root: root} = doc, :root, selector), do: do_find(doc, root, selector)
  def find(%Document{} = doc, scope, selector), do: do_find(doc, scope, selector)

  defp do_find(_doc, scope, selector) when selector in [nil, ""], do: [scope]

  defp do_find(%Document{markers: markers}, scope, selector) do
    native = rewrite(selector, markers)

    try do
      scope |> LazyHTML.query(native) |> Enum.to_list()
    rescue
      e in ArgumentError ->
        reraise ArgumentError,
                "invalid selector #{inspect(selector)}: #{Exception.message(e)}",
                __STACKTRACE__
    end
  end

  @spec text([LazyHTML.t()]) :: String.t()
  def text(nodes), do: Enum.map_join(nodes, &LazyHTML.text/1)

  @spec attribute([LazyHTML.t()], String.t()) :: String.t() | nil
  def attribute([], _name), do: nil

  def attribute([first | _], name) do
    case LazyHTML.attribute(first, name) do
      [value | _] -> value
      [] -> nil
    end
  end

  @spec without(Document.t(), LazyHTML.t(), [String.t()]) :: LazyHTML.t()
  def without(%Document{} = doc, node, selectors) do
    # query/2 includes the scope itself; goquery's Find().Remove() only removes
    # descendants, so the scope's own id is never dropped.
    own = LazyHTML.attribute(node, @nid)

    drop =
      selectors
      |> Enum.flat_map(&find(doc, node, &1))
      |> Enum.flat_map(&LazyHTML.attribute(&1, @nid))
      |> Enum.reject(&(&1 in own))
      |> MapSet.new()

    node |> LazyHTML.to_tree() |> prune(drop) |> LazyHTML.from_tree()
  end

  # -- :contains --------------------------------------------------------------

  defp needles(nil), do: []

  defp needles(selector) when is_binary(selector) do
    @contains
    |> Regex.scan(selector)
    |> Enum.map(&needle_from_match/1)
  end

  defp needles(_), do: []

  defp needle_from_match([_full | groups]), do: needle(groups)

  # The first non-empty capture group (double-quoted, single-quoted, bare), unescaped.
  defp needle(groups) do
    groups |> Enum.find(&(&1 not in [nil, ""])) |> Kernel.||("") |> unescape()
  end

  defp unescape(text), do: String.replace(text, ~r/\\(.)/, "\\1")

  defp rewrite(selector, markers) do
    Regex.replace(@contains, selector, fn full, d, s, u ->
      case Map.fetch(markers, needle([d, s, u])) do
        {:ok, attr} ->
          "[#{attr}]"

        :error ->
          raise ArgumentError,
                "selector #{inspect(selector)} uses #{full}, which was not declared to Selector.parse/2"
      end
    end)
  end

  # -- tree annotation ----------------------------------------------------------

  # Returns {annotated_nodes, next_id}. Each element gets a node id and, for each
  # needle its text content contains, that needle's marker attribute. Text is
  # built bottom-up once, so the cost is one pass over the tree.
  defp annotate(nodes, markers, id) when is_list(nodes) do
    Enum.map_reduce(nodes, id, fn node, id ->
      {node, _text, id} = annotate_node(node, markers, id)
      {node, id}
    end)
  end

  defp annotate_node({tag, attrs, children}, markers, id) when is_binary(tag) do
    {children, texts, next} =
      Enum.reduce(children, {[], [], id + 1}, fn child, {acc, texts, next} ->
        {child, text, next} = annotate_node(child, markers, next)
        {[child | acc], [text | texts], next}
      end)

    text = texts |> Enum.reverse() |> IO.iodata_to_binary()

    marks = for {needle, attr} <- markers, String.contains?(text, needle), do: {attr, ""}

    {{tag, [{@nid, Integer.to_string(id)} | attrs] ++ marks, Enum.reverse(children)}, text, next}
  end

  defp annotate_node(text, _markers, id) when is_binary(text), do: {text, text, id}
  defp annotate_node(other, _markers, id), do: {other, "", id}

  defp prune(nodes, drop) when is_list(nodes) do
    nodes
    |> Enum.reject(fn
      {tag, attrs, _} when is_binary(tag) ->
        case List.keyfind(attrs, @nid, 0) do
          {@nid, id} -> MapSet.member?(drop, id)
          nil -> false
        end

      _ ->
        false
    end)
    |> Enum.map(fn
      {tag, attrs, children} when is_binary(tag) -> {tag, attrs, prune(children, drop)}
      other -> other
    end)
  end
end
