# User Management

Mydia includes a built-in multi-user system with role-based access control.

## User Roles

| Role | Permissions |
|------|-------------|
| **Admin** | Full access: media management, downloads, configuration, request approval |
| **Guest** | Browse library, submit requests for admin approval |

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
2. Click **Add User**
3. Enter username, email, and password
4. Select role (admin or guest)
5. Save

Mydia also supports single sign-on via OpenID Connect (OIDC), including auto-promotion of the first OIDC user to admin. See [SSO/OIDC Configuration](sso-oidc.md) for supported providers, setup, and role assignment.

## Request System

Guest users can request media:

1. **Guest searches** for a movie or TV show
2. **Guest clicks Request** on the search result
3. **Admin receives notification** of the request
4. **Admin reviews** and approves or denies
5. **If approved**, media is added to library and download begins
6. **Guest is notified** of the decision

### Managing Requests

Admins can view and manage requests:

1. Navigate to **Admin > Requests**
2. View pending requests
3. Approve or deny each request
4. Optionally add a message

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
