defmodule MydiaWeb.MediaLive.Show.RenameSelectionTest do
  use ExUnit.Case, async: true

  alias Mydia.Library.Structs.RenamePreview
  alias MydiaWeb.MediaLive.Show.RenameSelection

  defp p(id, season, changed?) do
    %RenamePreview{
      file_id: id,
      season_number: season,
      changed?: changed?,
      proposed_path: "/lib/#{id}-new.mkv"
    }
  end

  defp previews, do: [p("a", 1, true), p("b", 1, false), p("c", 2, true), p("d", 2, true)]

  test "initial selects only changed files" do
    assert RenameSelection.initial(previews()) == MapSet.new(["a", "c", "d"])
  end

  test "toggle_file flips a changed file and ignores unchanged or unknown ids" do
    sel = RenameSelection.initial(previews())
    assert RenameSelection.toggle_file(sel, previews(), "a") == MapSet.new(["c", "d"])
    assert RenameSelection.toggle_file(MapSet.new(), previews(), "a") == MapSet.new(["a"])
    assert RenameSelection.toggle_file(sel, previews(), "b") == sel
    assert RenameSelection.toggle_file(sel, previews(), "zzz") == sel
  end

  test "toggle_season fills a partial season, then clears a full one" do
    partial = MapSet.new(["c"])
    full = RenameSelection.toggle_season(partial, previews(), 2)
    assert full == MapSet.new(["c", "d"])
    assert RenameSelection.toggle_season(full, previews(), 2) == MapSet.new()
  end

  test "toggle_season leaves other seasons alone" do
    sel = MapSet.new(["a"])
    assert RenameSelection.toggle_season(sel, previews(), 2) == MapSet.new(["a", "c", "d"])
  end

  test "season_state reports all, some or none of the changed files" do
    season2 = Enum.filter(previews(), &(&1.season_number == 2))
    assert RenameSelection.season_state(MapSet.new(["c", "d"]), season2) == :all
    assert RenameSelection.season_state(MapSet.new(["c"]), season2) == :some
    assert RenameSelection.season_state(MapSet.new(), season2) == :none
  end

  test "groups keeps input order within and across seasons" do
    assert [{1, [%{file_id: "a"}, %{file_id: "b"}]}, {2, [%{file_id: "c"}, %{file_id: "d"}]}] =
             RenameSelection.groups(previews())
  end

  test "specs includes only selected changed previews" do
    assert RenameSelection.specs(MapSet.new(["c", "b"]), previews()) ==
             [%{file_id: "c", new_path: "/lib/c-new.mkv"}]
  end
end
