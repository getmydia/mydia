/// plex.tv Plex Home replies, in the shape community documentation gives
/// for `/api/v2/home/users` and `/api/v2/home/users/{uuid}/switch`. Names
/// are invented.
library;

const homeUsersJson = '''
{"id": 1, "name": "Quill's Home", "users": [
  {"id": 11, "uuid": "u1", "title": "Quill", "username": "quill",
   "admin": true, "guest": false, "restricted": false, "protected": false},
  {"id": 12, "uuid": "kid0001", "title": "Pip", "username": "",
   "admin": false, "guest": false, "restricted": true, "protected": true},
  {"id": 13, "uuid": "guest02", "title": "Wren", "username": "",
   "admin": false, "guest": false, "restricted": false, "protected": false},
  {"id": 14, "uuid": "bad:id", "title": "Odd", "admin": false,
   "protected": false}
]}
''';

const kidSwitchJson =
    '{"id": 12, "uuid": "kid0001", "title": "Pip", "authToken": "kid-token"}';

const ownerSwitchJson =
    '{"id": 11, "uuid": "u1", "title": "Quill", "authToken": "owner-switched"}';

const guestSwitchJson =
    '{"id": 13, "uuid": "guest02", "title": "Wren", "authToken": "guest-token"}';

const wrongPinJson =
    '{"errors": [{"code": 1041, "message": "Invalid PIN", "status": 401}]}';

/// What Pip can see: only the Attic.
const kidResourcesJson = '''
[
  {"name": "Attic", "provides": "server", "clientIdentifier": "aa11",
   "owned": false, "presence": true, "accessToken": "kid-server-token",
   "httpsRequired": false,
   "connections": [
     {"uri": "https://10-0-0-5.aa11.plex.direct:32400", "local": true, "relay": false}
   ]}
]
''';

/// What Wren can see: a server nobody chose.
const guestResourcesJson = '''
[
  {"name": "Shed", "provides": "server", "clientIdentifier": "zz99",
   "owned": false, "presence": true, "accessToken": "guest-server-token",
   "httpsRequired": false, "connections": []}
]
''';
