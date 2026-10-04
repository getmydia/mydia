defmodule MydiaWeb.AdminPluginsLive.CapabilitySummary do
  @moduledoc """
  Turns a plugin capability set into the grouped, plain-language summary the
  admin reads when approving or reviewing a plugin.

  Every label is **host-owned**: it comes from the tables below, keyed by
  capability class and value, never from manifest free text (KTD6). The value
  vocabularies are closed sets validated by `Mydia.Plugins.Manifest`, and
  `capability_summary_test.exs` fails if one of them gains a value with no label
  here. A value that slips through anyway renders as its raw string rather than
  vanishing from consent.

  The single exception is a host-granting settings field: its Talks to line
  names the field by its own manifest label, so the operator can tell which
  setting grants the host. The surrounding sentence ("The server you enter in
  ...") stays host-authored, and the admin plugins UI already showed this label.

  Groups are fixed and appear in `@groups` order; an empty group is omitted.
  Background mechanics (events, schedule, storage) go to the `also` footer.
  """

  alias Mydia.Plugins.Manifest
  alias MydiaWeb.AdminPluginsLive.CapabilitySummary.{Group, Line}

  defstruct groups: [], also: []

  @type t :: %__MODULE__{groups: [Group.t()], also: [Line.t()]}

  # {key, title, emphasized?}. Only Talks to is emphasized: it is the one group
  # whose data leaves Mydia.
  @groups [
    {:talks_to, "Talks to", true},
    {:can_see, "Can see", false},
    {:can_change, "Can change", false},
    {:adds, "Adds to Mydia", false}
  ]

  @data_labels %{
    "media_item" => "Media items",
    "playback_progress" => "Watch progress",
    "library_item" => "Library items",
    "media_request" => "Requests",
    "download" => "Downloads",
    "collection" => "Collections",
    "watch_history" => "Watch history"
  }

  @surface_labels %{
    "playback:watched" => "Mark items watched",
    "collections:favorite" => "Favorite items",
    "media:add" => "Add media",
    "collections:write" => "Edit collections"
  }

  @event_phrases %{
    "media_item.added" => "new titles",
    "media_item.updated" => "title updates",
    "media_item.removed" => "removed titles",
    "media_file.imported" => "new imports",
    "download.completed" => "finished downloads",
    "download.failed" => "failed downloads",
    "playback.started" => "playback starting",
    "playback.progressed" => "playback progress",
    "playback.paused" => "paused playback",
    "playback.finished" => "finished playback",
    "playback.unwatched" => "items marked unwatched"
  }

  @doc """
  Builds the summary for `capabilities` (`%{class => values}`).

  Options:
    * `:new` - a capability set (as returned by `Mydia.Plugins.Capabilities.ungranted/2`)
      whose values are marked `new?`.
    * `:settings_schema` - the manifest settings schema; each host-granting url
      field adds a Talks to line.
  """
  @spec build(map(), keyword()) :: t()
  def build(capabilities, opts \\ []) do
    new = Keyword.get(opts, :new, %{})

    entries =
      capability_entries(capabilities, new) ++
        host_field_entries(Keyword.get(opts, :settings_schema, []))

    groups =
      Enum.flat_map(@groups, fn {key, title, emphasized?} ->
        case for({^key, line} <- entries, do: line) do
          [] -> []
          lines -> [%Group{key: key, title: title, emphasized?: emphasized?, lines: lines}]
        end
      end)

    %__MODULE__{groups: groups, also: for({:also, line} <- entries, do: line)}
  end

  @doc "Number of lines (group and footer) marked new."
  @spec new_count(t()) :: non_neg_integer()
  def new_count(%__MODULE__{} = summary) do
    summary.groups
    |> Enum.flat_map(& &1.lines)
    |> Kernel.++(summary.also)
    |> Enum.count(& &1.new?)
  end

  @doc "Every line label of `capabilities`, groups first then footer, for one-line summaries."
  @spec flat_labels(map()) :: [String.t()]
  def flat_labels(capabilities) do
    summary = build(capabilities)
    Enum.map(Enum.flat_map(summary.groups, & &1.lines) ++ summary.also, & &1.label)
  end

  @doc "Host-owned label for a `data:read` namespace."
  @spec data_label(String.t()) :: String.t()
  def data_label(namespace), do: Map.get(@data_labels, namespace, namespace)

  @doc "Host-owned label for a `surfaces:write` surface."
  @spec surface_label(String.t()) :: String.t()
  def surface_label(surface), do: Map.get(@surface_labels, surface, surface)

  @doc "Host-owned noun phrase for a subscribed event (\"reacts to <phrase>\")."
  @spec event_phrase(String.t()) :: String.t()
  def event_phrase(event), do: Map.get(@event_phrases, event, event)

  # Sorted by class so lines inside a group have a stable order.
  defp capability_entries(capabilities, new) do
    capabilities
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.flat_map(fn {class, payload} ->
      entries_for(class, values(payload), Map.get(new, class))
    end)
  end

  # `new_values` is nil when nothing in the class is new, or the list of new
  # values (`[]` for a newly requested flag class).
  defp entries_for("net:http", hosts, new_values),
    do: per_value(:talks_to, hosts, new_values, & &1)

  defp entries_for("net:private", hosts, new_values),
    do: per_value(:talks_to, hosts, new_values, &"#{&1} (private network)")

  defp entries_for("data:read", namespaces, new_values),
    do: per_value(:can_see, namespaces, new_values, &data_label/1)

  defp entries_for("data:search", _, new_values),
    do: flag(:can_see, "Search your library as the person using it", new_values)

  defp entries_for("users:connections", _, new_values),
    do: flag(:can_see, "Accounts people link to it", new_values)

  defp entries_for("surfaces:write", surfaces, new_values),
    do: per_value(:can_change, surfaces, new_values, &surface_label/1)

  defp entries_for("surfaces:page", _, new_values),
    do: flag(:adds, "Its own page", new_values)

  defp entries_for("surfaces:shelf", _, new_values),
    do: flag(:adds, "Suggestions on each person's Home page", new_values)

  defp entries_for("events:subscribe", events, new_values),
    do: flag(:also, "reacts to " <> join_and(Enum.map(events, &event_phrase/1)), new_values)

  defp entries_for("schedule:interval", _, new_values),
    do: flag(:also, "runs on a schedule", new_values)

  defp entries_for("state:kv", _, new_values),
    do: flag(:also, "keeps its own storage", new_values)

  defp entries_for(class, values, new_values),
    do: flag(:also, Enum.join([class | values], " "), new_values)

  defp per_value(group, values, new_values, label_fun) do
    for value <- values do
      {group, %Line{label: label_fun.(value), new?: is_list(new_values) and value in new_values}}
    end
  end

  defp flag(group, label, new_values), do: [{group, %Line{label: label, new?: new_values != nil}}]

  defp host_field_entries(schema) do
    for field <- Manifest.host_granting_fields(schema) do
      {:talks_to, %Line{label: "The server you enter in #{field_name(field)}"}}
    end
  end

  defp field_name(field) do
    Enum.find_value(["label", "key"], "settings", fn name ->
      case Map.get(field, name) do
        value when is_binary(value) and value != "" -> value
        _ -> nil
      end
    end)
  end

  defp values(nil), do: []
  defp values(payload), do: payload |> List.wrap() |> Enum.map(&render_value/1)

  defp render_value(value) when is_binary(value), do: value
  defp render_value(value), do: inspect(value)

  defp join_and([]), do: ""
  defp join_and([one]), do: one

  defp join_and(list) do
    {init, [last]} = Enum.split(list, -1)
    Enum.join(init, ", ") <> " and " <> last
  end
end
