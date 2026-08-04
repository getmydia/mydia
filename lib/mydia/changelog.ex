defmodule Mydia.Changelog do
  @moduledoc """
  Release notes bundled into the image at compile time.

  Files live in `priv/changelog/<version>.md`, one per stable release, each
  describing only its own version's changes. They are read, parsed and rendered
  during compilation, so nothing here touches the filesystem or the network at
  runtime.

  Nothing in this module inspects the running build's version. What a user sees
  is a function of the bundled notes and the version they last saw, which makes
  development and prerelease builds behave correctly without a special case.
  """

  alias Mydia.Changelog.Entry

  @changelog_dir Path.expand("../../priv/changelog", __DIR__)

  @paths @changelog_dir |> Path.join("*.md") |> Path.wildcard() |> Enum.sort()

  for path <- @paths do
    @external_resource path
  end

  # The directory is tracked in addition to each file: a file ADDED after the
  # first compile is covered by no per-file resource, so without this the module
  # would not recompile and the new release's notes would silently vanish from
  # the build. A directory's mtime changes when an entry is added or removed.
  @external_resource @changelog_dir

  @entries @paths
           |> Enum.map(&Entry.from_file!/1)
           |> Enum.sort_by(& &1.version, {:desc, Version})

  @doc """
  Every bundled entry, newest first.
  """
  @spec entries() :: [Entry.t()]
  def entries, do: @entries

  @doc """
  The newest bundled version string, or `nil` when no notes are bundled.
  """
  @spec latest() :: String.t() | nil
  def latest do
    case @entries do
      [] -> nil
      [%Entry{version_string: version_string} | _] -> version_string
    end
  end

  @doc """
  Entries newer than `last_seen`, newest first.

  Returns `[]` for `nil` or an unparseable value, so callers never have to guard
  those cases themselves.
  """
  @spec unseen(String.t() | nil) :: [Entry.t()]
  def unseen(last_seen), do: unseen(@entries, last_seen)

  @doc """
  Pure form of `unseen/1` taking an explicit entry list.

  `unseen/1` delegates here with the bundled entries; tests can drive this
  directly with fixture entries instead.
  """
  @spec unseen([Entry.t()], String.t() | nil) :: [Entry.t()]
  def unseen(entries, last_seen) when is_binary(last_seen) do
    case Version.parse(last_seen) do
      {:ok, version} ->
        Enum.filter(entries, &(Version.compare(&1.version, version) == :gt))

      :error ->
        []
    end
  end

  def unseen(_entries, _last_seen), do: []
end
