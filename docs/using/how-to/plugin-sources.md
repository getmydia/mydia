# Add a third-party plugin source

A plugin source is a signed catalog of plugins published by someone other than
Mydia. Once you add one, its plugins appear in the plugin store next to the
official ones. Mydia has not reviewed them, so add only sources whose publisher
you trust.

## Add a source

You need the catalog URL and the publisher's signing key fingerprint, both from
the publisher.

1. Open **Admin > System > Plugins** and find the **Plugin sources** card.
2. Click **Add source**.
3. Enter the **Catalog URL**, for example `https://example.com/index.json`, and
   click **Check source**.
4. Review what Mydia found:
   - **Name** and **URL** of the catalog.
   - **Signing key**: the fingerprint of the key the catalog is signed with.
   - **Plugins listed**: how many plugins the catalog offers.

   Compare the signing key with the fingerprint the publisher gave you through a
   channel you trust. Adding the source trusts whoever holds that key.
5. Click **Trust and add**, or **Cancel**.

If the check fails, the window shows the reason, such as an unreachable URL or a
catalog whose signature does not verify. Nothing is added.

Mydia remembers the key from the moment you add the source. Plugins from the
source then show up under **Browse store** with a **Third-party** badge. Install
them as described in [Install and manage plugins](plugins.md); the approval
window repeats the warning that the plugin comes from outside the Mydia index.

## Read the sources table

The card lists the **Mydia plugin index**, marked with an **Official** badge,
and each source you added. The columns are **Name**, **URL**, **Key** (the
signing key fingerprint), **Plugins** (how many it lists) and **Status**. An
error from the last refresh, such as a signature that no longer verifies, shows
in the **Status** column.

## Sources declared in configuration

A source set with environment variables or in `config.yml` shows a **Declared**
badge and has no **Remove** button. Change it where you declared it; see
[Plugin sources](../reference/environment-variables.md#plugin-sources) and the
[configuration file](../reference/configuration.md#plugin-instances). A source you
stop declaring is disabled, not deleted.

## Remove a source

Click **Remove** on the source's row and confirm. Plugins you installed from it
keep running, but they stop receiving updates. Remove each plugin separately if
you want it gone.

## When a source's key changes

Mydia pins the key you saw when you added the source and never accepts a
different one on its own. If the publisher changes keys, or someone tampers with
the catalog, the source shows an error that its signing key changed, and its
plugins stop updating.

Ask the publisher whether the change was intentional and get the new
fingerprint from them. If it was, **Remove** the source and add it again, then
compare the new fingerprint as in the steps above. If they did not change it,
leave the source removed.

## Publishing your own

If you write plugins, see
[Publish your own plugin source](../../plugins/how-to/publish-a-source.md).
