defmodule MydiaWeb.MediaLive.ScanFlashTest do
  @moduledoc """
  Pins the scan-completed flash copy. `auto_linked` is a subset of the files a
  scan touched, not a fourth kind of change, so it must never enter the change
  total: a scan that found 3 new files and auto-imported 2 of them found 3
  things, not 5.
  """
  use ExUnit.Case, async: true

  alias MydiaWeb.MediaLive.Index

  test "reports nothing when a scan changed nothing" do
    assert Index.scan_completed_message(%{
             new_files: 0,
             modified_files: 0,
             deleted_files: 0,
             auto_linked: 0
           }) == "Library scan completed: No changes detected"
  end

  test "keeps today's copy for a scan that auto-imported nothing" do
    # The existing builder prepends, so the emitted order is removed, modified,
    # new. That is pre-existing behavior and this change must not alter it.
    assert Index.scan_completed_message(%{
             new_files: 3,
             modified_files: 1,
             deleted_files: 2,
             auto_linked: 0
           }) == "Library scan completed: 2 removed, 1 modified, 3 new"
  end

  test "appends the auto-imported count when auto-import linked something" do
    assert Index.scan_completed_message(%{
             new_files: 3,
             modified_files: 0,
             deleted_files: 0,
             auto_linked: 2
           }) == "Library scan completed: 3 new, 2 imported automatically"
  end

  test "omits the auto-imported clause entirely when nothing was auto-imported" do
    message =
      Index.scan_completed_message(%{
        new_files: 1,
        modified_files: 0,
        deleted_files: 0,
        auto_linked: 0
      })

    refute message =~ "automatically"
  end

  test "reports auto-imports even when no files were new or changed" do
    # The orphan branch links existing files, so a scan can auto-import
    # without any on-disk change at all. Reporting "No changes detected" here
    # would hide exactly the work the operator turned the flag on for.
    assert Index.scan_completed_message(%{
             new_files: 0,
             modified_files: 0,
             deleted_files: 0,
             auto_linked: 4
           }) == "Library scan completed: 4 imported automatically"
  end
end
