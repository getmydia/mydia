defmodule Mydia.Indexers.Cardigann.EngineSupport do
  @moduledoc """
  Which engines each Cardigann definition was verified on: in the benchmark
  (`mix mydia.cardigann_bench`), the engine returned results and agreed with
  Prowlarr's on every query. A definition Prowlarr itself returned nothing for
  is not listed. Not listed means "not verified", not "broken".

  Refreshing it is manual: run the bench, paste the map printed at the end of
  its `bench.md` over `@verified`, update `@verified_on`, commit.
  """

  @verified_on ~D[2026-10-12]

  @verified %{
    "anibt" => [:builtin, :prowlarr],
    "animetosho-xyz" => [:builtin, :prowlarr],
    "bangumi-moe" => [:builtin, :prowlarr],
    "bigfangroup" => [:prowlarr],
    "blueroms" => [:prowlarr],
    "byrutor" => [:prowlarr],
    "catorrent" => [:builtin, :prowlarr],
    "crackingpatching" => [:prowlarr],
    "dmhy" => [:builtin, :prowlarr],
    "ehentai" => [:prowlarr],
    "freejavtorrent" => [:builtin, :prowlarr],
    "internetarchive" => [:builtin, :prowlarr],
    "limetorrents" => [:builtin, :prowlarr],
    "linuxtracker" => [:builtin, :prowlarr],
    "mikan" => [:builtin, :prowlarr],
    "mixtapetorrent" => [:prowlarr],
    "mypornclub" => [:prowlarr],
    "nekobt" => [:builtin, :prowlarr],
    "noname-club" => [:prowlarr],
    "nyaasi" => [:prowlarr],
    "onejav" => [:prowlarr],
    "opensharing" => [:builtin, :prowlarr],
    "pandacd" => [:prowlarr],
    "pctorrent" => [:builtin, :prowlarr],
    "plugintorrent" => [:builtin, :prowlarr],
    "pornotorrent" => [:builtin, :prowlarr],
    "pornxlab" => [:builtin, :prowlarr],
    "rintornet" => [:builtin, :prowlarr],
    "rutor" => [:prowlarr],
    "shanaproject" => [:prowlarr],
    "sosulki" => [:builtin, :prowlarr],
    "sukebeinyaasi" => [:builtin, :prowlarr],
    "thepiratebay" => [:builtin, :prowlarr],
    "torrent-pirat" => [:builtin, :prowlarr],
    "torrentdownload" => [:prowlarr],
    "torrentdownloads" => [:builtin, :prowlarr],
    "torrentkitty" => [:builtin, :prowlarr],
    "u3c3" => [:prowlarr],
    "vstorrent" => [:prowlarr],
    "vsttorrents" => [:builtin, :prowlarr],
    "world-torrent" => [:builtin, :prowlarr],
    "xxxtor" => [:builtin, :prowlarr],
    "yts" => [:builtin, :prowlarr],
    "zamundalife" => [:builtin, :prowlarr]
  }

  @type engine :: :builtin | :prowlarr

  @spec verified_engines(String.t()) :: [engine()]
  def verified_engines(definition_id), do: Map.get(@verified, definition_id, [])

  @spec verified_on() :: Date.t()
  def verified_on, do: @verified_on

  @doc """
  How `definition_id` stands on `active`: verified there, verified only on the
  other engine, or not verified at all.
  """
  @spec verification(String.t(), engine()) :: :verified | {:other_only, engine()} | :unverified
  def verification(definition_id, active) do
    case verified_engines(definition_id) do
      [] -> :unverified
      engines -> if active in engines, do: :verified, else: {:other_only, hd(engines)}
    end
  end

  @doc "The ids verified on `engine` and not on the other one."
  @spec only_on(engine(), [String.t()]) :: [String.t()]
  def only_on(engine, ids), do: Enum.filter(ids, &(verified_engines(&1) == [engine]))
end
