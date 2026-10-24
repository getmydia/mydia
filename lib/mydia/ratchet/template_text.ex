defmodule Mydia.Ratchet.TemplateText do
  @moduledoc """
  Counts literal, translatable English in HEEx templates: text nodes and the
  literal values of `placeholder`, `title`, `alt`, `aria-label`, `label` and
  `prompt`, when they contain a letter. Expressions (`{...}`, `<%= %>`) are
  never counted, so `gettext(...)` calls are free.

  Skipped: `<script>`, `<style>` and `phx-no-curly-interpolation` elements,
  HTML entities, and text made only of the proper nouns in `@proper_nouns`.

  Uses `Phoenix.LiveView.TagEngine.Parser.tokenize/2`, which is internal to
  LiveView; `Mydia.Ratchet.TemplateTextTest` pins its shape.
  """

  alias Phoenix.LiveView.TagEngine.Parser

  @counted_attrs ~w(placeholder title alt aria-label label prompt)
  @skipped_tags ~w(script style)
  @tag_types [:tag, :local_component, :remote_component, :slot]

  @proper_nouns ~w(Mydia TMDB TVDB IMDb Plex Jellyfin Emby Stash Trakt Sonarr Radarr
                   Prowlarr Jackett qBittorrent Transmission Deluge rTorrent SABnzbd NZBGet
                   TorBox Real-Debrid AllDebrid OIDC TOTP HLS)

  @noise Regex.compile!(
           "&[#\\w]+;|\\b(?:#{Enum.map_join(@proper_nouns, "|", &Regex.escape/1)})\\b",
           "u"
         )

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
    source
    |> Parser.tokenize(tag_handler: Phoenix.LiveView.HTMLEngine, file: "nofile")
    |> Enum.reduce({0, []}, &step/2)
    |> elem(0)
  rescue
    # A template the compiler would reject anyway. Not this check's concern.
    _ -> 0
  end

  # The accumulator is {count, stack of open skipped tag names}.
  defp step({:close, _type, name, _meta}, {n, [name | rest]}), do: {n, rest}
  defp step(_token, {n, [_ | _] = skipping}), do: {n, skipping}

  defp step({type, name, attrs, meta}, {n, []}) when type in @tag_types do
    if skip?(name, attrs) and meta[:closing] not in [:self, :void],
      do: {n, [name]},
      else: {n + Enum.count(attrs, &counted_attr?/1), []}
  end

  defp step({:text, text, _meta}, {n, []}), do: {n + if(words?(text), do: 1, else: 0), []}
  defp step(_token, acc), do: acc

  defp skip?(name, attrs),
    do:
      name in @skipped_tags or
        Enum.any?(attrs, &match?({"phx-no-curly-interpolation", _, _}, &1))

  defp counted_attr?({name, {:string, value, _}, _}) when name in @counted_attrs,
    do: words?(value)

  defp counted_attr?(_attr), do: false

  defp words?(text), do: Regex.match?(~r/\p{L}/u, Regex.replace(@noise, text, ""))

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
