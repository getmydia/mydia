defmodule MydiaWeb.AdminImportListsLive.LabelsTest do
  use ExUnit.Case, async: true

  alias Mydia.ImportLists.ImportList
  alias MydiaWeb.AdminImportListsLive.Labels

  setup do
    Gettext.put_locale(MydiaWeb.Gettext, "en")
    :ok
  end

  test "type_label matches the domain for every type, and for an unknown one" do
    for type <- ImportList.valid_types() ++ ["not_a_type"] do
      assert Labels.type_label(type) == ImportList.type_label(type)
    end
  end

  test "sync_interval_label matches the domain for every interval, and for an unknown one" do
    for minutes <- ImportList.valid_sync_intervals() ++ [5] do
      assert Labels.sync_interval_label(minutes) == ImportList.sync_interval_label(minutes)
    end
  end

  test "config field text matches the domain" do
    for type <- ImportList.valid_types() ++ ["not_a_type"] do
      assert Labels.config_field_label(type) == ImportList.config_field_label(type)

      assert Labels.config_field_placeholder(type) ==
               ImportList.config_field_placeholder(type)
    end
  end
end
