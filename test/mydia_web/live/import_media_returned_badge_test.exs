defmodule MydiaWeb.ImportMediaLive.ReturnedBadgeTest do
  use MydiaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Mydia.MediaFixtures
  import Mydia.SettingsFixtures

  alias Mydia.ImportCandidates
  alias Mydia.Library.ImportCandidateGroup
  alias MydiaWeb.ImportMediaLive.Components

  defp only_group(attrs) do
    lp = library_path_fixture(%{type: "series"})

    import_candidate_fixture(
      Map.merge(%{library_path_id: lp.id, relative_path: "Quillmoor/s01e01.mkv"}, attrs)
    )

    {[group], nil} = ImportCandidates.page(lp.id)
    group
  end

  defp badge?(group) do
    render_component(&Components.group_row/1,
      id: "row",
      group: group,
      band: ImportCandidates.band(group),
      selected: false,
      expanded: false,
      members: []
    )
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#group-returned-#{ImportCandidateGroup.dom_id(group)}")
    |> Enum.any?()
  end

  test "a group holding a returned file carries a Returned badge" do
    group = only_group(%{returned_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    assert badge?(group)
  end

  test "an ordinary group does not" do
    refute badge?(only_group(%{}))
  end
end
