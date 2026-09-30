defmodule Mydia.Metadata.Structs.WatchProviderTest do
  use ExUnit.Case, async: true

  alias Mydia.Metadata.Structs.WatchProvider

  test "prefers the region's display priority" do
    wp =
      WatchProvider.from_api(
        %{
          "provider_id" => 7,
          "provider_name" => "Maplestream",
          "logo_path" => "/m.png",
          "display_priority" => 9,
          "display_priorities" => %{"CA" => 2}
        },
        "CA"
      )

    assert %WatchProvider{id: 7, name: "Maplestream", logo_path: "/m.png", display_priority: 2} =
             wp
  end

  test "falls back to the global priority" do
    wp =
      WatchProvider.from_api(
        %{"provider_id" => 7, "provider_name" => "Maplestream", "display_priority" => 9},
        "CA"
      )

    assert wp.display_priority == 9
  end

  test "rejects entries without an id or name" do
    assert WatchProvider.from_api(%{"provider_name" => "Maplestream"}, "CA") == nil
    assert WatchProvider.from_api(%{"provider_id" => 7, "provider_name" => ""}, "CA") == nil
  end
end
