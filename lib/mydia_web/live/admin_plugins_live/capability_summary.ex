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

  use Gettext, backend: MydiaWeb.Gettext

  alias Mydia.Plugins.Manifest
  alias MydiaWeb.AdminPluginsLive.CapabilitySummary.{Group, Line}

  defstruct groups: [], also: []

  @type t :: %__MODULE__{groups: [Group.t()], also: [Line.t()]}

  # {key, emphasized?}. Only Talks to is emphasized: it is the one group
  # whose data leaves Mydia. Titles come from `group_title/1` at build time,
  # never from a module attribute, so they follow the viewer's locale.
  @groups [
    {:talks_to, true},
    {:can_see, false},
    {:can_change, false},
    {:adds, false}
  ]

  defp group_title(:talks_to), do: gettext("Talks to")
  defp group_title(:can_see), do: gettext("Can see")
  defp group_title(:can_change), do: gettext("Can change")
  defp group_title(:adds), do: gettext("Adds to Mydia")

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
      Enum.flat_map(@groups, fn {key, emphasized?} ->
        case for({^key, line} <- entries, do: line) do
          [] ->
            []

          lines ->
            [%Group{key: key, title: group_title(key), emphasized?: emphasized?, lines: lines}]
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
  def data_label("media_item"), do: gettext("Media items")
  def data_label("playback_progress"), do: gettext("Watch progress")
  def data_label("library_item"), do: gettext("Library items")
  def data_label("media_request"), do: gettext("Requests")
  def data_label("download"), do: gettext("Downloads")
  def data_label("collection"), do: gettext("Collections")
  def data_label("watch_history"), do: gettext("Watch history")
  def data_label(namespace), do: namespace

  @doc "Host-owned label for a `surfaces:write` surface."
  @spec surface_label(String.t()) :: String.t()
  def surface_label("playback:watched"), do: gettext("Mark items watched")
  def surface_label("collections:favorite"), do: gettext("Favorite items")
  def surface_label("media:add"), do: gettext("Add media")
  def surface_label("collections:write"), do: gettext("Edit collections")
  def surface_label(surface), do: surface

  @doc "Host-owned noun phrase for a subscribed event (\"reacts to <phrase>\")."
  @spec event_phrase(String.t()) :: String.t()
  def event_phrase("media_item.added"), do: gettext("new titles")
  def event_phrase("media_item.updated"), do: gettext("title updates")
  def event_phrase("media_item.removed"), do: gettext("removed titles")
  def event_phrase("media_file.imported"), do: gettext("new imports")
  def event_phrase("download.completed"), do: gettext("finished downloads")
  def event_phrase("download.failed"), do: gettext("failed downloads")
  def event_phrase("playback.started"), do: gettext("playback starting")
  def event_phrase("playback.progressed"), do: gettext("playback progress")
  def event_phrase("playback.paused"), do: gettext("paused playback")
  def event_phrase("playback.finished"), do: gettext("finished playback")
  def event_phrase("playback.unwatched"), do: gettext("items marked unwatched")
  def event_phrase(event), do: event

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
    do:
      per_value(
        :talks_to,
        hosts,
        new_values,
        &gettext("%{host} (private network)", host: &1)
      )

  defp entries_for("data:read", namespaces, new_values),
    do: per_value(:can_see, namespaces, new_values, &data_label/1)

  defp entries_for("data:search", _, new_values),
    do: flag(:can_see, gettext("Search your library as the person using it"), new_values)

  defp entries_for("users:connections", _, new_values),
    do: flag(:can_see, gettext("Accounts people link to it"), new_values)

  defp entries_for("surfaces:write", surfaces, new_values),
    do: per_value(:can_change, surfaces, new_values, &surface_label/1)

  defp entries_for("surfaces:page", _, new_values),
    do: flag(:adds, gettext("Its own page"), new_values)

  defp entries_for("surfaces:shelf", _, new_values),
    do: flag(:adds, gettext("Suggestions on each person's Home page"), new_values)

  # Approved and newly requested events are separate lines, so a re-approval
  # marks only the events that are actually new.
  defp entries_for("events:subscribe", events, new_values) do
    {added, kept} = Enum.split_with(events, &(is_list(new_values) and &1 in new_values))
    added_kind = if kept == [], do: :reacts, else: :also_reacts

    event_line(kept, :reacts, false) ++ event_line(added, added_kind, true)
  end

  defp entries_for("schedule:interval", _, new_values),
    do: flag(:also, gettext("runs on a schedule"), new_values)

  defp entries_for("state:kv", _, new_values),
    do: flag(:also, gettext("keeps its own storage"), new_values)

  defp entries_for(class, values, new_values),
    do: flag(:also, Enum.join([class | values], " "), new_values)

  defp per_value(group, values, new_values, label_fun) do
    for value <- values do
      {group, %Line{label: label_fun.(value), new?: is_list(new_values) and value in new_values}}
    end
  end

  defp flag(group, label, new_values), do: [{group, %Line{label: label, new?: new_values != nil}}]

  defp event_line([], _prefix, _new?), do: []

  defp event_line(events, kind, new?) do
    phrases = join_and(Enum.map(events, &event_phrase/1))
    [{:also, %Line{label: event_sentence(kind, phrases), new?: new?}}]
  end

  defp event_sentence(:reacts, events), do: gettext("reacts to %{events}", events: events)

  defp event_sentence(:also_reacts, events),
    do: gettext("also reacts to %{events}", events: events)

  defp host_field_entries(schema) do
    for field <- Manifest.host_granting_fields(schema) do
      {:talks_to,
       %Line{label: gettext("The server you enter in %{field}", field: field_name(field))}}
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
    gettext("%{list} and %{last}", list: Enum.join(init, ", "), last: last)
  end
end
