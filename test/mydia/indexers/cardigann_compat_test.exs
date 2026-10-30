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
        method: oneurl
        path: /login
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
      assert :login_method_other in result.missing_features
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

  describe "login scoring" do
    @base """
    id: invented-tracker
    name: Invented Tracker
    type: private
    links: [https://tracker.example/]
    caps: {categorymappings: [{id: 1, cat: Movies}], modes: {search: [q]}}
    search: {paths: [{path: b.php}], rows: {selector: tr}, fields: {title: {selector: td}}}
    """

    test "scores the login method, 2FA and headers as supported" do
      yaml =
        @base <>
          """
          login:
            method: form
            path: login.php
            headers: {X-Test: [a]}
            inputs: {otp: "{{ .Config.2facode }}"}
          """

      result = CardigannCompat.analyze_definition(yaml, "invented.yml")

      assert :login_method_form in result.required_features
      assert :login_2fa in result.required_features
      assert :login_headers in result.required_features
      assert result.status == :fully_supported
      assert result.login_method == "form"
    end

    for method <- ~w(cookie get post form) do
      test "the #{method} login method is supported" do
        yaml = @base <> "login: {method: #{unquote(method)}, path: login.php}\n"
        result = CardigannCompat.analyze_definition(yaml, "m.yml")

        assert String.to_existing_atom("login_method_" <> unquote(method)) in result.required_features
        assert result.missing_features == []
      end
    end

    test "getselectorinputs is detected" do
      yaml =
        @base <>
          """
          login:
            method: form
            path: login.php
            getselectorinputs: {token: {selector: "input#t", attribute: value}}
          """

      assert :login_getselectorinputs in CardigannCompat.analyze_definition(yaml, "g.yml").required_features
    end

    test "an unknown login method is reported missing" do
      yaml = @base <> "login: {method: oneurl, path: x}\n"
      result = CardigannCompat.analyze_definition(yaml, "odd.yml")

      assert :login_method_other in result.missing_features
      assert result.status == :partially_supported
    end

    test "a definition without login has no login method" do
      result = CardigannCompat.analyze_definition(@base, "pub.yml")
      assert result.login_method == "none"
    end

    test "build_report counts definitions per login method" do
      results =
        for {yaml, name} <- [
              {@base, "a.yml"},
              {@base <> "login: {method: form, path: x}\n", "b.yml"},
              {@base <> "login: {method: form, path: x}\n", "c.yml"},
              {@base <> "login: {method: oneurl, path: x}\n", "d.yml"}
            ] do
          CardigannCompat.analyze_definition(yaml, name)
        end

      assert CardigannCompat.build_report(results).by_login_method ==
               %{"none" => 1, "form" => 2, "oneurl" => 1}
    end

    test "build_report splits logins into supported and unsupported, and counts captcha and 2FA" do
      captcha = "  captcha: {type: image, selector: img, input: c}\n"
      twofa = "  inputs: {code: \"{{ .Config.2facode }}\"}\n"

      results =
        for {yaml, name} <- [
              {@base, "a.yml"},
              {@base <> "login:\n  method: form\n  path: x\n" <> captcha <> twofa, "b.yml"},
              {@base <> "login:\n  method: form\n  path: x\n" <> captcha, "c.yml"},
              {@base <> "login: {method: oneurl, path: x}\n", "d.yml"},
              # Only a form login stops for a person.
              {@base <> "login:\n  method: post\n  path: x\n" <> captcha, "e.yml"},
              {"not: valid: yaml: [", "f.yml"}
            ] do
          CardigannCompat.analyze_definition(yaml, name)
        end

      report = CardigannCompat.build_report(results)
      assert report.parse_failed == 1
      assert report.login_support == %{supported: 4, unsupported: 1}
      assert report.by_login_feature == %{login_captcha: 2, login_2fa: 1}
    end
  end
end
