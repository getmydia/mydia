defmodule MetadataRelayWeb.FeedbackLive.Index do
  @moduledoc """
  Maintainer dashboard for reading and triaging Mydia feedback.
  """

  use Phoenix.LiveView

  alias MetadataRelay.Feedback
  alias MetadataRelay.Feedback.IssueDraft
  alias MetadataRelay.GitHub.Client

  @message_preview_limit 220
  @valid_state_filters ~w(unread read filed archived all)
  @valid_type_filters ~w(bug idea question all)

  @impl true
  def mount(params, _session, socket) do
    {:ok,
     socket
     |> assign(:state_filter, "unread")
     |> assign(:type_filter, "all")
     |> assign(:expanded_ids, focused_ids(params))
     |> assign(:page_title, "Feedback Dashboard")
     |> assign(:issue_draft, nil)
     |> assign(:issue_error, nil)
     |> assign(:issue_submitting?, false)
     |> assign(:github_repo, Client.repo())
     |> load_dashboard()}
  end

  defp focused_ids(%{"focus" => focus}) when is_binary(focus), do: MapSet.new([focus])
  defp focused_ids(_params), do: MapSet.new()

  @impl true
  def handle_event("filter", %{"filters" => filters}, socket) do
    {:noreply,
     socket
     |> assign(:state_filter, normalize_state_filter(Map.get(filters, "state")))
     |> assign(:type_filter, normalize_type_filter(Map.get(filters, "type")))
     |> load_dashboard()}
  end

  def handle_event("toggle_expand", %{"id" => id}, socket) do
    expanded_ids =
      if MapSet.member?(socket.assigns.expanded_ids, id) do
        MapSet.delete(socket.assigns.expanded_ids, id)
      else
        MapSet.put(socket.assigns.expanded_ids, id)
      end

    {:noreply, assign(socket, :expanded_ids, expanded_ids)}
  end

  def handle_event("mark_read", %{"id" => id}, socket) do
    update_submission(socket, id, fn submission -> Feedback.update_state(submission, "read") end)
  end

  def handle_event("archive", %{"id" => id}, socket) do
    update_submission(socket, id, fn submission ->
      Feedback.update_state(submission, "archived")
    end)
  end

  def handle_event("save_github_ref", %{"id" => id, "github_ref" => github_ref}, socket) do
    update_submission(socket, id, fn submission ->
      Feedback.set_github_ref(submission, github_ref)
    end)
  end

  def handle_event("open_issue", %{"id" => id}, socket) do
    case Feedback.get_submission(id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Feedback no longer exists.")
         |> load_dashboard()}

      submission ->
        draft = IssueDraft.from_submission(submission, Feedback.dashboard_url())

        {:noreply,
         socket
         |> assign(:issue_draft, %{
           submission_id: submission.id,
           title: draft.title,
           body: draft.body,
           labels: draft.labels
         })
         |> assign(:issue_error, nil)
         |> assign(:issue_submitting?, false)}
    end
  end

  def handle_event("close_issue", _params, socket) do
    {:noreply,
     socket
     |> assign(:issue_draft, nil)
     |> assign(:issue_error, nil)
     |> assign(:issue_submitting?, false)}
  end

  def handle_event("submit_issue", %{"title" => title, "body" => body}, socket) do
    draft = socket.assigns.issue_draft
    token = socket.assigns.github_token

    attrs = %{title: title, body: body, labels: draft.labels}
    submission_id = draft.submission_id

    {:noreply,
     socket
     |> assign(:issue_draft, %{draft | title: title, body: body})
     |> assign(:issue_error, nil)
     |> assign(:issue_submitting?, true)
     |> start_async(:file_issue, fn ->
       case Feedback.get_submission(submission_id) do
         nil -> {:error, {:missing, "Feedback no longer exists."}}
         submission -> Feedback.file_issue(submission, attrs, token)
       end
     end)}
  end

  @impl true
  def handle_async(:file_issue, {:ok, {:ok, submission}}, socket) do
    {:noreply,
     socket
     |> assign(:issue_draft, nil)
     |> assign(:issue_error, nil)
     |> assign(:issue_submitting?, false)
     |> put_flash(:info, "Filed as #{submission.github_ref}")
     |> load_dashboard()}
  end

  def handle_async(:file_issue, {:ok, {:error, {_reason, message}}}, socket) do
    {:noreply,
     socket
     |> assign(:issue_error, message)
     |> assign(:issue_submitting?, false)}
  end

  def handle_async(:file_issue, {:ok, {:error, _changeset}}, socket) do
    {:noreply,
     socket
     |> assign(
       :issue_error,
       "The issue was created but could not be recorded. Reload and check GitHub."
     )
     |> assign(:issue_submitting?, false)}
  end

  def handle_async(:file_issue, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:issue_error, "GitHub is unreachable. Your draft is preserved, try again.")
     |> assign(:issue_submitting?, false)}
  end

  defp update_submission(socket, id, updater) do
    case Feedback.get_submission(id) do
      nil ->
        {:noreply,
         socket
         |> put_flash(:error, "Feedback no longer exists.")
         |> load_dashboard()}

      submission ->
        case updater.(submission) do
          {:ok, _submission} ->
            {:noreply, load_dashboard(socket)}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Could not update feedback.")}
        end
    end
  end

  defp load_dashboard(socket) do
    opts =
      []
      |> maybe_filter(:state, socket.assigns.state_filter)
      |> maybe_filter(:type, socket.assigns.type_filter)

    filtered_submissions = Feedback.list_submissions(opts)

    socket
    |> assign(:submissions, filtered_submissions)
    |> assign(:summary, Feedback.submission_summary())
    |> assign(:visible_count, length(filtered_submissions))
  end

  defp maybe_filter(opts, _key, "all"), do: opts
  defp maybe_filter(opts, key, value), do: Keyword.put(opts, key, value)

  def expanded?(expanded_ids, id), do: MapSet.member?(expanded_ids, id)

  def short_instance_id(nil), do: "anonymous"

  def short_instance_id(instance_id) do
    String.slice(instance_id, 0, 8)
  end

  def format_time(nil), do: ""

  def format_time(datetime) do
    Calendar.strftime(datetime, "%Y-%m-%d %H:%M:%S UTC")
  end

  def active_filter_label(state_filter, type_filter, visible_count) do
    "Showing #{visible_count} matching submissions - State: #{label_for_state_filter(state_filter)} - Type: #{label_for_type_filter(type_filter)}"
  end

  def empty_state_copy(state_filter, type_filter) do
    "No #{label_for_state_filter(state_filter)} #{label_for_type_filter(type_filter)} submissions match the current filters."
  end

  def type_label("bug"), do: "Bug"
  def type_label("idea"), do: "Idea"
  def type_label("question"), do: "Question"

  def state_label("unread"), do: "Unread"
  def state_label("read"), do: "Read"
  def state_label("filed"), do: "Filed"
  def state_label("archived"), do: "Archived"

  def type_badge_class("bug"), do: "badge-error"
  def type_badge_class("idea"), do: "badge-info"
  def type_badge_class("question"), do: "badge-warning"

  def state_badge_class("unread"), do: "badge-primary"
  def state_badge_class("read"), do: "badge-ghost"
  def state_badge_class("filed"), do: "badge-success"
  def state_badge_class("archived"), do: "badge-neutral"

  def expandable_message?(message), do: byte_size(message) > @message_preview_limit

  def truncate_message(message) when byte_size(message) <= @message_preview_limit, do: message
  def truncate_message(message), do: String.slice(message, 0, @message_preview_limit) <> "..."

  defp label_for_state_filter("all"), do: "all states"
  defp label_for_state_filter("unread"), do: "unread"
  defp label_for_state_filter("read"), do: "read"
  defp label_for_state_filter("filed"), do: "filed"
  defp label_for_state_filter("archived"), do: "archived"
  defp label_for_state_filter(_), do: "all states"

  defp label_for_type_filter("all"), do: "all types"
  defp label_for_type_filter("bug"), do: "bug"
  defp label_for_type_filter("idea"), do: "idea"
  defp label_for_type_filter("question"), do: "question"
  defp label_for_type_filter(_), do: "all types"

  defp normalize_state_filter(nil), do: "unread"
  defp normalize_state_filter(value) when value in @valid_state_filters, do: value
  defp normalize_state_filter(_), do: "all"

  defp normalize_type_filter(nil), do: "all"
  defp normalize_type_filter(value) when value in @valid_type_filters, do: value
  defp normalize_type_filter(_), do: "all"
end
