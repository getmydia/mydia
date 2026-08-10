defmodule Mydia.Settings.CustomFormatsTest do
  use Mydia.DataCase, async: true

  import Mydia.SettingsFixtures

  alias Mydia.Settings.CustomFormats

  describe "list_all/0" do
    test "returns built-ins when no DB rows exist" do
      slugs = Enum.map(CustomFormats.list_all(), & &1.slug)
      assert "lang-vff" in slugs
      assert "lang-vfq" in slugs
    end

    test "marks built-ins as builtin? and not overridden" do
      vff = Enum.find(CustomFormats.list_all(), &(&1.slug == "lang-vff"))
      assert vff.builtin?
      refute vff.overridden?
      assert vff.patterns == ["\\bVFF\\b", "\\bTRUEFRENCH\\b"]
    end

    test "a DB row shadows the built-in it overrides" do
      {:ok, _} =
        CustomFormats.override_builtin("lang-vff", %{patterns: ["\\bVFF\\b"], name: "VFF"})

      vff = Enum.find(CustomFormats.list_all(), &(&1.slug == "lang-vff"))
      assert vff.builtin?
      assert vff.overridden?
      assert vff.patterns == ["\\bVFF\\b"]
    end

    test "reset_builtin/1 restores the shipped definition" do
      {:ok, _} = CustomFormats.override_builtin("lang-vff", %{patterns: ["x"], name: "VFF"})
      :ok = CustomFormats.reset_builtin("lang-vff")

      vff = Enum.find(CustomFormats.list_all(), &(&1.slug == "lang-vff"))
      refute vff.overridden?
      assert vff.patterns == ["\\bVFF\\b", "\\bTRUEFRENCH\\b"]
    end

    test "includes user-created formats alongside built-ins" do
      format = custom_format_fixture(%{name: "Anime Dual Audio", slug: "anime-dual"})
      view = Enum.find(CustomFormats.list_all(), &(&1.slug == format.slug))
      assert view
      refute view.builtin?
    end

    test "a user format may not take a built-in slug" do
      assert {:error, changeset} =
               CustomFormats.create_format(%{
                 name: "Fake VFF",
                 slug: "lang-vff",
                 patterns: ["x"]
               })

      assert %{slug: _} = errors_on(changeset)
    end
  end

  describe "delete_format/1" do
    test "deletes a user format and its assignments" do
      profile = quality_profile_fixture()
      format = custom_format_fixture()

      :ok =
        CustomFormats.set_assignments(profile, [
          %{format_slug: format.slug, score: 100, reject: false}
        ])

      :ok = CustomFormats.delete_format(format.slug)

      assert CustomFormats.list_assignments(profile) == []
    end

    test "refuses to delete a built-in" do
      assert {:error, :builtin} = CustomFormats.delete_format("lang-vff")
    end
  end

  describe "resolve_for_profile/1" do
    test "returns [] for nil" do
      assert CustomFormats.resolve_for_profile(nil) == []
    end

    test "returns [] when the profile scores nothing" do
      assert CustomFormats.resolve_for_profile(quality_profile_fixture()) == []
    end

    test "returns compiled formats for scored assignments" do
      profile = quality_profile_fixture()

      :ok =
        CustomFormats.set_assignments(profile, [
          %{format_slug: "lang-vff", score: 100, reject: false},
          %{format_slug: "lang-vfq", score: 0, reject: true}
        ])

      resolved = CustomFormats.resolve_for_profile(profile)
      assert length(resolved) == 2

      vff = Enum.find(resolved, &(&1.slug == "lang-vff"))
      assert vff.score == 100
      refute vff.reject
      assert Enum.all?(vff.patterns, &is_tuple/1)
    end

    test "omits assignments that are neither scored nor rejecting" do
      profile = quality_profile_fixture()

      :ok =
        CustomFormats.set_assignments(profile, [
          %{format_slug: "lang-vff", score: 0, reject: false}
        ])

      assert CustomFormats.resolve_for_profile(profile) == []
    end

    test "skips an assignment naming an unresolvable slug" do
      profile = quality_profile_fixture()

      :ok =
        CustomFormats.set_assignments(profile, [
          %{format_slug: "lang-vff", score: 100, reject: false},
          %{format_slug: "removed-in-a-later-release", score: 50, reject: false}
        ])

      resolved = CustomFormats.resolve_for_profile(profile)
      assert [%{slug: "lang-vff"}] = resolved
    end

    test "deleting a profile removes its assignments" do
      profile = quality_profile_fixture()

      :ok =
        CustomFormats.set_assignments(profile, [
          %{format_slug: "lang-vff", score: 100, reject: false}
        ])

      {:ok, _} = Mydia.Settings.delete_quality_profile(profile)
      assert CustomFormats.list_assignments(profile) == []
    end
  end
end
