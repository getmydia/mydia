defmodule MydiaWeb.MediaLive.Show.FixMatchEventsTest do
  use Mydia.DataCase, async: false

  import Mydia.AccountsFixtures
  import Mydia.MediaFixtures

  alias Mydia.Accounts.Scope
  alias Mydia.Metadata.Structs.SearchResult
  alias MydiaWeb.MediaLive.Show.FixMatchEvents

  defp socket(item) do
    user = user_fixture()

    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        flash: %{},
        current_user: user,
        current_scope: Scope.for_user(user),
        media_item: item,
        fix_match: nil
      },
      private: %{live_temp: %{}}
    }
  end

  defp result(id, title),
    do: %SearchResult{
      provider_id: to_string(id),
      provider: :metadata_relay,
      media_type: :movie,
      title: title,
      year: 2003
    }

  test "search results land on the search step", _ do
    item = media_item_fixture(%{type: "movie", title: "Wrong Pick", tmdb_id: 41})
    {:noreply, s} = FixMatchEvents.open(%{}, socket(item))

    {:noreply, s} =
      FixMatchEvents.handle_search_async({:ok, {:ok, [result(42, "Velvet Comet")]}}, s)

    assert %{step: :search, searching?: false, results: [%{provider_id: "42"}]} =
             s.assigns.fix_match
  end

  test "the current match cannot be picked", _ do
    item = media_item_fixture(%{type: "movie", title: "Wrong Pick", tmdb_id: 43})
    {:noreply, s} = FixMatchEvents.open(%{}, socket(item))

    {:noreply, s} =
      FixMatchEvents.handle_search_async({:ok, {:ok, [result(43, "Wrong Pick")]}}, s)

    {:noreply, s} = FixMatchEvents.pick(%{"provider_id" => "43"}, s)
    assert s.assigns.fix_match.step == :search
  end

  test "picking another result moves to the confirm step", _ do
    item = media_item_fixture(%{type: "movie", title: "Wrong Pick", tmdb_id: 44})
    {:noreply, s} = FixMatchEvents.open(%{}, socket(item))

    {:noreply, s} =
      FixMatchEvents.handle_search_async({:ok, {:ok, [result(45, "Velvet Comet")]}}, s)

    {:noreply, s} = FixMatchEvents.pick(%{"provider_id" => "45"}, s)
    assert %{step: :confirm, picked: %{provider_id: "45"}} = s.assigns.fix_match
  end

  describe "after the modal closed" do
    setup do
      %{socket: socket(media_item_fixture(%{type: "movie", title: "Wrong Pick", tmdb_id: 50}))}
    end

    test "a late search result is ignored", %{socket: s} do
      {:noreply, s} =
        FixMatchEvents.handle_search_async({:ok, {:ok, [result(51, "Velvet Comet")]}}, s)

      assert s.assigns.fix_match == nil
    end

    test "a late search error is ignored", %{socket: s} do
      {:noreply, s} = FixMatchEvents.handle_search_async({:ok, {:error, :boom}}, s)
      assert s.assigns.fix_match == nil
    end

    test "a late search crash is ignored", %{socket: s} do
      {:noreply, s} = FixMatchEvents.handle_search_async({:exit, :boom}, s)
      assert s.assigns.fix_match == nil
    end

    test "pick, back and search are no-ops", %{socket: s} do
      {:noreply, s} = FixMatchEvents.pick(%{"provider_id" => "51"}, s)
      {:noreply, s} = FixMatchEvents.back(%{}, s)

      {:noreply, s} =
        FixMatchEvents.search(%{"fix_match" => %{"query" => "Velvet", "year" => ""}}, s)

      assert s.assigns.fix_match == nil
    end
  end

  test "an empty query does not start a search", _ do
    item = media_item_fixture(%{type: "movie", title: "Wrong Pick", tmdb_id: 52})
    {:noreply, s} = FixMatchEvents.open(%{}, socket(item))

    {:noreply, s} = FixMatchEvents.search(%{"fix_match" => %{"query" => "  ", "year" => ""}}, s)
    assert s.assigns.fix_match.searching? == false

    {:noreply, s} = FixMatchEvents.search(%{"unexpected" => "payload"}, s)
    assert s.assigns.fix_match.searching? == false
  end

  test "a collision closes the modal and says where the title already is", _ do
    item = media_item_fixture(%{type: "movie", title: "Wrong Pick", tmdb_id: 46})
    other = media_item_fixture(%{type: "movie", title: "Velvet Comet", tmdb_id: 47})
    {:noreply, s} = FixMatchEvents.open(%{}, socket(item))

    {:noreply, s} =
      FixMatchEvents.handle_adopt_async({:ok, {:error, {:already_in_library, other}}}, s)

    assert s.assigns.fix_match == nil
    assert s.assigns.flash["error"] =~ "Velvet Comet is already in your library"
  end
end
