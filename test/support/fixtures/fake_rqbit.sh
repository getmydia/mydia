#!/bin/sh
# Stands in for rqbit in Engine tests. Records its pid, its arguments and the
# basic auth variable, then behaves as FAKE_RQBIT_MODE says. With `exec`, the
# recorded pid belongs to the final `sleep`.
echo $$ > "$FAKE_RQBIT_PID"
printf '%s\n' "$@" > "$FAKE_RQBIT_ARGS"
printf '%s\n' "$RQBIT_HTTP_BASIC_AUTH_USERPASS" >> "$FAKE_RQBIT_ARGS"
case "$FAKE_RQBIT_MODE" in
  exit) exit 3 ;;
  hold)
    # Keeps the shell (and its "rqbit" command line) alive.
    trap 'kill $!; exit 0' TERM
    sleep 600 &
    wait $!
    ;;
  *) exec sleep 600 ;;
esac
