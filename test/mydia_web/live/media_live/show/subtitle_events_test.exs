defmodule MydiaWeb.MediaLive.Show.SubtitleEventsTest do
  use MydiaWeb.ConnCase, async: true

  alias MydiaWeb.MediaLive.Show.SubtitleEvents

  defp socket(assigns \\ %{}) do
    %Phoenix.LiveView.Socket{
      assigns: Map.merge(%{__changed__: %{}, selected_languages: ["en"]}, assigns)
    }
  end

  describe "update_subtitle_languages/2" do
    test "stores the submitted selection" do
      {:noreply, socket} =
        SubtitleEvents.update_subtitle_languages(%{"languages" => ["en", "fr"]}, socket())

      assert socket.assigns.selected_languages == ["en", "fr"]
    end

    test "treats a payload with no languages key as an empty selection" do
      # Unchecking every daisyUI chip omits the key entirely rather than
      # sending an empty list, which used to raise FunctionClauseError.
      {:noreply, socket} = SubtitleEvents.update_subtitle_languages(%{}, socket())

      assert socket.assigns.selected_languages == []
    end
  end

  describe "clear_subtitle_languages/2" do
    test "empties the selection" do
      {:noreply, socket} =
        SubtitleEvents.clear_subtitle_languages(%{}, socket(%{selected_languages: ["en", "fr"]}))

      assert socket.assigns.selected_languages == []
    end
  end
end
