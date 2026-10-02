defmodule Mydia.Plugins.ShelfManifestTest do
  use ExUnit.Case, async: true

  alias Mydia.Plugins
  alias Mydia.Plugins.Error
  alias Mydia.Plugins.Manifest
  alias Mydia.Plugins.Plugin

  @shelf %{
    "key" => "picks",
    "title" => "Picked for you",
    "placement" => "home",
    "scope" => "user",
    "ttl_seconds" => 86_400,
    "refresh_on" => ["playback.finished"]
  }

  defp manifest(shelves, caps \\ %{"surfaces:shelf" => []}) do
    %{
      "slug" => "shelfy",
      "name" => "Shelfy",
      "version" => "1.0.0",
      "capabilities" => caps,
      "shelves" => shelves
    }
  end

  defp error(map) do
    assert {:error, %Error{type: :invalid_manifest, message: message}} = Manifest.parse(map)
    message
  end

  test "a shelf-only plugin parses" do
    assert {:ok, %Manifest{shelves: [shelf]}} = Manifest.parse(manifest([@shelf]))
    assert shelf == @shelf
  end

  test "refresh_on defaults to an empty list" do
    assert {:ok, %Manifest{shelves: [shelf]}} =
             Manifest.parse(manifest([Map.delete(@shelf, "refresh_on")]))

    assert shelf["refresh_on"] == []
  end

  test "shelves need the capability and the capability needs shelves" do
    assert error(manifest([@shelf], %{"events:subscribe" => ["media_item.added"]})) =~
             "surfaces:shelf"

    assert error(Map.delete(manifest([@shelf]), "shelves")) =~ "requires a shelves list"
    assert error(manifest([])) =~ "requires a shelves list"
  end

  test "placement, scope and events are closed sets" do
    assert error(manifest([%{@shelf | "placement" => "media_detail"}])) =~ "placement"
    assert error(manifest([%{@shelf | "scope" => "server"}])) =~ "scope"
    assert error(manifest([%{@shelf | "refresh_on" => ["download.exploded"]}])) =~ "refresh_on"
  end

  test "key, title and ttl are bounded" do
    assert error(manifest([%{@shelf | "key" => "Picks!"}])) =~ "key"
    assert error(manifest([%{@shelf | "title" => ""}])) =~ "title"
    assert error(manifest([%{@shelf | "title" => String.duplicate("x", 41)}])) =~ "title"
    assert error(manifest([%{@shelf | "ttl_seconds" => 60}])) =~ "ttl_seconds"
    assert error(manifest([%{@shelf | "ttl_seconds" => 2_592_001}])) =~ "ttl_seconds"
    assert error(manifest([%{@shelf | "ttl_seconds" => "daily"}])) =~ "ttl_seconds"
  end

  test "keys are unique and the list is capped" do
    assert error(manifest([@shelf, @shelf])) =~ "unique"

    many = for n <- 1..5, do: %{@shelf | "key" => "s#{n}"}
    assert error(manifest(many)) =~ "at most"
  end

  test "a plugin without shelves round-trips through manifest_to_map" do
    {:ok, plain} =
      Manifest.parse(%{
        "slug" => "plain",
        "name" => "Plain",
        "version" => "1.0.0",
        "capabilities" => %{"events:subscribe" => ["media_item.added"]}
      })

    assert plain.shelves == []
    assert {:ok, ^plain} = plain |> Plugins.manifest_to_map() |> Manifest.parse()
  end

  test "shelves survive manifest_to_map and reach the descriptor" do
    {:ok, parsed} = Manifest.parse(manifest([@shelf]))

    assert {:ok, ^parsed} = parsed |> Plugins.manifest_to_map() |> Manifest.parse()
    assert %Plugin{shelves: [@shelf]} = Plugin.from_manifest(parsed)
  end

  test "home is the only placement" do
    assert Manifest.shelf_placements() == ["home"]
  end
end
