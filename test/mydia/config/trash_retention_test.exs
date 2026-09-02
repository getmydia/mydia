defmodule Mydia.Config.TrashRetentionTest do
  @moduledoc """
  Retention lived only in config.exs, so changing how long trash is held
  needed a restart and an edit to a file most operators never see. It belongs
  in the yaml -> db -> env overlay with every other tunable.
  """
  use Mydia.DataCase, async: false

  alias Mydia.Config.Schema

  test "defaults to 30 days" do
    assert %{media: %{trash_retention_days: 30}} = Schema.defaults()
  end

  test "accepts a changed value" do
    changeset = Schema.changeset(%Schema{}, %{media: %{trash_retention_days: 7}})

    assert {:ok, config} = Ecto.Changeset.apply_action(changeset, :insert)
    assert config.media.trash_retention_days == 7
  end

  test "rejects a negative retention" do
    changeset = Schema.changeset(%Schema{}, %{media: %{trash_retention_days: -1}})

    refute changeset.valid?
  end

  test "zero is allowed and means purge on the next run" do
    changeset = Schema.changeset(%Schema{}, %{media: %{trash_retention_days: 0}})

    assert changeset.valid?
  end

  # validate_number/3 skips nil, so an explicit null would load cleanly and
  # only fail a day later inside TrashCleanup, where the retention reaches
  # DateTime.add/3 as `-nil`.
  test "rejects an explicit null rather than letting the cleanup job crash on it" do
    changeset = Schema.changeset(%Schema{}, %{media: %{trash_retention_days: nil}})

    refute changeset.valid?
  end
end
