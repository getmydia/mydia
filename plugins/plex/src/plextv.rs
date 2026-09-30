//! plex.tv calls: PIN sign-in, server discovery, Plex Home profiles.

use crate::host::Host;
use crate::http::{
    encode, plex_headers, query, request, send_json, Auth, PlexError, CLIENT_IDENTIFIER, PRODUCT,
};
use serde::{Deserialize, Serialize};

const AUTH_BASE: &str = "https://app.plex.tv/auth#";

pub struct Pin {
    pub id: i64,
    pub code: String,
}

pub enum PinStatus {
    Pending,
    Authorized(String),
    Expired,
}

#[derive(Deserialize)]
struct PinBody {
    id: i64,
    code: String,
    #[serde(rename = "authToken", default)]
    auth_token: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
pub struct Connection {
    pub uri: String,
    #[serde(default)]
    pub local: bool,
    #[serde(default)]
    pub relay: bool,
    #[serde(default)]
    pub protocol: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct Server {
    #[serde(default)]
    pub name: String,
    #[serde(rename = "clientIdentifier")]
    pub machine_identifier: String,
    #[serde(rename = "accessToken", default)]
    pub access_token: Option<String>,
    #[serde(default)]
    pub provides: Option<String>,
    #[serde(default)]
    pub owned: bool,
    #[serde(default)]
    pub presence: bool,
    #[serde(default)]
    pub connections: Vec<Connection>,
}

impl Server {
    fn provides_server(&self) -> bool {
        self.provides
            .as_deref()
            .is_some_and(|p| p.split(',').any(|c| c.trim() == "server"))
    }
}

#[derive(Debug, Clone, PartialEq)]
pub struct HomeUser {
    pub uuid: String,
    pub name: String,
    pub admin: bool,
}

#[derive(Deserialize)]
struct RawUser {
    #[serde(default)]
    uuid: Option<serde_json::Value>,
    #[serde(default)]
    username: Option<String>,
    #[serde(default)]
    title: Option<String>,
    #[serde(default)]
    admin: bool,
}

impl RawUser {
    /// `uuid`, never the numeric `id`: the v2 switch endpoint answers 404 for
    /// the numeric id. `username` is null for managed profiles; `title` names
    /// most of a household.
    fn into_home_user(self, admin_override: Option<bool>) -> Option<HomeUser> {
        let uuid = match self.uuid? {
            serde_json::Value::String(s) if !s.is_empty() => s,
            serde_json::Value::Number(n) => n.to_string(),
            _ => return None,
        };
        let name = self
            .username
            .filter(|s| !s.trim().is_empty())
            .or(self.title)
            .unwrap_or_default();
        Some(HomeUser {
            uuid,
            name,
            admin: admin_override.unwrap_or(self.admin),
        })
    }
}

#[derive(Deserialize)]
#[serde(untagged)]
enum UsersBody {
    Wrapped { users: Vec<RawUser> },
    Bare(Vec<RawUser>),
}

pub fn create_pin(host: &mut dyn Host, base: &str) -> Result<Pin, PlexError> {
    let body = query(&[
        ("strong", "true".to_string()),
        ("X-Plex-Product", PRODUCT.to_string()),
        ("X-Plex-Client-Identifier", CLIENT_IDENTIFIER.to_string()),
    ]);
    let mut headers = plex_headers();
    headers.push((
        "Content-Type".to_string(),
        "application/x-www-form-urlencoded".to_string(),
    ));
    let pin: PinBody = send_json(
        host,
        &Auth::None,
        request("POST", &format!("{base}/pins"), headers, Some(body)),
    )?;
    Ok(Pin {
        id: pin.id,
        code: pin.code,
    })
}

pub fn check_pin(host: &mut dyn Host, base: &str, pin_id: i64) -> Result<PinStatus, PlexError> {
    let req = request(
        "GET",
        &format!("{base}/pins/{pin_id}"),
        plex_headers(),
        None,
    );
    match send_json::<PinBody>(host, &Auth::None, req) {
        Ok(PinBody {
            auth_token: Some(t),
            ..
        }) if !t.is_empty() => Ok(PinStatus::Authorized(t)),
        Ok(_) => Ok(PinStatus::Pending),
        Err(PlexError::NotFound) => Ok(PinStatus::Expired),
        Err(e) => Err(e),
    }
}

pub fn auth_url(code: &str) -> String {
    format!(
        "{AUTH_BASE}?clientID={}&code={}&{}={}",
        encode(CLIENT_IDENTIFIER),
        encode(code),
        encode("context[device][product]"),
        encode(PRODUCT)
    )
}

pub fn resources(host: &mut dyn Host, base: &str, auth: &Auth) -> Result<Vec<Server>, PlexError> {
    let req = request(
        "GET",
        &format!("{base}/resources?includeHttps=1&includeRelay=1"),
        plex_headers(),
        None,
    );
    let all: Vec<Server> = send_json(host, auth, req)?;
    Ok(all.into_iter().filter(Server::provides_server).collect())
}

/// Owned first, then online, then by name (`Plex.Selection.rank/1`).
pub fn rank(mut servers: Vec<Server>) -> Vec<Server> {
    servers.sort_by(|a, b| {
        (!a.owned, !a.presence, a.name.as_str()).cmp(&(!b.owned, !b.presence, b.name.as_str()))
    });
    servers
}

/// The signed-in account, as a remote account flagged admin.
pub fn account(host: &mut dyn Host, base: &str, auth: &Auth) -> Result<HomeUser, PlexError> {
    let raw: RawUser = send_json(
        host,
        auth,
        request("GET", &format!("{base}/user"), plex_headers(), None),
    )?;
    raw.into_home_user(Some(true))
        .ok_or_else(|| PlexError::Unexpected("plex.tv returned an account without a uuid".into()))
}

/// `None` when the account has no Plex Home (404).
pub fn home_users(
    host: &mut dyn Host,
    base: &str,
    auth: &Auth,
) -> Result<Option<Vec<HomeUser>>, PlexError> {
    let req = request("GET", &format!("{base}/home/users"), plex_headers(), None);
    match send_json::<UsersBody>(host, auth, req) {
        Ok(UsersBody::Wrapped { users }) | Ok(UsersBody::Bare(users)) => Ok(Some(
            users
                .into_iter()
                .filter_map(|u| u.into_home_user(None))
                .collect(),
        )),
        Err(PlexError::NotFound) => Ok(None),
        Err(e) => Err(e),
    }
}

/// Mints a token scoped to one Home profile. No token is an error, never a
/// fallback to the owner's token: that would merge two people's watch state.
pub fn switch_user(
    host: &mut dyn Host,
    base: &str,
    owner_link: &str,
    uuid: &str,
) -> Result<String, PlexError> {
    let req = request(
        "POST",
        &format!("{base}/home/users/{}/switch", encode(uuid)),
        plex_headers(),
        None,
    );
    let body: serde_json::Value = send_json(host, &Auth::Link(owner_link), req)?;
    ["authToken", "authentication_token"]
        .iter()
        .filter_map(|k| body.get(*k).and_then(|v| v.as_str()))
        .find(|t| !t.is_empty())
        .map(str::to_string)
        .ok_or_else(|| {
            PlexError::Unexpected(format!("switch to home user {uuid} returned no token"))
        })
}
#[cfg(test)]
mod tests {
    use super::*;
    use crate::host::fake::FakeHost;

    const TV: &str = "https://plex.tv/api/v2";

    #[test]
    fn create_pin_posts_a_strong_form_with_the_client_identifier() {
        let mut host = FakeHost::new();
        host.respond(
            "POST",
            &format!("{TV}/pins"),
            201,
            r#"{"id":42,"code":"c0de"}"#,
        );
        let pin = create_pin(&mut host, TV).unwrap();
        assert_eq!((pin.id, pin.code.as_str()), (42, "c0de"));
        let sent = &host.sent[0];
        assert_eq!(
            sent.header("Content-Type"),
            Some("application/x-www-form-urlencoded")
        );
        let body = sent.body.as_deref().unwrap();
        assert!(body.contains("strong=true"));
        assert!(body.contains("X-Plex-Client-Identifier=mydia-media-manager"));
    }

    #[test]
    fn check_pin_distinguishes_pending_authorized_and_expired() {
        let mut host = FakeHost::new();
        host.respond(
            "GET",
            &format!("{TV}/pins/1"),
            200,
            r#"{"id":1,"code":"c","authToken":null}"#,
        )
        .respond(
            "GET",
            &format!("{TV}/pins/2"),
            200,
            r#"{"id":2,"code":"c","authToken":""}"#,
        )
        .respond(
            "GET",
            &format!("{TV}/pins/3"),
            200,
            r#"{"id":3,"code":"c","authToken":"acct-token"}"#,
        )
        .respond("GET", &format!("{TV}/pins/4"), 404, "");
        assert!(matches!(
            check_pin(&mut host, TV, 1).unwrap(),
            PinStatus::Pending
        ));
        assert!(matches!(
            check_pin(&mut host, TV, 2).unwrap(),
            PinStatus::Pending
        ));
        assert!(
            matches!(check_pin(&mut host, TV, 3).unwrap(), PinStatus::Authorized(t) if t == "acct-token")
        );
        assert!(matches!(
            check_pin(&mut host, TV, 4).unwrap(),
            PinStatus::Expired
        ));
    }

    #[test]
    fn auth_url_matches_the_native_format() {
        assert_eq!(
            auth_url("c0de"),
            "https://app.plex.tv/auth#?clientID=mydia-media-manager&code=c0de&context%5Bdevice%5D%5Bproduct%5D=Mydia"
        );
    }

    const RESOURCES: &str = r#"[
      {"name":"Player","clientIdentifier":"p1","provides":"player","owned":true,"presence":true,"connections":[]},
      {"name":"Zed Shared","clientIdentifier":"s2","provides":"server","owned":false,"presence":true,"accessToken":"shared-tok",
       "connections":[{"uri":"https://1-2-3-4.s2.plex.direct:32400","local":false,"relay":false,"protocol":"https"}]},
      {"name":"Den","clientIdentifier":"m1","provides":"server,player","owned":true,"presence":false,"accessToken":"den-tok",
       "connections":[{"uri":"http://192.168.1.20:32400","local":true,"relay":false,"protocol":"http"}]},
      {"name":"Attic","clientIdentifier":"m3","provides":"server","owned":true,"presence":true,"connections":[]}
    ]"#;

    #[test]
    fn resources_keeps_only_servers_and_sends_includes() {
        let mut host = FakeHost::new();
        host.respond(
            "GET",
            &format!("{TV}/resources?includeHttps=1&includeRelay=1"),
            200,
            RESOURCES,
        );
        let servers = resources(&mut host, TV, &Auth::Token("acct")).unwrap();
        let names: Vec<_> = servers.iter().map(|s| s.name.as_str()).collect();
        assert_eq!(names, vec!["Zed Shared", "Den", "Attic"]);
        assert_eq!(servers[1].machine_identifier, "m1");
        assert_eq!(servers[1].access_token.as_deref(), Some("den-tok"));
        assert!(servers[1].connections[0].local);
        assert_eq!(host.sent[0].header("X-Plex-Token"), Some("acct"));
    }

    #[test]
    fn rank_orders_owned_then_online_then_name() {
        let mut host = FakeHost::new();
        host.respond(
            "GET",
            &format!("{TV}/resources?includeHttps=1&includeRelay=1"),
            200,
            RESOURCES,
        );
        let ranked = rank(resources(&mut host, TV, &Auth::None).unwrap());
        let names: Vec<_> = ranked.iter().map(|s| s.name.as_str()).collect();
        assert_eq!(names, vec!["Attic", "Den", "Zed Shared"]);
    }

    #[test]
    fn home_users_key_on_uuid_and_fall_back_to_title() {
        let mut host = FakeHost::new();
        host.respond("GET", &format!("{TV}/home/users"), 200, r#"{"users":[
            {"id":14861644,"uuid":"2ed8d606cadd57f0","username":"camille","title":"Camille","admin":true},
            {"id":5,"uuid":"uuid-kid","username":null,"title":"Kiddo","admin":false},
            {"id":6,"username":"no-uuid"}
        ]}"#);
        let users = home_users(&mut host, TV, &Auth::Link("owner"))
            .unwrap()
            .unwrap();
        assert_eq!(
            users,
            vec![
                HomeUser {
                    uuid: "2ed8d606cadd57f0".into(),
                    name: "camille".into(),
                    admin: true
                },
                HomeUser {
                    uuid: "uuid-kid".into(),
                    name: "Kiddo".into(),
                    admin: false
                },
            ]
        );
    }

    #[test]
    fn home_users_accepts_a_bare_list() {
        let mut host = FakeHost::new();
        host.respond(
            "GET",
            &format!("{TV}/home/users"),
            200,
            r#"[{"uuid":"u1","title":"Solo"}]"#,
        );
        assert_eq!(
            home_users(&mut host, TV, &Auth::Link("owner"))
                .unwrap()
                .unwrap()
                .len(),
            1
        );
    }

    #[test]
    fn an_account_without_home_is_none_not_an_error() {
        let mut host = FakeHost::new();
        host.respond("GET", &format!("{TV}/home/users"), 404, "");
        assert_eq!(
            home_users(&mut host, TV, &Auth::Link("owner")).unwrap(),
            None
        );
    }

    #[test]
    fn account_reads_the_signed_in_user_as_admin() {
        let mut host = FakeHost::new();
        host.respond(
            "GET",
            &format!("{TV}/user"),
            200,
            r#"{"id":1,"uuid":"owner-uuid","username":"camille","title":"Camille"}"#,
        );
        assert_eq!(
            account(&mut host, TV, &Auth::Link("owner")).unwrap(),
            HomeUser {
                uuid: "owner-uuid".into(),
                name: "camille".into(),
                admin: true
            }
        );
    }

    #[test]
    fn switch_user_posts_by_uuid_through_the_owner_link() {
        let mut host = FakeHost::new();
        host.respond(
            "POST",
            &format!("{TV}/home/users/uuid-kid/switch"),
            201,
            r#"{"authToken":"kid-token"}"#,
        );
        assert_eq!(
            switch_user(&mut host, TV, "owner", "uuid-kid").unwrap(),
            "kid-token"
        );
        assert_eq!(host.sent[0].link.as_deref(), Some("owner"));
    }

    #[test]
    fn switch_user_accepts_the_legacy_token_field() {
        let mut host = FakeHost::new();
        host.respond(
            "POST",
            &format!("{TV}/home/users/u/switch"),
            200,
            r#"{"authentication_token":"legacy"}"#,
        );
        assert_eq!(switch_user(&mut host, TV, "owner", "u").unwrap(), "legacy");
    }

    #[test]
    fn a_switch_without_a_token_is_an_error_never_a_fallback() {
        let mut host = FakeHost::new();
        host.respond(
            "POST",
            &format!("{TV}/home/users/u/switch"),
            200,
            r#"{"authToken":""}"#,
        )
        .respond("POST", &format!("{TV}/home/users/r/switch"), 403, "");
        assert!(matches!(
            switch_user(&mut host, TV, "owner", "u"),
            Err(PlexError::Unexpected(_))
        ));
        assert_eq!(
            switch_user(&mut host, TV, "owner", "r"),
            Err(PlexError::Unauthorized)
        );
    }
}
