defmodule MydiaWeb.Live.Helpers.DetailModalTest do
  @moduledoc """
  The two pure functions behind the detail dialog's host state.

  `find_selectable_item/2` decides whether a poster click resolves to anything
  at all, and `refresh_selected/2` decides whether the dialog's header still
  offers "Add to Library" for a title the user just added. Both fail silently
  in the UI, which is why they get direct tests rather than only being covered
  through a LiveView.
  """

  use ExUnit.Case, async: true

  alias MydiaWeb.Live.Helpers.DetailModal

  defp result(provider_id, title \\ nil) do
    %{provider_id: provider_id, title: title || "Title #{provider_id}"}
  end

  describe "find_selectable_item/2" do
    test "finds an item in the first list" do
      assert %{provider_id: "2"} =
               DetailModal.find_selectable_item([[result("1"), result("2")], []], "2")
    end

    test "finds an item that exists only in a later list" do
      assert %{provider_id: "101"} =
               DetailModal.find_selectable_item([[], [result("101")]], "101")
    end

    test "prefers the earlier list when both carry the id" do
      assert %{title: "From grid"} =
               DetailModal.find_selectable_item(
                 [[result("5", "From grid")], [result("5", "From rail")]],
                 "5"
               )
    end

    test "compares ids as strings on both sides" do
      assert %{provider_id: 7} = DetailModal.find_selectable_item([[result(7)]], "7")
    end

    test "returns nil for an unknown id" do
      assert is_nil(DetailModal.find_selectable_item([[result("1")], [result("2")]], "999"))
    end

    test "returns nil for no lists at all" do
      assert is_nil(DetailModal.find_selectable_item([], "1"))
    end
  end

  describe "refresh_selected/2" do
    defp socket(selected_item) do
      %Phoenix.LiveView.Socket{assigns: %{selected_item: selected_item, __changed__: %{}}}
    end

    test "swaps in the refreshed copy of the selected item" do
      stale = %{provider_id: "5", in_library: false}
      fresh = %{provider_id: "5", in_library: true}

      refreshed = DetailModal.refresh_selected(socket(stale), [[fresh]])

      assert refreshed.assigns.selected_item.in_library
    end

    test "leaves the selection alone when the id is in none of the lists" do
      stale = %{provider_id: "5", in_library: false}

      refreshed = DetailModal.refresh_selected(socket(stale), [[%{provider_id: "9"}]])

      assert refreshed.assigns.selected_item == stale
    end

    test "is a no-op with no dialog open" do
      refreshed = DetailModal.refresh_selected(socket(nil), [[%{provider_id: "5"}]])

      assert is_nil(refreshed.assigns.selected_item)
    end
  end
end
