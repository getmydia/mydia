#!/bin/sh
# Stands in for rqbit in Engine tests. Records its pid, its arguments and the
# basic auth variable (and, when FAKE_RQBIT_ENV names a file, its whole
# environment), then behaves as FAKE_RQBIT_MODE says. With `exec`, the
# recorded pid belongs to the final `sleep`.
if [ -n "${FAKE_RQBIT_PID:-}" ]; then
  tmp_pid="${FAKE_RQBIT_PID}.tmp.$$"
  printf '%s\n' "$$" > "$tmp_pid" && mv "$tmp_pid" "$FAKE_RQBIT_PID"
fi

if [ -n "${FAKE_RQBIT_ARGS:-}" ]; then
  tmp_args="${FAKE_RQBIT_ARGS}.tmp.$$"
  {
    printf '%s\n' "$@"
    printf '%s\n' "$RQBIT_HTTP_BASIC_AUTH_USERPASS"
  } > "$tmp_args" && mv "$tmp_args" "$FAKE_RQBIT_ARGS"
fi

if [ -n "${FAKE_RQBIT_ENV:-}" ]; then
  tmp_env="${FAKE_RQBIT_ENV}.tmp.$$"
  env > "$tmp_env" && mv "$tmp_env" "$FAKE_RQBIT_ENV"
fi
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
