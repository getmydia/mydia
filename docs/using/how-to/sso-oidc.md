# SSO/OIDC Configuration

Mydia supports OpenID Connect (OIDC) for single sign-on integration.

## Supported Providers

Mydia works with any OIDC-compliant provider:

- Keycloak
- Authelia
- Auth0
- Okta
- Azure AD
- Google
- And more...

## Configuration

### Environment Variables

```bash
OIDC_ENABLED=true
OIDC_ISSUER=https://your-provider
OIDC_CLIENT_ID=mydia
OIDC_CLIENT_SECRET=your-client-secret
OIDC_REDIRECT_URI=http://localhost:4000/auth/oidc/callback
OIDC_SCOPES=openid profile email
```

### Variable Reference

| Variable | Description | Required |
|----------|-------------|----------|
| `OIDC_ENABLED` | Enable OIDC authentication | Yes |
| `OIDC_ISSUER` | OIDC issuer URL (e.g., `https://auth.example.com`) | Yes |
| `OIDC_CLIENT_ID` | Application client ID | Yes |
| `OIDC_CLIENT_SECRET` | Application client secret | Yes |
| `OIDC_REDIRECT_URI` | Callback URL (auto-computed if not set) | No |
| `OIDC_SCOPES` | Space-separated scope list | No |

!!! note "Legacy Variable"
    `OIDC_DISCOVERY_DOCUMENT_URI` is still accepted as a legacy alias for `OIDC_ISSUER`. The issuer is extracted by stripping the `/.well-known/openid-configuration` suffix.

## Provider Setup

### Minimal Configuration

Mydia uses standard OAuth2 authentication. Configure your provider with:

1. **Client ID** - Unique identifier for Mydia
2. **Client Secret** - Secret key for authentication
3. **Redirect URI** - `https://your-mydia-host/auth/oidc/callback`

No need to configure:

- Token endpoint auth methods
- Response modes
- JWT-based authentication
- PAR settings

### Keycloak Example

1. Create a new client in your realm
2. Set client protocol to `openid-connect`
3. Set access type to `confidential`
4. Add redirect URI: `https://mydia.example.com/auth/oidc/callback`
5. Copy client ID and secret

```bash
OIDC_ISSUER=https://keycloak.example.com/realms/myrealm
OIDC_CLIENT_ID=mydia
OIDC_CLIENT_SECRET=your-client-secret
```

### Authelia Example

1. Add client configuration to Authelia:

```yaml
identity_providers:
  oidc:
    clients:
      - client_id: mydia
        client_secret: your-client-secret
        redirect_uris:
          - https://mydia.example.com/auth/oidc/callback
        scopes:
          - openid
          - profile
          - email
```

2. Configure Mydia:

```bash
OIDC_ISSUER=https://authelia.example.com
OIDC_CLIENT_ID=mydia
OIDC_CLIENT_SECRET=your-client-secret
```

### Auth0 Example

1. Create a new Regular Web Application
2. Configure allowed callback URLs
3. Copy domain, client ID, and secret

```bash
OIDC_ISSUER=https://your-tenant.auth0.com
OIDC_CLIENT_ID=your-client-id
OIDC_CLIENT_SECRET=your-client-secret
```

### Google Example

1. Create OAuth 2.0 credentials in Google Cloud Console
2. Add authorized redirect URIs
3. Copy client ID and secret

```bash
OIDC_ISSUER=https://accounts.google.com
OIDC_CLIENT_ID=your-client-id.apps.googleusercontent.com
OIDC_CLIENT_SECRET=your-client-secret
```

## User Management

### First User Promotion

The first user to log in via OIDC is automatically promoted to admin role. Subsequent users are assigned guest role.

### Role Assignment

Currently, role assignment is manual after first login:

1. Admin logs in
2. Navigates to Admin > Users
3. Updates user role as needed

### Combining with Local Auth

You can use both local and OIDC authentication:

```bash
LOCAL_AUTH_ENABLED=true
OIDC_ENABLED=true
```

Users see options for both on the login page.

### Disabling Local Auth

For OIDC-only authentication:

```bash
LOCAL_AUTH_ENABLED=false
OIDC_ENABLED=true
```

!!! warning
    Ensure OIDC is working before disabling local auth to avoid lockout.

## Scopes

Default scopes:

```bash
OIDC_SCOPES=openid profile email
```

Required scopes:

- `openid` - Required for OIDC
- `profile` - User profile information
- `email` - User email address

## Redirect URI

The redirect URI is auto-computed from your `PHX_HOST` and `URL_SCHEME`:

```
{URL_SCHEME}://{PHX_HOST}/auth/oidc/callback
```

Override with:

```bash
OIDC_REDIRECT_URI=https://mydia.example.com/auth/oidc/callback
```

## Troubleshooting

### Login Fails

1. Check discovery document URI is accessible
2. Verify client ID and secret
3. Check redirect URI matches provider configuration
4. Review application logs for errors

### User Not Created

1. Ensure required scopes are granted
2. Check provider returns email claim
3. Review application logs

### Session Issues

1. Check cookie settings
2. Verify HTTPS configuration
3. Check `PHX_HOST` matches your domain

## Testing

For detailed testing instructions, see the [OIDC Testing Guide](https://github.com/getmydia/mydia/blob/master/docs/OIDC_TESTING.md).
