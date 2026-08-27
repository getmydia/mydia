defmodule MydiaWeb.Live.UserAuth do
  @moduledoc """
  LiveView authentication hooks.

  Provides `on_mount` hooks for LiveViews to authenticate users
  and assign current_user to the socket.
  """
  import Phoenix.Component
  import Phoenix.LiveView

  alias Ecto.Changeset
  alias Mydia.Accounts
  alias Mydia.Accounts.Authorization
  alias Mydia.Auth.Guardian
  alias Mydia.MediaRequests

  @doc """
  LiveView mount hook for authentication and authorization.

  Supports multiple modes:
  - `:ensure_authenticated` - Requires user to be logged in
  - `:maybe_authenticated` - Loads user if present, but doesn't require it
  - `{:ensure_role, role}` - Requires user to have a specific role
  - `:load_navigation_data` - Loads counts for navigation sidebar/layout

  Usage in LiveView:
      on_mount {MydiaWeb.Live.UserAuth, :ensure_authenticated}
      on_mount {MydiaWeb.Live.UserAuth, :maybe_authenticated}
      on_mount {MydiaWeb.Live.UserAuth, {:ensure_role, :admin}}
      on_mount {MydiaWeb.Live.UserAuth, :load_navigation_data}
  """
  def on_mount(mode, params, session, socket)

  def on_mount(:ensure_authenticated, _params, session, socket) do
    socket = mount_current_user(socket, session)

    case socket.assigns do
      %{current_user: %Mydia.Accounts.User{} = user} ->
        # Carries the user plus their media access restrictions. Every Media
        # read and write in this LiveView takes it.
        socket = assign(socket, :current_scope, Mydia.Accounts.Scope.for_user(user))
        {:cont, socket}

      _ ->
        socket =
          socket
          |> put_flash(:error, "You must be logged in to access this page")
          |> redirect(to: "/auth/login")

        {:halt, socket}
    end
  end

  def on_mount(:maybe_authenticated, _params, session, socket) do
    {:cont, mount_current_user(socket, session)}
  end

  def on_mount({:ensure_role, required_role}, _params, session, socket) do
    socket = mount_current_user(socket, session)

    case socket.assigns do
      %{current_user: %Mydia.Accounts.User{} = user} ->
        if has_role?(user, required_role) do
          # Carries the user plus their media access restrictions. Every Media
          # read and write in this LiveView takes it.
          socket = assign(socket, :current_scope, Mydia.Accounts.Scope.for_user(user))
          {:cont, socket}
        else
          socket =
            socket
            |> put_flash(:error, "You do not have permission to access this page")
            |> redirect(to: "/")

          {:halt, socket}
        end

      _ ->
        socket =
          socket
          |> put_flash(:error, "You do not have permission to access this page")
          |> redirect(to: "/")

        {:halt, socket}
    end
  end

  def on_mount(:load_navigation_data, _params, _session, socket) do
    # Subscribe to job status updates for real-time sidebar indicator
    if connected?(socket) do
      Mydia.Jobs.Broadcaster.subscribe()
    end

    # Load navigation counts once per LiveView mount
    # These are used by the layout component for sidebar badges
    pending_requests_count =
      case Map.fetch(socket.assigns, :current_user) do
        {:ok, user} when not is_nil(user) ->
          if Authorization.can_manage_requests?(user) do
            MediaRequests.count_pending_requests()
          else
            0
          end

        _ ->
          0
      end

    # Get configured library types (for showing/hiding sidebar links)
    configured_library_types = get_configured_library_types()

    # Get executing jobs for sidebar status indicator
    executing_jobs = Mydia.Jobs.list_executing_jobs()

    socket =
      socket
      |> assign(:movie_count, Mydia.Media.count_movies(socket.assigns.current_scope))
      |> assign(:tv_show_count, Mydia.Media.count_tv_shows(socket.assigns.current_scope))
      |> assign(:downloads_count, Mydia.Downloads.count_active_downloads())
      |> assign(:import_group_count, Mydia.ImportGroups.count_pending())
      |> assign(:pending_requests_count, pending_requests_count)
      |> assign(:configured_library_types, configured_library_types)
      |> assign(:executing_jobs, executing_jobs)
      |> assign(:current_path, nil)
      |> assign(:feedback_enabled?, Mydia.Feedback.enabled?())
      |> assign(:show_feedback_modal, false)
      |> assign(:feedback_form, build_feedback_form(%{}))
      |> assign_changelog_notice()
      |> attach_hook(:changelog_hook, :handle_event, &handle_changelog_event/3)
      |> attach_hook(:jobs_status_hook, :handle_info, &handle_jobs_status/2)
      |> attach_hook(:feedback_hook, :handle_event, &handle_feedback_event/3)

    # handle_params hooks only work for LiveViews mounted via live/3 in the router.
    # This on_mount also runs for non-router views (e.g. dead view rendering), so
    # we guard against the RuntimeError that would be raised in those cases.
    socket =
      try do
        attach_hook(socket, :track_current_path, :handle_params, &track_current_path/3)
      rescue
        RuntimeError -> socket
      end

    {:cont, socket}
  end

  # Track current path for active navigation highlighting
  defp track_current_path(_params, uri, socket) do
    path = URI.parse(uri).path
    {:cont, assign(socket, :current_path, path)}
  end

  # Handle job status updates from PubSub
  defp handle_jobs_status({:jobs_status_changed, executing_jobs}, socket) do
    {:halt, assign(socket, :executing_jobs, executing_jobs)}
  end

  defp handle_jobs_status(_msg, socket) do
    {:cont, socket}
  end

  defp handle_feedback_event("open_feedback_modal", _params, socket) do
    {:halt, assign(socket, :show_feedback_modal, true)}
  end

  defp handle_feedback_event("close_feedback_modal", _params, socket) do
    {:halt,
     socket
     |> assign(:show_feedback_modal, false)
     |> assign(:feedback_form, build_feedback_form(%{}))}
  end

  defp handle_feedback_event("validate_feedback", %{"feedback" => feedback_params}, socket) do
    {:halt, assign(socket, :feedback_form, build_feedback_form(feedback_params, :validate))}
  end

  defp handle_feedback_event("submit_feedback", %{"feedback" => feedback_params}, socket) do
    changeset = feedback_changeset(feedback_params)

    if changeset.valid? do
      feedback =
        changeset
        |> Changeset.apply_changes()

      case Mydia.Feedback.send(feedback) do
        {:ok, _result} ->
          {:halt,
           socket
           |> put_flash(:info, "Thanks, feedback sent.")
           |> assign(:show_feedback_modal, false)
           |> assign(:feedback_form, build_feedback_form(%{}))}

        {:error, {:rate_limited, retry_after}} ->
          {:halt,
           socket
           |> put_flash(
             :error,
             "Feedback is rate limited. Try again #{retry_after_text(retry_after)}."
           )
           |> assign(:feedback_form, build_feedback_form(feedback_params))}

        {:error, :service_unavailable} ->
          {:halt,
           socket
           |> put_flash(
             :error,
             "Feedback service is temporarily unavailable. Please try again later."
           )
           |> assign(:feedback_form, build_feedback_form(feedback_params))}

        {:error, _reason} ->
          {:halt,
           socket
           |> put_flash(:error, "Could not send feedback. Please try again later.")
           |> assign(:feedback_form, build_feedback_form(feedback_params))}
      end
    else
      {:halt, assign(socket, :feedback_form, build_feedback_form(feedback_params, :validate))}
    end
  end

  defp handle_feedback_event(_event, _params, socket), do: {:cont, socket}

  # Decide whether this user has unread release notes.
  #
  # A nil stored version means the user has never been shown the changelog,
  # which is true of every user that existed before the feature shipped and of
  # every newly created user. Those adopt the newest bundled version silently,
  # so nobody is greeted by the entire project history.
  defp assign_changelog_notice(socket) do
    case socket.assigns do
      %{current_user: %Mydia.Accounts.User{} = user} ->
        assign(socket, :changelog_notice, changelog_notice_for(user, connected?(socket)))

      _ ->
        assign(socket, :changelog_notice, nil)
    end
  end

  # The `connected` flag gates the adoption write only. `mount/3` runs twice, and
  # writing during the dead render would burn a database write on every page load
  # for no gain. The banner decision itself is identical in both renders.
  #
  # Note the parameter is named `connected`, not `connected?`: Elixir variable
  # names cannot contain a question mark.
  defp changelog_notice_for(user, connected) do
    case Mydia.Accounts.last_seen_changelog_version(user) do
      nil ->
        if connected, do: Mydia.Accounts.mark_changelog_seen_at_latest(user)
        nil

      last_seen ->
        case Mydia.Changelog.unseen(last_seen) do
          [] ->
            nil

          [newest | older] ->
            %{version: newest.version_string, older_count: length(older)}
        end
    end
  end

  defp handle_changelog_event("dismiss_changelog", _params, socket) do
    case socket.assigns do
      %{current_user: %Mydia.Accounts.User{} = user} ->
        Mydia.Accounts.mark_changelog_seen_at_latest(user)

      _ ->
        :ok
    end

    {:halt, assign(socket, :changelog_notice, nil)}
  end

  defp handle_changelog_event(_event, _params, socket), do: {:cont, socket}

  defp build_feedback_form(params, action \\ nil) do
    params
    |> feedback_changeset()
    |> Map.put(:action, action)
    |> to_form(as: :feedback)
  end

  defp feedback_changeset(params) do
    types = %{type: :string, message: :string, contact: :string}

    {%{}, types}
    |> Changeset.cast(params, Map.keys(types))
    |> Changeset.validate_required([:type, :message])
    |> Changeset.validate_inclusion(:type, ["bug", "idea", "question"])
    |> validate_feedback_message_bytes()
  end

  defp validate_feedback_message_bytes(changeset) do
    Changeset.validate_change(changeset, :message, fn :message, message ->
      if byte_size(message) > 4096 do
        [message: "should be at most 4096 bytes"]
      else
        []
      end
    end)
  end

  defp retry_after_text(nil), do: "later"

  defp retry_after_text(seconds) when is_integer(seconds) and seconds < 60,
    do: "in #{seconds} seconds"

  defp retry_after_text(seconds) when is_integer(seconds) do
    minutes = max(div(seconds, 60), 1)
    "in about #{minutes} minutes"
  end

  defp retry_after_text(_seconds), do: "later"

  # Get a MapSet of library types that have at least one enabled library path
  defp get_configured_library_types do
    Mydia.Settings.list_library_paths()
    |> Enum.reject(& &1.disabled)
    |> Enum.map(& &1.type)
    |> MapSet.new()
  end

  # Mount the current user from the session
  defp mount_current_user(socket, session) do
    case session do
      %{"guardian_default_token" => token} ->
        case Guardian.verify_token(token) do
          {:ok, user} ->
            assign(socket, current_user: user)

          {:error, _reason} ->
            assign(socket, current_user: nil)
        end

      %{"guardian_token" => token} ->
        # Legacy key for backward compatibility
        case Guardian.verify_token(token) do
          {:ok, user} ->
            assign(socket, current_user: user)

          {:error, _reason} ->
            assign(socket, current_user: nil)
        end

      %{"user_id" => user_id} ->
        # Fallback: load user by ID if no Guardian token
        case Accounts.get_user!(user_id) do
          user -> assign(socket, current_user: user)
        end

      _ ->
        assign(socket, current_user: nil)
    end
  rescue
    Ecto.NoResultsError ->
      assign(socket, current_user: nil)
  end

  # Check if user has the required role
  defp has_role?(user, required_role) do
    role_hierarchy = %{
      "admin" => 4,
      "user" => 3,
      "readonly" => 2,
      "guest" => 1
    }

    user_level = Map.get(role_hierarchy, user.role, 0)
    required_level = Map.get(role_hierarchy, to_string(required_role), 999)

    user_level >= required_level
  end
end
