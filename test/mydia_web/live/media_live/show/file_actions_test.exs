defmodule MydiaWeb.MediaLive.Show.FileActionsTest do
  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mydia.Library.MediaFile
  alias MydiaWeb.MediaLive.Show.Components
  alias MydiaWeb.StreamLink

  @user_id "11111111-1111-1111-1111-111111111111"

  defp file do
    %MediaFile{
      id: "file-1",
      resolution: "2160p",
      codec: "hevc",
      library_path: nil,
      relative_path: "Lanternfall.2031.2160p.mkv"
    }
  end

  defp render_actions(attrs) do
    render_component(
      &Components.file_actions/1,
      Keyword.merge(
        [
          file: file(),
          container: "mfrow",
          item_label: "movie",
          subtitle_button_id: "subtitle-open-file-file-1",
          current_user_id: @user_id
        ],
        attrs
      )
    )
  end

  defp query(html, selector), do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector)
  defp present?(html, selector), do: Enum.any?(query(html, selector))

  defp attr(html, selector, name),
    do: html |> query(selector) |> LazyHTML.attribute(name) |> List.first()

  describe "visible strip" do
    test "the stream link button carries a verified signed path and a label" do
      html = render_actions([])

      ["", "stream", token, _name] =
        String.split(attr(html, "#stream-link-file-1", "data-href"), "/")

      assert StreamLink.verify(token) == {:ok, {@user_id, "file-1"}}
      assert html |> query("#stream-link-file-1") |> LazyHTML.text() =~ "Copy stream link"
      assert attr(html, "#stream-link-file-1", "class") =~ "btn-primary"
    end

    test "no stream link without a user" do
      refute present?(render_actions(current_user_id: nil), "#stream-link-file-1")
    end

    test "subtitles and details are visible, outside the menu" do
      html = render_actions([])

      assert present?(html, "#subtitle-open-file-file-1")
      assert present?(html, "#file-details-open-file-1")
      refute present?(html, "#file-actions-menu-file-1 #subtitle-open-file-file-1")
      refute present?(html, "#file-actions-menu-file-1 #file-details-open-file-1")
    end

    test "play shows only when a play url is given" do
      refute present?(render_actions([]), "#play-file-1")
      assert present?(render_actions(play_url: "/player/x"), "#play-file-1")
    end
  end

  describe "more menu" do
    test "holds preferred, not-this, and delete" do
      html = render_actions([])

      for id <- ~w(mark-preferred-file-1 not-this-item-file-1 file-delete-file-1) do
        assert present?(html, "#file-actions-menu-file-1 ##{id}"), "#{id} not in menu"
      end

      assert html |> query("#not-this-item-file-1") |> LazyHTML.text() =~ "Not this movie"
    end

    test "move to extras only when demotable" do
      refute present?(render_actions([]), "#demote-file-1")

      assert present?(
               render_actions(demotable?: true),
               "#file-actions-menu-file-1 #demote-file-1"
             )
    end

    test "lists pre-transcode resolutions below the source resolution" do
      html = render_actions([])

      assert present?(html, "#file-actions-menu-file-1 #pre-transcode-file-1-1080p")
    end
  end

  describe "markup" do
    @label "#stream-link-file-1 [aria-live]"

    test "stream label is announced and only hidden on narrow side-by-side episode rows" do
      eprow = render_actions(container: "eprow", subtitle_button_id: "subtitle-open-file-1")

      assert attr(eprow, @label, "aria-live") == "polite"
      assert attr(eprow, @label, "class") =~ "@md/eprow:sr-only"

      mfrow = render_actions([])
      assert attr(mfrow, @label, "aria-live") == "polite"
      refute attr(mfrow, @label, "class") =~ "sr-only"
    end

    test "dropdown menu drops daisyUI nested-menu styles and holds only li children" do
      html = render_actions([])

      assert attr(html, "#file-actions-menu-file-1", "class") =~ "before:hidden"
      refute present?(html, "#file-actions-menu-file-1 > div")
      assert present?(html, "#file-actions-menu-file-1 > li.divider")
    end
  end

  describe "container sizing" do
    test "movie squares use the mfrow variant, episode squares the eprow one" do
      mfrow = attr(render_actions([]), "#subtitle-open-file-file-1", "class")
      assert mfrow =~ "@md/mfrow:btn-sm"
      refute Regex.match?(~r/(^|\s)btn-sm(\s|$)/, mfrow)

      eprow =
        attr(
          render_actions(container: "eprow", subtitle_button_id: "subtitle-open-file-1"),
          "#subtitle-open-file-1",
          "class"
        )

      assert eprow =~ "@md/eprow:btn-xs"
      refute Regex.match?(~r/(^|\s)btn-xs(\s|$)/, eprow)
    end
  end
end
