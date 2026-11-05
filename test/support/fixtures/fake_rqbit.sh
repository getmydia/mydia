#!/bin/sh
# Stands in for rqbit in Engine tests. Records its arguments and the basic
# auth variable, then behaves as FAKE_RQBIT_MODE says.
printf '%s\n' "$@" > "$FAKE_RQBIT_ARGS"
printf '%s\n' "$RQBIT_HTTP_BASIC_AUTH_USERPASS" >> "$FAKE_RQBIT_ARGS"
case "$FAKE_RQBIT_MODE" in
  exit) exit 3 ;;
  *) exec sleep 600 ;;
esac
