# How Remote Access Works

Mydia's player app can reach your instance from a coffee shop without you
opening a port, buying a domain, configuring dynamic DNS, or running a VPN. That
is a suspiciously large claim for self-hosted software, so this page explains
what is actually happening, what infrastructure is involved, and where the
trade-offs are.

For turning it on and for the symptoms of it not working, see the
[remote access how-to](../how-to/remote-access.md).

## The problem being solved

A self-hosted server is almost always behind NAT. It has no stable public
address, its router will not accept unsolicited inbound connections, and the
person running it frequently cannot change that: they are on carrier-grade NAT,
or they do not administer the router, or they simply do not want to expose a
port to the internet.

The conventional answers all push work onto the operator. Port forwarding
requires router access and a static address or dynamic DNS. A VPN requires
configuring and maintaining one, on the server and on every client. A tunnel
service requires an account with a third party who then sees all your traffic.
Each of these is a reasonable choice and each is a reason someone gives up.

Mydia's position is that remote access should not require the operator to
configure their environment at all. That constraint is what produces the design
below, including the parts that are less than ideal.

## Two paths, tried in order

There are two entirely different ways the player reaches the server, and the app
prefers the cheap one.

**Direct connection.** The instance detects its own reachable addresses (local
network interfaces, a public address if it has one, a configured hostname) and
offers them to paired devices. On the same LAN this is the path that gets used,
and it is a plain HTTPS connection to the server: no intermediary, no overhead,
full local bandwidth. Because a self-hosted instance's certificate is normally
self-signed, the app does not trust the certificate chain; it pins the exact
certificate fingerprint recorded when the device was paired, and refuses anything
else. That is stricter than ordinary HTTPS, not weaker: a substituted
certificate fails even if a public authority signed it.

**The peer-to-peer path.** When direct addresses do not work, which is the
normal case from outside your network, the player and the server talk over a
peer-to-peer connection established with [iroh](https://www.iroh.computer/). The
rest of this page is about that path.

## Identity is a keypair, not an address

Every Mydia instance and every player generates an Ed25519 keypair on first run
and keeps it. The public key is the node's identity: not an IP address, not a
hostname, a key. Instances persist theirs to disk so it survives restarts,
container recreation, and moving to a different network.

This is the design decision everything else follows from. If a node's name is a
key rather than a location, then a node that changes networks has not changed
identity, and "find this instance" becomes a lookup problem rather than an
addressing problem. Your server can move from ethernet to Wi-Fi, get a new DHCP
lease, or be rebuilt behind a different ISP, and a paired phone still knows what
it is looking for.

It also means authentication is free. A connection to a node ID is
cryptographically guaranteed to be a connection to the holder of that private
key. There is nothing to impersonate: an attacker who intercepts the connection
cannot complete it, because they do not have the key that the identity *is*.

## Finding a node whose address you do not know

Knowing a node's key does not tell you where it currently is. Nodes publish
signed records mapping their key to their current addresses and relay, and
resolve each other's records the same way. In the current implementation this
uses iroh's default discovery service, which distributes those records over DNS.

Transport is QUIC, encrypted with TLS 1.3, over UDP. Every byte between the
player and the server is encrypted with keys neither side's network operator has,
and connections carry an application protocol identifier so a Mydia node only
speaks to another Mydia node.

## The relay, and why "no central server" would be a lie

Two nodes behind NAT cannot simply call each other. Something with a public
address has to introduce them, and that something is a relay.

Mydia ships with a relay it operates and iroh's public relays as fallback. When
your instance comes online it connects to a relay and stays connected. When a
player wants to reach it, the connection is established through the relay
immediately, and then both sides attempt hole punching: they exchange address
observations and try to establish a direct UDP path between the two networks.
When that works, and it usually does, traffic moves onto the direct path and the
relay drops out of the data flow. When it does not work, which happens behind
symmetric NAT and some corporate firewalls, the relay keeps carrying the traffic
for the life of the connection. The app reports which of these you are on.

This is worth being precise about, because "decentralised, no central server" is
a claim self-hosted projects like to make and it is rarely fully true. Mydia
depends on infrastructure the project runs: a relay for introductions and
fallback transport, a discovery service for resolving keys to addresses, and a
pairing service that issues claim codes. If all of that vanished, existing
direct-address connections on your own LAN would keep working and new
peer-to-peer connections from outside would not.

What the relay does *not* do is see your data. It forwards encrypted QUIC to a
key it cannot decrypt for. It is a dumb pipe with a public IP, which is why
Mydia can afford to run it, and why pointing your instance at a different one
(including your own) is a configuration change rather than a trust decision.

The honest summary is: the connection is end-to-end encrypted and usually
direct; the *bootstrap* is not decentralised, and the fallback path is not
direct. Anyone claiming a NAT-traversal system with none of these dependencies
is either running a VPN or leaving something out.

## Claim codes

A **claim code** is the short, single-use string you generate on the server and
type into the player to pair a new device. It is eight characters drawn from an
alphabet with the ambiguous ones removed, so it can be read off a screen or
dictated over a phone without confusing zero for O.

Its job is to solve a bootstrapping problem: a node ID is a long, unreadable key,
and nobody is typing one into a phone. So the instance hands its node address to
the pairing service, which returns a short code standing in for it. The player
sends the code back, learns where to connect, and the two sides complete the
pairing.

That indirection is why claim codes are aggressively short-lived. A code is valid
for **five minutes**, works exactly once, and validation is rate-limited per
source address. A short code has very little entropy, so the only thing keeping
it from being guessable is that the window to guess it is tiny. This is the same
reasoning behind a bank's SMS code expiring in a few minutes rather than a day.

The pairing conversation is the only time a code matters. Once a device is
paired, it holds a device token, and that token, not the code, is what
authenticates it from then on. This is also why the five-minute expiry is a
frequent cause of failed pairings: a code generated, left on screen while
someone finds their phone, and typed in eight minutes later is simply expired,
and the failure looks the same as a network problem. Generating a fresh one is
usually the whole fix.

## Media over the same connection

Video does not get a separate channel. The player runs a small HTTP server on
its own loopback interface and points the video player at it; that local server
translates each HLS manifest and segment request into a request over the
peer-to-peer connection and streams the response back.

The reason for the indirection is unglamorous: platform video players want to be
handed a URL, and "a QUIC stream to an Ed25519 public key" is not a URL. A local
proxy is the adapter between what the transport provides and what the media
stack expects. It also means seeking, bitrate switching, and buffering behave
normally, because as far as the video player is concerned it is fetching HLS
over HTTP from localhost.

Two consequences follow. Streaming performance depends on whether the connection
went direct or stayed on the relay, which is not something the video player can
tell you but the app can. And **playback is a player concern, not a server
concern**: Mydia's web interface manages your library, it does not play video,
and the peer-to-peer path exists to carry media to the app rather than to a
browser.

## One core, two languages

The networking code is a single Rust crate. The Elixir server uses it through a
native interface function; the Flutter player uses it through a generated Dart
binding. Same crate, same protocol logic, same version.

This is a deliberate choice against the more usual arrangement of a server
implementation and a client implementation that are supposed to agree. Protocol
bugs between two implementations of the same spec are miserable to find, because
each side is behaving correctly by its own reading. With one implementation there
is no reading to disagree about: if the handshake changes, it changes for both
sides at once, and a mismatch is a build error rather than a support ticket six
months later.

The cost is that the Rust core is on the critical path for both the server and
every player platform, so every target has to be able to build it. That is a real
constraint on the project and it is the reason the p2p code moves more slowly and
more carefully than the rest of Mydia.

## Where to go next

- [Remote access how-to](../how-to/remote-access.md) for enabling it and for
  troubleshooting.
- [Putting Mydia behind a reverse proxy](../how-to/reverse-proxy.md) if you would
  rather expose the web interface conventionally.
- [How Mydia runs](how-mydia-runs.md) for the deployment model this assumes.
