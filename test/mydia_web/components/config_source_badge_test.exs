defmodule MydiaWeb.ConfigSourceBadgeTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias MydiaWeb.AdminComponents

  test "names each source" do
    assert render_component(&AdminComponents.config_source_badge/1, source: :env) =~ "ENV"
    assert render_component(&AdminComponents.config_source_badge/1, source: :database) =~ "DB"
    assert render_component(&AdminComponents.config_source_badge/1, source: :yaml) =~ "YAML"
    assert render_component(&AdminComponents.config_source_badge/1, source: :default) =~ "Default"
  end

  test "renders small by default and extra small on request" do
    assert render_component(&AdminComponents.config_source_badge/1, source: :env) =~ "badge-sm"

    assert render_component(&AdminComponents.config_source_badge/1, source: :env, size: "xs") =~
             "badge-xs"
  end
end
