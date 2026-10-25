defmodule MydiaWeb.ActivityLive.EventTextTest do
  use ExUnit.Case, async: true

  alias Mydia.Events.Event
  alias Mydia.Events.Presentation
  alias MydiaWeb.ActivityLive.EventText

  setup do
    Gettext.put_locale(MydiaWeb.Gettext, "en")
    :ok
  end

  defp event(type), do: %Event{type: type, severity: :info, metadata: %{}}

  test "title matches the domain title for every registered type" do
    for type <- Presentation.known_types() do
      assert EventText.title(event(type)) == Presentation.for_event(event(type)).title
    end
  end

  test "an unregistered type keeps the domain's humanized fallback" do
    event = event("legacy.something_old")

    assert EventText.title(event) == "Legacy something old"
  end

  test "field_label matches the domain for known, unknown, atom and malformed fields" do
    known = ~w(title original_title year monitored monitor_new_seasons category
               category_override tmdb_id tvdb_id overview poster backdrop tagline rating
               runtime genres cast crew)

    for field <- known ++ ["brand_new_field", :tmdb_id, :other_atom, nil, 42] do
      assert EventText.field_label(field) == Presentation.field_label(field)
    end
  end

  test "no_detail is the timeline's English fallback" do
    assert EventText.no_detail() == "Event occurred"
  end
end
