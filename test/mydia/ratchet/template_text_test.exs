defmodule Mydia.Ratchet.TemplateTextTest do
  use ExUnit.Case, async: true

  alias Mydia.Ratchet.TemplateText

  # These pin the shape of Phoenix.LiveView.TagEngine.Parser.tokenize/2, an
  # internal API. If a LiveView upgrade breaks one, fix TemplateText, do not
  # loosen the test.

  test "counts literal text nodes with letters" do
    assert TemplateText.count(~S|<p>Hello</p><p>  </p><p>42 · 7</p>|) == 1
  end

  test "expressions are never counted" do
    assert TemplateText.count(
             ~S|<p>{@name}</p><p>{gettext("Hi")}</p><%= if @x do %>{@y}<% end %>|
           ) == 0
  end

  test "text around an expression counts once per text node" do
    assert TemplateText.count(~S|<p>Hi {@name}!</p>|) == 1
  end

  test "text inside EEx blocks counts" do
    assert TemplateText.count(~S|<%= if @x do %>Yes<% else %>No<% end %>|) == 2
  end

  test "counts literal translatable attributes on tags and components" do
    src = ~S"""
    <input placeholder="Search" title={@t} />
    <img alt="Poster" />
    <span aria-label="Close"></span>
    <.input label="Time zone" prompt="Pick one" name="tz" class="w-full" />
    """

    assert TemplateText.count(src) == 5
  end

  test "skips script, style and phx-no-curly-interpolation content" do
    src = ~S"""
    <script>var hello = 1;</script>
    <style>.a { color: red; }</style>
    <code phx-no-curly-interpolation>let obj = {key: "val"}</code>
    <p>Counted</p>
    """

    assert TemplateText.count(src) == 1
  end

  test "a same-name element nested in a skipped one does not end the skip early" do
    src = ~S|<div phx-no-curly-interpolation><div>x</div> trailing</div>|
    assert TemplateText.count(src) == 0
    assert TemplateText.count(src <> "<p>After</p>") == 1
  end

  test "invalid templates count 0 without raising" do
    assert TemplateText.count("<div") == 0
    assert TemplateText.count("<%= if %>") == 0
  end

  test "technical tokens, units and single letters alone are not counted" do
    assert TemplateText.count(~S|<p>1080p</p><p>0 GB</p><p>JSON</p><p>2FA</p><p>S</p>|) == 0
    assert TemplateText.count(~S|<span>v{@version}</span><span>{@ms} ms</span>|) == 0
    assert TemplateText.count(~S|<p>Export as JSON file</p>|) == 1
  end

  test "example values in attributes are not counted, words are" do
    assert TemplateText.count(~S|<input placeholder="https://x.example.org" />|) == 0
    assert TemplateText.count(~S|<input placeholder="/path/to/dir" />|) == 0
    assert TemplateText.count(~S|<input placeholder="john@example.com" />|) == 0
    assert TemplateText.count(~S|<input placeholder="localhost" />|) == 0
    assert TemplateText.count(~S|<input placeholder="en-US" />|) == 0
    assert TemplateText.count(~S|<input placeholder="release.mkv" />|) == 0
    assert TemplateText.count(~S|<input placeholder="~/media" />|) == 0

    for prose <- ["Search...", "Loading...", "Delete.", "Name:", "Download/Upload", "e.g. 4K"] do
      assert TemplateText.count(~s|<input placeholder="#{prose}" />|) == 1, prose
    end

    for word <- ["optional", "username", "search"] do
      assert TemplateText.count(~s|<input placeholder="#{word}" />|) == 1, word
    end

    assert TemplateText.count(~S|<p>e.g. 5</p>|) == 1
    assert TemplateText.count(~S|<input title="localhost" />|) == 1
    assert TemplateText.count(~S|<input placeholder="Search" />|) == 1
    assert TemplateText.count(~S|<input placeholder="Type a path: /data" />|) == 1
  end

  test "allowlisted proper nouns and entities alone are not counted" do
    assert TemplateText.count(~S|<p>Mydia</p><p>TMDB · TVDB</p><p>&nbsp;</p>|) == 0
    assert TemplateText.count(~S|<p>Open in Plex</p>|) == 1
  end

  # The tokenizer hands comments and the doctype back as ordinary text tokens.
  test "HTML comments and the doctype are not counted" do
    assert TemplateText.count("<!-- Hello -->") == 0
    assert TemplateText.count("<!DOCTYPE html>") == 0
    assert TemplateText.count("<!-- a --><p>Real</p>") == 1
    assert TemplateText.count("<p>Hi <!-- note --> there</p>") == 1
  end

  test "the root layout has no untranslated text" do
    assert TemplateText.count_file("lib/mydia_web/components/layouts/root.html.heex") == 0
  end

  test "count_file/1 sums every ~H in an .ex file" do
    path = Path.join(System.tmp_dir!(), "tt_#{System.unique_integer([:positive])}.ex")

    File.write!(path, ~S'''
    defmodule TT do
      use Phoenix.Component
      def a(assigns), do: ~H"<p>One</p>"
      def b(assigns) do
        ~H"""
        <p>Two</p><p>{@x}</p>
        """
      end
    end
    ''')

    on_exit(fn -> File.rm(path) end)
    assert TemplateText.count_file(path) == 2
  end
end
