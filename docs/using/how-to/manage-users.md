# User Management

Mydia includes a built-in multi-user system with role-based access control.

## User Roles

Mydia has four roles, ranked. Each one can do everything the role below it can,
with one deliberate exception noted below.

| Role | Can do |
|------|--------|
| **Admin** | Everything. The only role that reaches `/admin`: configuration, indexers, download clients, libraries, users, jobs, and approving or rejecting requests. |
| **User** | Browse the library, and add, edit, or delete media. Cannot reach any admin page. |
| **Read Only** | Browse the library. Cannot add, edit, or delete anything. |
| **Guest** | Browse the library, and submit requests for an admin to approve. |

New users default to **Guest**.

!!! note "Only guests can submit requests"
    The request flow is not additive. `can_submit_request?` returns true for
    guests and false for everyone else, including admins, because a user or admin
    is expected to add the media directly rather than ask for it. So a Read Only
    user can neither add media nor request it.

## First User Setup

When you first access Mydia:

1. You're guided through creating the initial admin user
2. Choose to set a custom password or generate a secure random one
3. After creation, you're automatically logged in

## Local Authentication

By default, Mydia uses local username/password authentication.

### Configuration

```bash
LOCAL_AUTH_ENABLED=true
```

### Creating Users

Admins can create users through the Admin UI:

1. Navigate to **Admin > Users**
2. Click **Create Local User**
3. Enter username and email
4. Select a role: Guest, Read Only, User, or Admin
5. Either set a password or let Mydia generate a random one
6. Save

You can change an existing user's role later from the same page, using the edit
icon on their row.

Mydia also supports single sign-on via OpenID Connect (OIDC), including auto-promotion of the first OIDC user to admin. See [SSO/OIDC Configuration](sso-oidc.md) for supported providers, setup, and role assignment.

## Request System

Guest users can request media:

1. **Guest searches** for a movie or TV show
2. **Guest clicks Request** on the search result
3. **The request lands in the admin queue** as pending
4. **Admin reviews** and approves or rejects
5. **If approved**, media is added to library and download begins
6. **The guest sees the outcome** on their own requests page

!!! warning "There are no notifications"
    Mydia does not email, push, or otherwise notify anyone about requests. Nothing
    tells an admin that a request arrived, and nothing tells the guest it was
    approved or rejected. Both sides find out by looking. Admins should check
    **Admin > Requests** periodically, and guests can watch **My Requests**.

### Managing Requests

Admins can view and manage requests:

1. Navigate to **Admin > Requests**
2. View pending requests
3. Approve or reject each request
4. A rejection requires a reason, which the requester can see

## Disabling Authentication

!!! danger "Security Warning"
    Disabling authentication is not recommended for production deployments.

For local/testing environments, you can disable local auth when using OIDC:

```bash
LOCAL_AUTH_ENABLED=false
OIDC_ENABLED=true
```

## Next Steps

- [Adding Media](add-media.md) - How guests search for media to request
- [SSO/OIDC](sso-oidc.md) - Detailed OIDC configuration
- [Environment Variables](../reference/environment-variables.md) - All auth options
