defmodule Mydia.Events.PresentationTest do
  use ExUnit.Case, async: true

  alias Mydia.Events.Event
  alias Mydia.Events.Presentation

  defp event(attrs) do
    struct!(%Event{severity: :info, metadata: %{}}, attrs)
  end

  describe "known_types/0" do
    test "covers all 32 event types" do
      assert length(Presentation.known_types()) == 32
    end

    test "has no duplicate entries" do
      types = Presentation.known_types()
      assert types == Enum.uniq(types)
    end

    test "includes the type that triggered this work" do
      assert "download.stalled" in Presentation.known_types()
    end
  end

  describe "feed_hidden_types/0" do
    test "hides the per-request plugin audit trail" do
      assert Presentation.feed_hidden_types() == ["plugin.http_request"]
    end
  end

  describe "for_event/1 registered types" do
    test "every registered type resolves to a usable title and icon" do
      for type <- Presentation.known_types() do
        presentation = Presentation.for_event(event(type: type))

        assert is_binary(presentation.title) and presentation.title != "",
               "#{type} has no title"

        assert String.starts_with?(presentation.icon, "hero-"),
               "#{type} has icon #{inspect(presentation.icon)}"

        assert is_binary(presentation.color) and presentation.color != "",
               "#{type} resolved to no color"
      end
    end

    test "no title leaks a raw event key" do
      for type <- Presentation.known_types() do
        presentation = Presentation.for_event(event(type: type))
        refute presentation.title =~ ".", "#{type} title looks like a raw key"
      end
    end
  end

  describe "for_event/1 unknown types" do
    test "humanizes the raw key into a readable title" do
      presentation = Presentation.for_event(event(type: "legacy.retired_thing"))
      assert presentation.title == "Legacy retired thing"
    end

    test "derives icon and color from severity" do
      assert %{icon: "hero-exclamation-circle", color: "text-error"} =
               Presentation.for_event(event(type: "legacy.gone", severity: :error))

      assert %{icon: "hero-exclamation-triangle", color: "text-warning"} =
               Presentation.for_event(event(type: "legacy.gone", severity: :warning))

      assert %{icon: "hero-information-circle", color: "text-info"} =
               Presentation.for_event(event(type: "legacy.gone", severity: :info))
    end
  end

  describe "detail/1 fallback" do
    test "falls back to the metadata title" do
      assert Presentation.detail(event(type: "legacy.gone", metadata: %{"title" => "Arrival"})) ==
               "Arrival"
    end

    test "falls back to the metadata description" do
      assert Presentation.detail(
               event(type: "legacy.gone", metadata: %{"description" => "something happened"})
             ) == "something happened"
    end

    test "returns nil when metadata carries nothing usable" do
      assert Presentation.detail(event(type: "legacy.gone", metadata: %{})) == nil
    end
  end
end
