# Install and manage plugins

Plugins add features to Mydia, such as a media server connection, a watch-history
sync, or suggestions on Home. Each one runs in a sandbox and can only do what you
approve. You manage them in **Admin > System > Plugins**.

## Install a plugin from the store

1. Open **Admin > System > Plugins** and click **Browse store**.
2. Find the plugin and click **Install**. Entries from a source you added
   yourself carry a **Third-party** badge. Entries already on your server show
   **Installed** or **Bundled** instead of a button.
3. Read the approval window. It lists what the plugin asks for in plain groups:
   **Talks to** (the hosts it may contact, highlighted because that data leaves
   your server), **Can see**, **Can change** and **Adds to Mydia**, followed by an
   "Also:" line for background behavior. For a plugin from a third-party source
   the window also warns that Mydia has not reviewed it.
4. Click **Approve & activate**, or **Decline** to stop. Approval is
   all-or-nothing: the plugin cannot run until you approve, and you cannot
   approve part of the list.

An approved plugin appears in the list as **active**. If a plugin shows
**Review & approve** instead, it was installed without approval (for example
with `mydia-cli`, see below); that button opens the same window.

Only the official Mydia plugin index is listed by default. To browse a
third-party catalog, [add it as a plugin source](plugin-sources.md).

## Install a plugin someone sent you as files

If you were given a `.wasm` file and a `manifest.json` rather than a store
listing, copy both somewhere the container can read, such as the `/config`
volume, and run:

```bash
docker exec mydia mydia-cli plugin install \
  /config/my_plugin.wasm /config/manifest.json
```

The plugin installs inactive. Approve it from its **Review & approve** button as
above. Adding `--approve` grants everything the manifest declares on the spot,
so use it only for a plugin you wrote or fully trust. Only install files from
people you trust: Mydia cannot check where a sideloaded file came from.

## Configure a plugin

Click **Settings** on the plugin's row. The fields are the plugin's own, so
they differ from plugin to plugin.

- Some fields only appear once another field has a certain value. Choose the
  controlling option first.
- A field that shows "Set in the environment or config file. Change it there."
  is read-only here because you declared it with an environment variable or in
  `config.yml`. Change it where you set it. See
  [Plugins](../reference/environment-variables.md#plugins) and the
  [configuration file](../reference/configuration.md#plugin-instances).
- A web address you type into a setting that the plugin uses to reach a server
  is added to the hosts the plugin may contact when you save.
- Secrets are write-only: the dialog never shows them again after saving.

Click **Save settings**. **Settings** is greyed out with a tooltip while the
plugin awaits approval or if it has nothing to configure. Plugins that connect
to a media server are configured per server instead, on
[Media servers](#media-server-plugins).

### Let plugins make changes for people

A plugin that can serve its own page and change things on a user's behalf (for
example, add a title to a collection) asks the user before each change. The
Settings window of such a plugin has a second section, **What each role may
allow without asking**, with one menu per role: **Nothing**, **Ask every
time**, **Up to a session** and **Up to always**. The choice is the longest
grant that role may give the plugin. Click **Save permissions** to apply it.

Without changes, admins and users may go up to always, guests up to a session,
and read-only users cannot allow anything. People can see and revoke what they
allowed on their own **Integrations** page, under **Plugin permissions**.

## Update a plugin

Mydia checks every source for newer versions once a day at 07:00 server time. A
plugin with a newer version gets an **update available** badge.

1. Click **Browse store** and find the plugin.
2. Click **Update to v**_x.y.z_. A plugin installed from the official index
   that is now also offered by a third-party source shows **Replace**, which
   switches its future updates to that source.
3. Review and approve in the window that opens, as for a new install.

### When a plugin asks for more than you approved

A plugin never gains permissions by itself. If a new version asks for something
you have not approved (a new host to contact, for example), the plugin keeps
running on your earlier approval, the new access is denied, and its row shows a
**needs re-approval** badge naming what is missing. Click **Review & re-approve**.
The window marks the newly requested items **New**. Click **Re-approve** to
grant them, or leave it as is to keep the plugin limited.

## Check what a plugin is doing

Click **Logs** on the plugin's row. The window has three tabs.

- **Activity** is a live log of what the plugin reports. You can search it and
  filter by level.
- **Network** lists every request the plugin made to the internet, with the
  address, status, size and outcome. A request to a host you did not approve
  shows a non-ok outcome.
- **Test** sends the plugin a made-up event so you can confirm it responds
  without waiting for real activity. Pick an event and click **Run test**. The
  plugin must be enabled and listen for events, otherwise the tab says so.
  Watch the **Activity** tab for the result.

If a plugin fills Home suggestions and fails for some people, its row shows a
line such as "Suggestions failing for 2 people", followed by the most recent
error the plugin returned. The cause is usually in its settings, such as a
wrong server address or API key. Check the **Network** tab.

**Details** shows everything the plugin is currently allowed to do, and anything
it requests but was not granted.

## Disable, revoke or remove a plugin

- **Disable** turns the plugin off and keeps its approval and settings.
  **Enable** turns it back on.
- **Details**, then **Revoke capabilities**, takes away everything you approved
  and deactivates the plugin. It stays listed and needs approval again before it
  runs.
- The trash icon removes the plugin and its settings entirely.

Revoking or removing a plugin also deletes the suggestions it filled for your
users, along with their dismissals. Disabling only hides them, and enabling the
plugin shows them again.

!!! note "Bundled plugins come back"
    Some plugins ship inside Mydia and are marked **Bundled** in the store.
    Because Mydia itself is their source, removing one is not permanent: the
    next time Mydia starts, or someone opens the Plugins page, it is added again
    with its shipped permissions, approved and enabled. Revoked permissions are
    restored the same way. **Disable** is the control that sticks, and Mydia
    keeps your choice across updates.

## Media server plugins

Plugins that connect a media server, such as Plex, add themselves to the
**Add server** menu on **Admin > Configuration > Media Servers**. The menu lists
a plugin once it is installed, approved and enabled, next to **Jellyfin**, which
is built in.

1. Install and approve the plugin as above.
2. On **Media Servers**, click **Add server** and choose the plugin.
3. Follow the steps in the window. Each plugin asks for what it needs, such as
   an address and a sign-in.
4. Repeat for each server. Every server is its own instance with its own
   settings.

On the **Plugins** page such a plugin's **Settings** button is greyed out with
"Configured per server on Media servers". You can also declare servers in your
configuration; see [Media servers](../reference/environment-variables.md#media-servers).

## Link your account to a plugin

Some plugins act on your own account at an outside service, such as syncing watch
history. Each person links their own account from **Integrations** in the user
menu.

1. Click **Connect** followed by the plugin's name.
2. Open the address shown, enter the code on that page, and approve at the
   service. Mydia says "Waiting for authorization..." until you do. **Cancel**
   stops the attempt.
3. The card shows **Connected**. **Disconnect** removes the link. **Needs
   reconnect** with a **Reconnect** button means the service stopped accepting
   the saved sign-in.

## What your users see

Home gains one **Picked for you** entry in **Customize Home** that turns on
every shelf plugins provide. People who customized Home before the plugin
arrived have to tick it once. Each card has a **Not interested** button, and a
dismissed title never returns to that shelf for that person.

## See also

- [Add a third-party plugin source](plugin-sources.md)
- [Environment variables: Plugins](../reference/environment-variables.md#plugins)
  and [configuration file](../reference/configuration.md#plugin-instances) for
  declaring plugin settings
- Plugin author? See [Build plugins](../../plugins/index.md).
