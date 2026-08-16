defmodule Mydia.Indexers.CategoryMappingTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.CategoryMapping

  describe "categories_for_type/1" do
    test "returns movie categories for :movies type" do
      categories = CategoryMapping.categories_for_type(:movies)

      assert is_list(categories)
      assert 2000 in categories
      assert 2040 in categories
      assert 2045 in categories
      # Should not include TV or other types
      refute 5000 in categories
      refute 3000 in categories
    end

    test "returns TV categories for :series type" do
      categories = CategoryMapping.categories_for_type(:series)

      assert is_list(categories)
      assert 5000 in categories
      assert 5040 in categories
      assert 5070 in categories
      # Should not include movies
      refute 2000 in categories
    end

    test "returns combined movies and TV for :mixed type" do
      categories = CategoryMapping.categories_for_type(:mixed)
      movie_categories = CategoryMapping.categories_for_type(:movies)
      tv_categories = CategoryMapping.categories_for_type(:series)

      # Should include both movie and TV categories
      assert 2000 in categories
      assert 5000 in categories

      # Should be union of movies and series
      for cat <- movie_categories, do: assert(cat in categories)
      for cat <- tv_categories, do: assert(cat in categories)
    end

    test "returns empty list for unknown type" do
      assert CategoryMapping.categories_for_type(:unknown) == []
      assert CategoryMapping.categories_for_type(:invalid) == []
    end
  end

  describe "parent_category/1" do
    test "returns parent category ID for each library type" do
      assert CategoryMapping.parent_category(:movies) == 2000
      assert CategoryMapping.parent_category(:series) == 5000
    end

    test "returns nil for mixed type" do
      assert CategoryMapping.parent_category(:mixed) == nil
    end

    test "returns nil for unknown type" do
      assert CategoryMapping.parent_category(:unknown) == nil
    end
  end

  describe "category_name/1" do
    test "returns correct names for movie categories" do
      assert CategoryMapping.category_name(2000) == "Movies"
      assert CategoryMapping.category_name(2040) == "Movies/HD"
      assert CategoryMapping.category_name(2045) == "Movies/UHD"
    end

    test "returns correct names for TV categories" do
      assert CategoryMapping.category_name(5000) == "TV"
      assert CategoryMapping.category_name(5040) == "TV/HD"
      assert CategoryMapping.category_name(5070) == "TV/Anime"
    end

    test "returns correct names for audio categories" do
      assert CategoryMapping.category_name(3000) == "Audio"
      assert CategoryMapping.category_name(3010) == "Audio/MP3"
      assert CategoryMapping.category_name(3040) == "Audio/Lossless"
    end

    test "returns correct names for book categories" do
      assert CategoryMapping.category_name(7000) == "Books"
      assert CategoryMapping.category_name(7020) == "Books/EBook"
      assert CategoryMapping.category_name(7030) == "Books/Comics"
    end

    test "returns correct names for adult categories" do
      assert CategoryMapping.category_name(6000) == "XXX"
      assert CategoryMapping.category_name(6040) == "XXX/x264"
    end

    test "returns Unknown for unrecognized category IDs" do
      assert CategoryMapping.category_name(9999) == "Unknown (9999)"
    end
  end

  describe "category_matches_type?/2" do
    test "correctly identifies movie categories" do
      assert CategoryMapping.category_matches_type?(2000, :movies)
      assert CategoryMapping.category_matches_type?(2040, :movies)
      refute CategoryMapping.category_matches_type?(5000, :movies)
      refute CategoryMapping.category_matches_type?(3000, :movies)
    end

    test "correctly identifies TV categories" do
      assert CategoryMapping.category_matches_type?(5000, :series)
      assert CategoryMapping.category_matches_type?(5070, :series)
      refute CategoryMapping.category_matches_type?(2000, :series)
    end
  end

  describe "type_for_category/1" do
    test "returns correct type for category ranges" do
      # Movies: 2000-2999
      assert CategoryMapping.type_for_category(2000) == :movies
      assert CategoryMapping.type_for_category(2500) == :movies
      assert CategoryMapping.type_for_category(2999) == :movies

      # Audio: 3000-3999 (no longer a Mydia library type; falls through)
      assert CategoryMapping.type_for_category(3000) == :other
      assert CategoryMapping.type_for_category(3500) == :other

      # TV: 5000-5999
      assert CategoryMapping.type_for_category(5000) == :series
      assert CategoryMapping.type_for_category(5999) == :series

      # Adult: 6000-6999 (no longer a Mydia library type; falls through)
      assert CategoryMapping.type_for_category(6000) == :other
      assert CategoryMapping.type_for_category(6500) == :other

      # Books: 7000-7999 (no longer a Mydia library type; falls through)
      assert CategoryMapping.type_for_category(7000) == :other
      assert CategoryMapping.type_for_category(7999) == :other
    end

    test "returns :other for unknown ranges" do
      assert CategoryMapping.type_for_category(1000) == :other
      assert CategoryMapping.type_for_category(4000) == :other
      assert CategoryMapping.type_for_category(8000) == :other
      assert CategoryMapping.type_for_category(9000) == :other
    end
  end

  describe "all_categories/0" do
    test "returns list of all categories with metadata" do
      all = CategoryMapping.all_categories()

      assert is_list(all)
      assert all != []

      # Each entry should have id, name, and type
      for category <- all do
        assert is_map(category)
        assert is_integer(category.id)
        assert is_binary(category.name)
        assert is_atom(category.type)
      end
    end

    test "includes categories for all library types" do
      all = CategoryMapping.all_categories()
      types = Enum.map(all, & &1.type) |> Enum.uniq()

      assert :movies in types
      assert :series in types
      assert :other in types
    end
  end

  describe "category_id_from_name/1" do
    test "returns correct ID for movie categories" do
      assert CategoryMapping.category_id_from_name("Movies") == 2000
      assert CategoryMapping.category_id_from_name("Movies/HD") == 2040
      assert CategoryMapping.category_id_from_name("Movies/UHD") == 2045
      assert CategoryMapping.category_id_from_name("Movies/BluRay") == 2050
      assert CategoryMapping.category_id_from_name("Movies/SD") == 2030
    end

    test "returns correct ID for TV categories" do
      assert CategoryMapping.category_id_from_name("TV") == 5000
      assert CategoryMapping.category_id_from_name("TV/HD") == 5040
      assert CategoryMapping.category_id_from_name("TV/Anime") == 5070
      assert CategoryMapping.category_id_from_name("TV/Documentary") == 5080
      assert CategoryMapping.category_id_from_name("TV/SD") == 5030
    end

    test "returns correct ID for audio categories" do
      assert CategoryMapping.category_id_from_name("Audio") == 3000
      assert CategoryMapping.category_id_from_name("Audio/MP3") == 3010
      assert CategoryMapping.category_id_from_name("Audio/Lossless") == 3040
      assert CategoryMapping.category_id_from_name("Music") == 3000
      assert CategoryMapping.category_id_from_name("Music/Lossless") == 3040
    end

    test "returns correct ID for book categories" do
      assert CategoryMapping.category_id_from_name("Books") == 7000
      assert CategoryMapping.category_id_from_name("Books/EBook") == 7020
      assert CategoryMapping.category_id_from_name("Books/Comics") == 7030
    end

    test "returns correct ID for adult categories" do
      assert CategoryMapping.category_id_from_name("XXX") == 6000
      assert CategoryMapping.category_id_from_name("XXX/DVD") == 6010
      assert CategoryMapping.category_id_from_name("XXX/Video") == 6010
    end

    test "handles case-insensitive lookups" do
      assert CategoryMapping.category_id_from_name("movies/hd") == 2040
      assert CategoryMapping.category_id_from_name("MOVIES/HD") == 2040
      assert CategoryMapping.category_id_from_name("Movies/HD") == 2040
    end

    test "handles common 1337x category names" do
      # These are actual category names from 1337x definition
      assert CategoryMapping.category_id_from_name("Movies/Divx/Xvid") == 2030
      assert CategoryMapping.category_id_from_name("Movies/h.264/x264") == 2040
      assert CategoryMapping.category_id_from_name("Movies/HEVC/x265") == 2040
      assert CategoryMapping.category_id_from_name("TV/HEVC/x265") == 5040
      assert CategoryMapping.category_id_from_name("TV/Cartoons") == 5070
    end

    test "returns nil for unknown categories" do
      assert CategoryMapping.category_id_from_name("Unknown/Category") == nil
      assert CategoryMapping.category_id_from_name("NonExistent") == nil
    end

    test "returns nil for non-string input" do
      assert CategoryMapping.category_id_from_name(nil) == nil
      assert CategoryMapping.category_id_from_name(123) == nil
    end
  end

  describe "map_site_category_to_torznab/2" do
    test "maps site category ID to Torznab category using mappings" do
      # Example 1337x category mappings
      mappings = [
        %{"id" => 42, "cat" => "Movies/HD"},
        %{"id" => 1, "cat" => "Movies/DVD"},
        %{"id" => 5, "cat" => "TV"},
        %{"id" => 41, "cat" => "TV/HD"},
        %{"id" => 28, "cat" => "TV/Anime"}
      ]

      assert CategoryMapping.map_site_category_to_torznab("42", mappings) == 2040
      assert CategoryMapping.map_site_category_to_torznab("1", mappings) == 2070
      assert CategoryMapping.map_site_category_to_torznab("5", mappings) == 5000
      assert CategoryMapping.map_site_category_to_torznab("41", mappings) == 5040
      assert CategoryMapping.map_site_category_to_torznab("28", mappings) == 5070
    end

    test "handles integer site category IDs" do
      mappings = [%{"id" => 42, "cat" => "Movies/HD"}]

      assert CategoryMapping.map_site_category_to_torznab(42, mappings) == 2040
    end

    test "handles atom keys in mappings" do
      mappings = [%{id: 42, cat: "Movies/HD"}]

      assert CategoryMapping.map_site_category_to_torznab("42", mappings) == 2040
    end

    test "returns nil for unknown site category ID" do
      mappings = [%{"id" => 42, "cat" => "Movies/HD"}]

      assert CategoryMapping.map_site_category_to_torznab("999", mappings) == nil
    end

    test "returns nil for nil inputs" do
      mappings = [%{"id" => 42, "cat" => "Movies/HD"}]

      assert CategoryMapping.map_site_category_to_torznab(nil, mappings) == nil
      assert CategoryMapping.map_site_category_to_torznab("42", nil) == nil
    end

    test "returns nil for empty mappings" do
      assert CategoryMapping.map_site_category_to_torznab("42", []) == nil
    end

    test "handles real 1337x category mappings" do
      # Actual mappings from 1337x Cardigann definition
      mappings = [
        %{"id" => 28, "cat" => "TV/Anime", "desc" => "Anime/Anime"},
        %{"id" => 42, "cat" => "Movies/HD", "desc" => "Movies/HD"},
        %{"id" => 76, "cat" => "Movies/UHD", "desc" => "Movies/UHD"},
        %{"id" => 41, "cat" => "TV/HD", "desc" => "TV/HD"},
        %{"id" => 22, "cat" => "Audio/MP3", "desc" => "Music/MP3"},
        %{"id" => 23, "cat" => "Audio/Lossless", "desc" => "Music/Lossless"}
      ]

      assert CategoryMapping.map_site_category_to_torznab("28", mappings) == 5070
      assert CategoryMapping.map_site_category_to_torznab("42", mappings) == 2040
      assert CategoryMapping.map_site_category_to_torznab("76", mappings) == 2045
      assert CategoryMapping.map_site_category_to_torznab("41", mappings) == 5040
      assert CategoryMapping.map_site_category_to_torznab("22", mappings) == 3010
      assert CategoryMapping.map_site_category_to_torznab("23", mappings) == 3040
    end
  end
end
