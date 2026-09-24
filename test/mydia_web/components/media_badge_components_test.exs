defmodule MydiaWeb.MediaBadgeComponentsTest do
  @moduledoc """
  Content rating and show status badges shared by the library card, the
  detail hero and the trending preview modal.
  """

  use ExUnit.Case, async: true
  use Phoenix.Component

  import Phoenix.LiveViewTest
  import MydiaWeb.MediaBadgeComponents

  alias Mydia.Metadata.Structs.MediaMetadata

  describe "content_rating_badge/1" do
    test "renders the rating text" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.content_rating_badge rating="TV-MA" id="r" size="sm" />
        """)

      fragment = LazyHTML.from_fragment(html)
      rating = LazyHTML.query(fragment, "#r")

      assert Enum.count(rating) == 1
      assert html =~ "TV-MA"
      assert html =~ "badge-outline"
      assert html =~ "badge-sm"
      assert html =~ "font-mono"
    end

    test "renders nothing when rating is nil" do
      assigns = %{rating: nil}

      html =
        rendered_to_string(~H"""
        <.content_rating_badge rating={@rating} id="r" size="sm" />
        """)

      assert String.trim(html) == ""
    end

    test "renders nothing when rating is an empty string" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.content_rating_badge rating="" id="r" size="sm" />
        """)

      assert String.trim(html) == ""
    end

    test "defaults to size sm" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.content_rating_badge rating="PG-13" id="r" />
        """)

      assert html =~ "badge-sm"
    end
  end

  describe "show_status_badge/1" do
    test "continuing renders the label and a success status dot" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.show_status_badge status={:continuing} id="s" size="sm" />
        """)

      assert html =~ "Continuing"
      assert html =~ "status-success"
      assert html =~ ~s(data-status="continuing")
    end

    test "ended renders the label and a visible muted status dot" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.show_status_badge status={:ended} id="s" size="sm" />
        """)

      assert html =~ "Ended"
      assert html =~ "bg-base-content/40"
    end

    test "canceled renders the label and an error status dot" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.show_status_badge status={:canceled} id="s" size="sm" />
        """)

      assert html =~ "Canceled"
      assert html =~ "status-error"
    end

    test "upcoming renders the label and an info status dot" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.show_status_badge status={:upcoming} id="s" size="sm" />
        """)

      assert html =~ "Upcoming"
      assert html =~ "status-info"
    end

    test "renders nothing when status is nil" do
      assigns = %{status: nil}

      html =
        rendered_to_string(~H"""
        <.show_status_badge status={@status} id="s" size="sm" />
        """)

      assert String.trim(html) == ""
    end

    test "renders the badge-ghost gap-1 classes and the status dot span" do
      assigns = %{}

      html =
        rendered_to_string(~H"""
        <.show_status_badge status={:continuing} id="s" size="md" />
        """)

      fragment = LazyHTML.from_fragment(html)

      assert html =~ "badge-ghost"
      assert html =~ "badge-md"
      assert html =~ "gap-1"
      assert fragment |> LazyHTML.query(".status.status-success") |> Enum.count() == 1
    end
  end

  describe "format_release_date/1" do
    test "formats a date as abbreviated month, day, year" do
      assert format_release_date(~D[2019-03-04]) == "Mar 4, 2019"
    end

    test "returns nil for nil" do
      assert format_release_date(nil) == nil
    end
  end

  describe "release_date/1" do
    test "picks release_date for a movie" do
      metadata = %MediaMetadata{
        provider_id: "1",
        provider: :tmdb,
        media_type: :movie,
        release_date: ~D[2019-03-04],
        first_air_date: ~D[2020-01-01]
      }

      assert release_date(metadata) == ~D[2019-03-04]
    end

    test "picks first_air_date for a tv show" do
      metadata = %MediaMetadata{
        provider_id: "1",
        provider: :tmdb,
        media_type: :tv_show,
        release_date: ~D[2019-03-04],
        first_air_date: ~D[2020-01-01]
      }

      assert release_date(metadata) == ~D[2020-01-01]
    end

    test "returns nil for nil" do
      assert release_date(nil) == nil
    end
  end
end
