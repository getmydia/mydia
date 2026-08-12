defmodule Mydia.Indexers.CardigannCompatTest do
  use ExUnit.Case, async: true

  alias Mydia.Indexers.CardigannCompat

  describe "analyze_definition/2" do
    test "reports required and unsupported features" do
      yaml = """
      id: partial
      name: Partial
      description: d
      language: en-US
      type: private
      encoding: UTF-8
      links:
        - https://example.com/
      caps:
        categories:
          2000: Movies
      settings: []
      login:
        method: form
        path: /login
        captcha:
          type: image
          selector: img#cap
      search:
        paths:
          - path: /search
        rows:
          selector: tr
        fields:
          title:
            selector: td.title
          download:
            selector: a
            attribute: href
      """

      result = CardigannCompat.analyze_definition(yaml, "partial.yml")

      assert result.status == :partially_supported
      assert :login_captcha in result.missing_features
      assert :field_selector in result.required_features
    end

    test "reports a fully supported definition" do
      yaml = """
      id: full
      name: Full
      description: d
      language: en-US
      type: public
      encoding: UTF-8
      links:
        - https://example.com/
      caps:
        categories:
          2000: Movies
      settings: []
      search:
        paths:
          - path: /search
        rows:
          selector: tr
          after: 1
        fields:
          title:
            selector: td.title
          download:
            selector: a
            attribute: href
      """

      result = CardigannCompat.analyze_definition(yaml, "full.yml")

      assert result.status == :fully_supported
      assert result.missing_features == []
    end

    test "reports parse_failed for invalid YAML" do
      result = CardigannCompat.analyze_definition("not: valid: yaml: [", "broken.yml")

      assert result.status == :parse_failed
      assert result.error != nil
    end

    test "reports parse_failed for YAML missing required fields" do
      yaml = """
      id: test
      name: Test
      """

      result = CardigannCompat.analyze_definition(yaml, "incomplete.yml")

      assert result.status == :parse_failed
      assert result.error != nil
    end
  end
end
