defmodule Mydia.NoRawDownloadUrlTest do
  @moduledoc """
  A release's `download_url` often carries the tracker credentials of the
  account that searched: a `passkey`, `torrent_pass` or `apikey` query
  parameter. Anyone holding that URL can grab torrents as that account, and
  a private tracker treats a leaked passkey as the account owner's fault.

  So the URL stays on the server. It must not reach a log line, and it must
  not be rendered into a page, where it would sit in the DOM and in every
  LiveView diff. Search rows reference results with
  `MydiaWeb.Live.SearchResultRef` instead, and a page that shows a source URL
  shows `Mydia.Downloads.Client.Helpers.redact_url/1` of it.

  This test reads the source rather than exercising code paths, so it covers
  pages and log lines no other test reaches:

    * Every `Logger` call in `lib/` whose arguments mention `download_url` (a
      variable, a field access or a `download_url:` key) outside a
      `redact_url(...)` call.
    * Every HEEx interpolation, in `.heex` files and `~H` sigils, that mentions
      `download_url` without `redact_url(`. Block heads such as
      `<%= if @download.download_url do %>` decide what renders, not what is
      rendered, and are allowed.

  Like `no_varchar_columns_test.exs`, it only sees what the source spells out.
  A URL renamed to `url` before logging slips past it.
  """
  use ExUnit.Case, async: true

  @logger_levels ~w(debug info notice warning warn error critical alert emergency log)a
  @block_heads ~w(if unless case cond for with)

  test "no Logger call or HEEx interpolation exposes a raw download_url" do
    violations =
      "lib/**/*.{ex,heex}"
      |> Path.wildcard()
      |> Enum.flat_map(&file_violations/1)

    assert violations == [],
           """
           These lines expose a download URL, which can carry tracker credentials.
           Pass it through Mydia.Downloads.Client.Helpers.redact_url/1, log the
           download id instead, or reference search results with
           MydiaWeb.Live.SearchResultRef:

           #{Enum.join(violations, "\n")}
           """
  end

  describe "the scanner" do
    test "flags a Logger call that interpolates download_url" do
      assert [_] =
               source_violations(~S"""
               Logger.info("Grabbing #{download.download_url}")
               """)
    end

    test "flags a download_url metadata key and a bare variable" do
      assert [_, _] =
               source_violations(~S"""
               Logger.warning("grab failed", download_url: url)
               Logger.error("grab failed: " <> download_url)
               """)
    end

    test "passes a Logger call that redacts" do
      assert [] =
               source_violations(~S"""
               Logger.info("Grabbing #{Helpers.redact_url(download.download_url)}",
                 download_url: redact_url(download_url)
               )
               """)
    end

    test "flags HEEx that renders download_url and passes redacted or block heads" do
      source = ~S'''
      def row(assigns) do
        ~H"""
        <%= if @download.download_url do %>
          <p>{redact_url(@download.download_url)}</p>
        <% end %>
        <button phx-value-url={@result.download_url}>Grab</button>
        <span><%= @download.download_url %></span>
        """
      end
      '''

      assert [first, second] = source_violations(source)
      assert first =~ "@result.download_url"
      assert second =~ "@download.download_url"
    end
  end

  defp file_violations(path) do
    source = File.read!(path)

    if String.contains?(source, "download_url") do
      source
      |> violations_in(path)
      |> Enum.map(&"#{path}:#{&1}")
    else
      []
    end
  end

  defp source_violations(source), do: violations_in(source, "snippet.ex")

  defp violations_in(source, path) do
    if String.ends_with?(path, ".heex") do
      heex_violations(source, 1)
    else
      source
      |> Code.string_to_quoted!(columns: false, file: path)
      |> ast_violations()
    end
  end

  defp ast_violations(ast) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {:sigil_H, meta, [{:<<>>, _, [template]}, _mods]} = node, acc
        when is_binary(template) ->
          {node, acc ++ heex_violations(template, (meta[:line] || 0) + 1)}

        {{:., meta, [{:__aliases__, _, [:Logger]}, level]}, _, args} = node, acc
        when level in @logger_levels ->
          if raw_reference?(args),
            do: {node, acc ++ ["#{meta[:line]}: Logger.#{level} with a raw download_url"]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # True when `ast` mentions download_url anywhere outside a redact_url call.
  defp raw_reference?({:redact_url, _, args}) when is_list(args), do: false
  defp raw_reference?({{:., _, [_, :redact_url]}, _, _}), do: false
  defp raw_reference?({:download_url, _, ctx}) when is_atom(ctx), do: true
  defp raw_reference?({{:., _, [_, :download_url]}, _, _}), do: true
  defp raw_reference?({:download_url, value}), do: not redact_call?(value)

  defp raw_reference?({left, _meta, args}) when is_list(args),
    do: raw_reference?(left) or Enum.any?(args, &raw_reference?/1)

  defp raw_reference?({left, right}), do: raw_reference?(left) or raw_reference?(right)
  defp raw_reference?(list) when is_list(list), do: Enum.any?(list, &raw_reference?/1)
  defp raw_reference?(_other), do: false

  defp redact_call?({:redact_url, _, args}) when is_list(args), do: true
  defp redact_call?({{:., _, [_, :redact_url]}, _, _}), do: true
  defp redact_call?(_other), do: false

  defp heex_violations(template, first_line) do
    template
    |> heex_expressions()
    |> Enum.filter(fn {expr, _offset} ->
      String.contains?(expr, "download_url") and not String.contains?(expr, "redact_url(") and
        not block_head?(expr)
    end)
    |> Enum.map(fn {expr, offset} ->
      line = first_line + count_newlines(binary_part(template, 0, offset))
      "#{line}: HEEx renders #{String.trim(expr)}"
    end)
  end

  defp block_head?(expr) do
    head = expr |> String.trim() |> String.split(~r/[\s(]/, parts: 2) |> hd()
    head in @block_heads
  end

  # Every output expression in a template with its byte offset: the body of
  # each `<%= ... %>` and each top-level `{...}` outside EEx tags and comments.
  defp heex_expressions(template) do
    eex = Regex.scan(~r/<%=(.*?)%>/s, template, return: :index)

    outputs =
      Enum.map(eex, fn [_whole, {start, len}] -> {binary_part(template, start, len), start} end)

    # Blank out comments and every EEx tag (keeping offsets) before matching braces.
    masked =
      Regex.replace(~r/<%!--.*?--%>|<%.*?%>/s, template, fn match ->
        String.duplicate(" ", byte_size(match))
      end)

    Enum.sort_by(outputs ++ curly_expressions(masked), &elem(&1, 1))
  end

  defp curly_expressions(text) do
    text
    |> scan_curly(0, 0, nil, [])
    |> Enum.map(fn {start, stop} -> {binary_part(text, start, stop - start), start} end)
  end

  defp scan_curly(<<>>, _pos, _depth, _start, acc), do: Enum.reverse(acc)

  defp scan_curly(<<"{", rest::binary>>, pos, 0, nil, acc),
    do: scan_curly(rest, pos + 1, 1, pos + 1, acc)

  defp scan_curly(<<"{", rest::binary>>, pos, depth, start, acc) when depth > 0,
    do: scan_curly(rest, pos + 1, depth + 1, start, acc)

  defp scan_curly(<<"}", rest::binary>>, pos, 1, start, acc),
    do: scan_curly(rest, pos + 1, 0, nil, [{start, pos} | acc])

  defp scan_curly(<<"}", rest::binary>>, pos, depth, start, acc) when depth > 1,
    do: scan_curly(rest, pos + 1, depth - 1, start, acc)

  defp scan_curly(<<_char, rest::binary>>, pos, depth, start, acc),
    do: scan_curly(rest, pos + 1, depth, start, acc)

  defp count_newlines(text), do: text |> :binary.matches("\n") |> length()
end
