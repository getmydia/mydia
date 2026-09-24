#!/bin/sh
# Mydia CLI - Thin wrapper around mix tasks for production containers
set -e

MYDIA_BIN="${MYDIA_BIN:-/app/bin/mydia}"

# Allow MYDIA_BIN to be a command with arguments
run_mydia() {
    $MYDIA_BIN "$@"
}

show_help() {
    cat << 'EOF'
Mydia CLI

Usage: mydia-cli <command> [args...]

Commands:
    user <subcommand>     User management (list, add, delete, reset-password, reset-2fa)
    eval <code>           Evaluate Elixir code
    rpc <code>            Run code via RPC on running node
    remote                Connect to running node via IEx

Examples:
    mydia-cli user list
    mydia-cli user list --role=admin
    mydia-cli user add user@example.com myuser --password=secret --role=admin
    mydia-cli user delete user@example.com
    mydia-cli user reset-password admin --password=newpass
    mydia-cli user reset-2fa admin
    mydia-cli eval 'IO.puts("hello")'
    mydia-cli remote
EOF
}

run_user_command() {
    # Build Elixir list of arguments
    args="["
    first=true
    for arg in "$@"; do
        if [ "$first" = true ]; then
            first=false
        else
            args="$args, "
        fi
        # Escape quotes in argument
        escaped=$(printf '%s' "$arg" | sed 's/\\/\\\\/g; s/"/\\"/g')
        args="$args\"$escaped\""
    done
    args="$args]"

    run_mydia eval "Mix.Tasks.Mydia.User.run($args)"
}

case "${1:-help}" in
    user)
        shift
        run_user_command "$@"
        ;;
    eval)
        shift
        run_mydia eval "$@"
        ;;
    rpc)
        shift
        run_mydia rpc "$@"
        ;;
    remote)
        run_mydia remote
        ;;
    help|--help|-h)
        show_help
        ;;
    *)
        echo "Error: Unknown command '$1'"
        show_help
        exit 1
        ;;
esac
