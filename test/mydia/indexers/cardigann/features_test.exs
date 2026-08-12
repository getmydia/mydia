defmodule Mydia.Indexers.Cardigann.FeaturesTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.Cardigann.Features

  test "supported/0 lists implemented features" do
    supported = Features.supported()

    for feature <- [
          :field_selector,
          :field_attribute,
          :field_text,
          :field_optional,
          :field_remove,
          :field_default,
          :field_case,
          :rows_after,
          :rows_count,
          :response_html,
          :response_json,
          :response_xml,
          :keywordsfilters,
          :allow_empty_inputs,
          :download_selectors,
          :download_infohash,
          :download_before,
          :legacylinks
        ] do
      assert feature in supported, "expected #{feature} to be registered as supported"
    end
  end

  test "supported/0 does not claim login features" do
    refute :login_captcha in Features.supported()
    refute :login_selectorinputs in Features.supported()
  end

  test "required/1 detects features from a definition map" do
    yaml = %{
      "legacylinks" => ["https://old.example.com"],
      "download" => %{"selectors" => [%{"selector" => "a"}]},
      "search" => %{
        "keywordsfilters" => [%{"name" => "trim"}],
        "rows" => %{"selector" => "tr", "after" => 1},
        "fields" => %{"title" => %{"selector" => "td", "case" => %{"*" => "x"}}}
      }
    }

    required = Features.required(yaml)

    assert :legacylinks in required
    assert :download_selectors in required
    assert :keywordsfilters in required
    assert :rows_after in required
    assert :field_case in required
    refute :download_infohash in required
  end

  test "required/1 detects login features it does not support" do
    yaml = %{"login" => %{"method" => "form", "captcha" => %{"type" => "image"}}, "search" => %{}}
    assert :login_captcha in Features.required(yaml)
  end
end
