defmodule MydiaWeb.MediaLive.Show.DetailModalEventsTest do
  use Mydia.DataCase, async: true

  alias Mydia.Accounts.Scope
  alias Mydia.Metadata.Structs.SearchResult
  alias MydiaWeb.MediaLive.Show.DetailModalEvents

  defp selected(id, media_type) do
    %SearchResult{provider: :tmdb, provider_id: to_string(id), media_type: media_type}
  end

  defp socket(selected_item) do
    %Phoenix.LiveView.Socket{
      assigns: %{
        __changed__: %{},
        current_scope: Scope.unrestricted(),
        selected_item: selected_item,
        selected_recommendations: []
      }
    }
  end

  defp rec(id),
    do: %SearchResult{
      provider: :tmdb,
      provider_id: to_string(id),
      media_type: nil,
      title: "Rec #{id}"
    }

  describe "handle_recommendations_result/4" do
    test "a result for the selected title is stored and stamped with its type" do
      {:noreply, socket} =
        DetailModalEvents.handle_recommendations_result(
          {:tmdb, 5},
          :tv_show,
          {:ok, {:ok, [rec(9)]}},
          socket(selected(5, :tv_show))
        )

      assert [%{provider_id: "9", media_type: :tv_show}] = socket.assigns.selected_recommendations
    end

    test "a movie's result landing after a same-id show was selected is dropped" do
      {:noreply, socket} =
        DetailModalEvents.handle_recommendations_result(
          {:tmdb, 5},
          :movie,
          {:ok, {:ok, [rec(9)]}},
          socket(selected(5, :tv_show))
        )

      assert socket.assigns.selected_recommendations == []
    end

    test "a result after the dialog closed is dropped" do
      {:noreply, socket} =
        DetailModalEvents.handle_recommendations_result(
          {:tmdb, 5},
          :movie,
          {:ok, {:ok, [rec(9)]}},
          socket(nil)
        )

      assert socket.assigns.selected_recommendations == []
    end
  end
end
