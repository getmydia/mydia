/// Which locations sit on the root navigator, above the app shell.
library;

/// Whether [location] is a root-navigator screen that opens over the shell:
/// the server management and unlock screens.
///
/// These have no drawer or bottom nav, so their only way out is popping back
/// to what opened them. Reaching one with `go` empties the stack, and on iOS,
/// which has no system back, the viewer is stuck. Push them instead.
bool opensOverShell(String location) =>
    location.startsWith('/sources') || location.startsWith('/unlock');
