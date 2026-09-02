defmodule MydiaWeb.AddMediaComponentsTest do
  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Mydia.Media.AddDefaults
  alias MydiaWeb.AddMediaComponents

  defp library(id, path, type \\ :movies) do
    %Mydia.Settings.LibraryPath{id: id, path: path, type: type, monitored: true}
  end

  defp config(overrides \\ %{}) do
    Map.merge(
      %{
        provider_id: "551",
        media_type: :movie,
        defaults: %AddDefaults{
          library_path_id: "lib-1",
          quality_profile_id: nil,
          monitored: true,
          season_monitoring: "all",
          search_on_add: true
        },
        preview: %{
          title: "The Kestrel Protocol",
          year: 2021,
          poster_path: "/kestrel.jpg",
          overview: "A courier loses the package."
        },
        libraries: [library("lib-1", "/media/movies")]
      },
      overrides
    )
  end

  defp render_modal(assigns) do
    render_component(&AddMediaComponents.add_config_modal/1, assigns)
  end

  defp document(html), do: LazyHTML.from_fragment(html)

  describe "add_config_modal/1" do
    test "renders nothing but a closed dialog when config is nil" do
      html = render_modal(%{config: nil, quality_profiles: []})

      refute html =~ "Configure Before Adding"
      assert LazyHTML.query(document(html), ~s(dialog[open])) |> Enum.empty?()
    end

    test "renders the title, year and overview from the preview" do
      html = render_modal(%{config: config(), quality_profiles: []})

      assert html =~ "The Kestrel Protocol"
      assert html =~ "2021"
      assert html =~ "A courier loses the package."
    end

    test "renders a placeholder poster when the preview has none" do
      html =
        render_modal(%{
          config:
            config(%{preview: %{title: "No Art", year: nil, poster_path: nil, overview: nil}}),
          quality_profiles: []
        })

      assert html =~ "/images/no-poster.svg"
      assert html =~ "N/A"
    end

    test "preselects the resolved default library" do
      html =
        render_modal(%{
          config:
            config(%{
              libraries: [library("lib-1", "/media/movies"), library("lib-2", "/media/4k")]
            }),
          quality_profiles: []
        })

      selected =
        document(html)
        |> LazyHTML.query(~s(select[name="config[library_path_id]"] option[selected]))
        |> LazyHTML.attribute("value")

      assert selected == ["lib-1"]
    end

    test "labels each library with its basename before its full path" do
      # "/media/movies" cannot tell this apart from rendering the path alone:
      # its own basename ("movies") is already a substring of the full path,
      # so `html =~ "movies"` would pass even if Path.basename/1 were never
      # called. "/srv/vault/cinema" cannot fake a pass that way: "cinema" is
      # not a substring of the path's directory part ("/srv/vault"), so
      # asserting basename-then-path only succeeds if the option's rendered
      # text actually leads with the extracted basename.
      html =
        render_modal(%{
          config: config(%{libraries: [library("lib-1", "/srv/vault/cinema")]}),
          quality_profiles: []
        })

      option_text =
        document(html)
        |> LazyHTML.query(~s(select[name="config[library_path_id]"] option[value="lib-1"]))
        |> LazyHTML.text()
        |> to_string()
        |> String.trim()

      assert option_text == "cinema · /srv/vault/cinema"
    end

    test "omits the season monitoring field for a movie" do
      html = render_modal(%{config: config(), quality_profiles: []})

      assert document(html)
             |> LazyHTML.query(~s(select[name="config[season_monitoring]"]))
             |> Enum.empty?()
    end

    test "renders the season monitoring field for a TV show" do
      html = render_modal(%{config: config(%{media_type: :tv_show}), quality_profiles: []})

      refute document(html)
             |> LazyHTML.query(~s(select[name="config[season_monitoring]"]))
             |> Enum.empty?()
    end

    test "disables submit and warns when there are no libraries" do
      html = render_modal(%{config: config(%{libraries: []}), quality_profiles: []})

      assert html =~ "No library paths configured"

      assert document(html)
             |> LazyHTML.query(~s(button[type="submit"]))
             |> LazyHTML.attribute("disabled") != []
    end

    test "binds Escape and the backdrop to close_add_config" do
      html = render_modal(%{config: config(), quality_profiles: []})
      doc = document(html)

      assert LazyHTML.query(doc, ~s(dialog[phx-key="Escape"]))
             |> LazyHTML.attribute("phx-window-keydown") == ["close_add_config"]

      refute LazyHTML.query(doc, ~s([phx-click="close_add_config"])) |> Enum.empty?()
    end

    test "submits to submit_add_config" do
      html = render_modal(%{config: config(), quality_profiles: []})

      assert document(html)
             |> LazyHTML.query(~s(form#add-config-form))
             |> LazyHTML.attribute("phx-submit") == ["submit_add_config"]
    end
  end
end
