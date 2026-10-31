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

  Search and fetch URLs carry credentials too: an indexer's `apikey`, a
  Prowlarr key, a tracker passkey in a Cardigann download link. So the log
  rule covers every URL, not only `download_url`.

  This test reads the source rather than exercising code paths, so it covers
  pages and log lines no other test reaches:

    * Every `Logger` call in `lib/` whose arguments mention a name ending in
      `url` or `urls` (a variable such as `url` or `search_url`, a field access
      such as `req.url`, or a `url:` key) outside a call that hides the secret:
      `redact_url/1`, a host-only helper (`log_origin/1`, `url_host/1`) or a
      `.host` access such as `URI.parse(url).host`. Module attributes are
      compile-time constants and pass. Files that log URLs known to carry no
      credentials are listed in `@allowed`, each with its reason.
    * Every HEEx interpolation, in `.heex` files and `~H` sigils, that mentions
      `download_url` without `redact_url(`. Block heads such as
      `<%= if @download.download_url do %>` decide what renders, not what is
      rendered, and are allowed.

  Like `no_varchar_columns_test.exs`, it only sees what the source spells out.
  A URL bound to a name that does not end in `url` slips past it.
  """
  use ExUnit.Case, async: true

  @logger_levels ~w(debug info notice warning warn error critical alert emergency log)a
  @block_heads ~w(if unless case cond for with)
  @safe_calls [:redact_url, :log_origin, :url_host]

  # Files whose logged URLs carry no credentials.
  @allowed %{
    # The upgrade notice links to the public docs site.
    "lib/mydia/release.ex" => true,
    # Plugin catalog and source URLs are public, operator-declared catalogs.
    "lib/mydia/plugins.ex" => true,
    "lib/mydia/plugins/declared_sources.ex" => true,
    "lib/mydia/plugins/runtime_instances.ex" => true,
    # Cardigann definitions come from a public GitHub repository.
    "lib/mydia/indexers/definition_sync.ex" => true,
    # Relay and public-IP service URLs are Mydia's own or public endpoints.
    "lib/mydia/p2p/server.ex" => true,
    "lib/mydia/remote_access/direct_urls.ex" => true,
    # The Flutter dev proxy points at a localhost dev server.
    "lib/mydia_web/channels/player_dev_socket.ex" => true,
    # Crash reports and subtitles go to metadata-relay, which takes no key in the URL.
    "lib/mydia/crash_reporter/sender.ex" => true,
    "lib/mydia/subtitles/client/metadata_relay.ex" => true,
    # The Cardigann guest is downloaded from a public, pinned release URL.
    "lib/mydia/indexers/cardigann/wasm/delivery.ex" => true
  }

  test "no Logger call or HEEx interpolation exposes a raw URL" do
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

    test "flags any variable, field or key named like a URL" do
      assert [_, _, _, _] =
               source_violations(~S"""
               Logger.debug("Jackett search: #{url}")
               Logger.debug("Newznab test connection: #{full_url}")
               Logger.info("Cardigann http #{req.url}")
               Logger.warning("fetch failed", release_url: release_url)
               """)
    end

    test "flags a serialised URI unless it is redacted" do
      assert [_] =
               source_violations(~S"""
               Logger.debug("request: #{URI.to_string(req)}")
               Logger.debug("request: #{redact_url(URI.to_string(req))}")
               """)
    end

    test "passes host-only helpers, .host and module attributes" do
      assert [] =
               source_violations(~S"""
               Logger.info("Downloading file from #{log_origin(url)}")
               Logger.debug("request: #{URI.parse(search_url).host}")
               Logger.info("Back up first: #{@docs_url}")
               Logger.debug("FlareSolverr #{url_host(url)}")
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

    test "flags a raw URL beside a redacted one in the same expression" do
      source = ~S'''
      def row(assigns) do
        ~H"""
        <p>{@d.download_url <> redact_url(@d.download_url)}</p>
        """
      end
      '''

      assert [_] = source_violations(source)
    end

    test "scans HEEx in a file allowlisted for logging" do
      source = ~S'''
      def row(assigns) do
        Logger.info("docs at #{url}")
        ~H"<p>{@d.download_url}</p>"
      end
      '''

      assert [heex] = violations_in(source, "lib/mydia/release.ex", false)
      assert heex =~ "HEEx renders"
    end
  end

  defp file_violations(path) do
    source = File.read!(path)

    # The allowlist exempts Logger calls only; HEEx is scanned everywhere.
    if String.contains?(source, "url") do
      source
      |> violations_in(path, not Map.has_key?(@allowed, path))
      |> Enum.map(&"#{path}:#{&1}")
    else
      []
    end
  end

  defp source_violations(source), do: violations_in(source, "snippet.ex", true)

  defp violations_in(source, path, check_logs?) do
    if String.ends_with?(path, ".heex") do
      heex_violations(source, 1)
    else
      source
      |> Code.string_to_quoted!(columns: false, file: path)
      |> ast_violations(check_logs?)
    end
  end

  defp ast_violations(ast, check_logs?) do
    {_ast, acc} =
      Macro.prewalk(ast, [], fn
        {:sigil_H, meta, [{:<<>>, _, [template]}, _mods]} = node, acc
        when is_binary(template) ->
          {node, acc ++ heex_violations(template, (meta[:line] || 0) + 1)}

        {{:., meta, [{:__aliases__, _, [:Logger]}, level]}, _, args} = node, acc
        when level in @logger_levels ->
          if check_logs? and raw_reference?(args),
            do: {node, acc ++ ["#{meta[:line]}: Logger.#{level} with a raw URL"]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    acc
  end

  # True when `ast` mentions a URL-named value outside a call that hides it.
  defp raw_reference?(ast) do
    cond do
      safe?(ast) -> false
      url_reference?(ast) -> true
      true -> raw_child_reference?(ast)
    end
  end

  defp raw_child_reference?({key, value}) when is_atom(key),
    do: if(url_name?(key), do: not safe?(value), else: raw_reference?(value))

  defp raw_child_reference?({left, _meta, args}) when is_list(args),
    do: raw_reference?(left) or Enum.any?(args, &raw_reference?/1)

  defp raw_child_reference?({left, right}), do: raw_reference?(left) or raw_reference?(right)
  defp raw_child_reference?(list) when is_list(list), do: Enum.any?(list, &raw_reference?/1)
  defp raw_child_reference?(_other), do: false

  # A variable or a field access whose name ends in url/urls, or a URI
  # serialised whatever its name (URI.to_string(req)).
  defp url_reference?({{:., _, [{:__aliases__, _, [:URI]}, :to_string]}, _, _}), do: true
  defp url_reference?({name, _, ctx}) when is_atom(name) and is_atom(ctx), do: url_name?(name)
  defp url_reference?({{:., _, [_, field]}, _, []}) when is_atom(field), do: url_name?(field)
  defp url_reference?(_other), do: false

  # Calls that redact or keep only the host, `.host` accesses and module attributes.
  defp safe?({name, _, args}) when name in @safe_calls and is_list(args), do: true
  defp safe?({{:., _, [_, name]}, _, _}) when name in @safe_calls, do: true
  defp safe?({{:., _, [_, :host]}, _, []}), do: true
  defp safe?({:@, _, _}), do: true
  defp safe?(_other), do: false

  defp url_name?(name) do
    name = Atom.to_string(name)
    String.ends_with?(name, "url") or String.ends_with?(name, "urls")
  end

  defp heex_violations(template, first_line) do
    template
    |> heex_expressions()
    |> Enum.filter(fn {expr, _offset} ->
      String.contains?(without_redacted(expr), "download_url") and not block_head?(expr)
    end)
    |> Enum.map(fn {expr, offset} ->
      line = first_line + count_newlines(binary_part(template, 0, offset))
      "#{line}: HEEx renders #{String.trim(expr)}"
    end)
  end

  # The expression with every redact_url(...) call removed (one level of
  # nested parentheses), so a raw URL beside a redacted one still shows.
  defp without_redacted(expr),
    do: String.replace(expr, ~r/redact_url\((?:[^()]|\([^()]*\))*\)/, "")

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
