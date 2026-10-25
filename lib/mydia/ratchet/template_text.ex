defmodule Mydia.Ratchet.TemplateText do
  @moduledoc """
  Counts literal, translatable English in HEEx templates: text nodes and the
  literal values of `placeholder`, `title`, `alt`, `aria-label`, `label` and
  `prompt`, when they contain a letter. Expressions (`{...}`, `<%= %>`) are
  never counted, so `gettext(...)` calls are free.

  Skipped: `<script>`, `<style>` and `phx-no-curly-interpolation` elements,
  HTML comments, the doctype, HTML entities, and text made only of the proper
  nouns in `@proper_nouns`, the format names and units in `@technical_tokens`,
  tokens containing a digit or underscore (`1080p`, `2FA`) and single letters.
  A single-token attribute value with a `/ . : @` in it (a URL, path or email
  example) is a value, not prose, and so is a lowercase-identifier or locale-tag
  `placeholder` (`localhost`, `en-US`).

  Uses `Phoenix.LiveView.TagEngine.Parser.tokenize/2`, which is internal to
  LiveView; `Mydia.Ratchet.TemplateTextTest` pins its shape.
  """

  alias Phoenix.LiveView.TagEngine.Parser

  @counted_attrs ~w(placeholder title alt aria-label label prompt)
  @skipped_tags ~w(script style)
  @tag_types [:tag, :local_component, :remote_component, :slot]

  @proper_nouns [
    "Mydia",
    "TMDB",
    "TVDB",
    "IMDb",
    "Plex",
    "Jellyfin",
    "Emby",
    "Stash",
    "Trakt",
    "Sonarr",
    "Radarr",
    "Prowlarr",
    "Jackett",
    "qBittorrent",
    "Transmission",
    "Deluge",
    "rTorrent",
    "SABnzbd",
    "NZBGet",
    "TorBox",
    "Real-Debrid",
    "AllDebrid",
    "OIDC",
    "TOTP",
    "HLS",
    "FlareSolverr",
    "Profilarr",
    "TRaSH Guides",
    "iroh",
    "SQLite",
    "PostgreSQL",
    "Elixir",
    "Usenet",
    "Dolby Vision",
    "HDR"
  ]

  # Format names, file formats and units. They read the same in every locale,
  # so a node made only of these is a value, not prose.
  @technical_tokens ~w(ENV DB CF CSV JSON YAML URL GUID ms KB MB GB TB)

  # The tokenizer returns HTML comments and the doctype as plain text tokens,
  # sometimes sharing one with real text, so they are stripped as noise. So are
  # tokens with a digit or an underscore (`1080p`, `2FA`, `LIBRARY_API_KEY`).
  @noise Regex.compile!(
           "<!--.*?-->|(?i:<!doctype[^>]*>)|&[#\\w]+;|\\S*[\\d_]\\S*|" <>
             "\\b(?:#{Enum.map_join(@proper_nouns ++ @technical_tokens, "|", &Regex.escape/1)})\\b",
           "us"
         )

  # An example value in a form field (`https://x.example.org`, `/path/to/dir`,
  # `john@example.com`): one token with a separator in it, not a word.
  @example_value ~r/^\S*[\/.:@]\S*$/u
  # A `placeholder` that is a lowercase identifier (`localhost`, `my-bucket`) or a
  # locale tag (`en-US`) is an example too. Capitalised words (`Search`) and
  # phrases are prose and still count.
  @example_identifier ~r/^(?:[a-z][a-z0-9-]*|[a-z]{2,3}-[A-Z]{2})$/

  @spec count_file(Path.t()) :: non_neg_integer()
  def count_file(path) do
    source = File.read!(path)

    case Path.extname(path) do
      ".heex" -> count(source)
      ".ex" -> source |> sigils() |> Enum.map(&count/1) |> Enum.sum()
      _ -> 0
    end
  end

  @spec count(binary()) :: non_neg_integer()
  def count(source) do
    case EEx.tokenize(source) do
      {:ok, _tokens} -> count_tokens(source)
      # A template the compiler would reject anyway. Not this check's concern.
      {:error, _message, _meta} -> 0
    end
  end

  # Only an invalid template counts as 0. Any other failure (a changed
  # tokenizer API, a bug in step/2) must raise so the gate cannot pass silently.
  defp count_tokens(source) do
    source
    |> Parser.tokenize(tag_handler: Phoenix.LiveView.HTMLEngine, file: "nofile")
    |> Enum.reduce({0, nil}, &step/2)
    |> elem(0)
  rescue
    Phoenix.LiveView.TagEngine.Tokenizer.ParseError -> 0
  end

  # The accumulator is {count, nil | {skipped tag name, nesting depth}}.
  defp step({:close, _type, name, _meta}, {n, {name, 1}}), do: {n, nil}
  defp step({:close, _type, name, _meta}, {n, {name, depth}}), do: {n, {name, depth - 1}}

  defp step({type, name, _attrs, meta}, {n, {name, depth}} = acc) when type in @tag_types do
    if meta[:closing] in [:self, :void], do: acc, else: {n, {name, depth + 1}}
  end

  defp step(_token, {_n, {_name, _depth}} = skipping), do: skipping

  defp step({type, name, attrs, meta}, {n, nil}) when type in @tag_types do
    if skip?(name, attrs) and meta[:closing] not in [:self, :void],
      do: {n, {name, 1}},
      else: {n + Enum.count(attrs, &counted_attr?/1), nil}
  end

  defp step({:text, text, _meta}, {n, nil}), do: {n + if(words?(text), do: 1, else: 0), nil}
  defp step(_token, acc), do: acc

  defp skip?(name, attrs),
    do:
      name in @skipped_tags or
        Enum.any?(attrs, &match?({"phx-no-curly-interpolation", _, _}, &1))

  defp counted_attr?({name, {:string, value, _}, _}) when name in @counted_attrs do
    value = String.trim(value)

    not Regex.match?(@example_value, value) and
      not (name == "placeholder" and Regex.match?(@example_identifier, value)) and
      words?(value)
  end

  defp counted_attr?(_attr), do: false

  # A word is two or more letters: a lone `v`, `S` or `E` is a prefix, not text.
  defp words?(text), do: Regex.match?(~r/\p{L}{2}/u, Regex.replace(@noise, text, ""))

  defp sigils(source) do
    {_ast, acc} =
      source
      |> Code.string_to_quoted!()
      |> Macro.prewalk([], fn
        {:sigil_H, _, [{:<<>>, _, [template]}, _]} = node, acc when is_binary(template) ->
          {node, [template | acc]}

        node, acc ->
          {node, acc}
      end)

    acc
  end
end
