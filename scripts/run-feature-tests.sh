#!/usr/bin/env bash
set -euo pipefail

# Feature Tests Runner
# Works in both Docker containers and GitHub Actions
#
# Usage:
#   ./scripts/run-feature-tests.sh           # Run all feature tests
#   ./scripts/run-feature-tests.sh --setup   # Only install Chrome/ChromeDriver
#   ./scripts/run-feature-tests.sh path/to/test.exs  # Run specific test file

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Detect environment
detect_environment() {
    if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
        echo "github-actions"
    elif [[ -f /.dockerenv ]] || grep -q docker /proc/1/cgroup 2>/dev/null; then
        echo "docker"
    else
        echo "local"
    fi
}

# Check if Chrome is installed and get version
get_chrome_version() {
    # CHROME_PATH first, mirroring how the chromedriver helpers below prefer
    # CHROMEDRIVER_PATH. devenv points both at its own pinned chromium. Without
    # this, a GitHub runner's system google-chrome — which tracks stable and
    # moves independently of nixpkgs — gets compared against devenv's pinned
    # chromedriver, and the version check aborts before any test runs.
    if [[ -n "${CHROME_PATH:-}" ]] && [[ -x "${CHROME_PATH}" ]]; then
        "$CHROME_PATH" --version | grep -oP '\d+\.\d+\.\d+' || true
    elif command -v google-chrome &>/dev/null; then
        google-chrome --version | grep -oP '\d+\.\d+\.\d+' || true
    elif command -v chromium &>/dev/null; then
        chromium --version | grep -oP '\d+\.\d+\.\d+' || true
    elif command -v chromium-browser &>/dev/null; then
        chromium-browser --version | grep -oP '\d+\.\d+\.\d+' || true
    fi
}

# Check if ChromeDriver is installed and get version
get_chromedriver_version() {
    local chromedriver_bin="${CHROMEDRIVER_PATH:-}"

    # Try common chromedriver locations
    if [[ -n "$chromedriver_bin" ]] && [[ -x "$chromedriver_bin" ]]; then
        "$chromedriver_bin" --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || true
    elif command -v chromedriver &>/dev/null; then
        chromedriver --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' || true
    fi
}

# Find chromedriver binary
find_chromedriver() {
    if [[ -n "${CHROMEDRIVER_PATH:-}" ]] && [[ -x "${CHROMEDRIVER_PATH}" ]]; then
        echo "$CHROMEDRIVER_PATH"
    elif command -v chromedriver &>/dev/null; then
        command -v chromedriver
    elif [[ -x /usr/bin/chromedriver ]]; then
        echo "/usr/bin/chromedriver"
    elif [[ -x /usr/local/bin/chromedriver ]]; then
        echo "/usr/local/bin/chromedriver"
    fi
}

# Install Chrome (Debian/Ubuntu)
install_chrome() {
    log_info "Installing Google Chrome..."

    # Check if already installed
    if command -v google-chrome &>/dev/null; then
        log_info "Chrome already installed: $(google-chrome --version)"
        return 0
    fi

    # Install dependencies
    apt-get update -qq
    apt-get install -y -qq wget gnupg2 ca-certificates

    # Add Google Chrome repository
    wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | apt-key add -
    echo "deb [arch=amd64] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list

    # Install Chrome
    apt-get update -qq
    apt-get install -y -qq google-chrome-stable

    log_info "Chrome installed: $(google-chrome --version)"
}

# Install ChromeDriver matching Chrome version
install_chromedriver() {
    local chrome_version="${1:-}"

    if [[ -z "$chrome_version" ]]; then
        chrome_version=$(get_chrome_version)
    fi

    if [[ -z "$chrome_version" ]]; then
        log_error "Chrome not installed. Cannot determine ChromeDriver version."
        return 1
    fi

    local chrome_major="${chrome_version%%.*}"
    log_info "Installing ChromeDriver for Chrome $chrome_version (major: $chrome_major)..."

    # Create temp directory for download
    local tmp_dir
    tmp_dir=$(mktemp -d)
    cd "$tmp_dir"

    # Try Chrome for Testing endpoint (Chrome 115+)
    local chromedriver_url="https://storage.googleapis.com/chrome-for-testing-public/${chrome_version}.0/linux64/chromedriver-linux64.zip"

    if ! curl -sL "$chromedriver_url" -o chromedriver.zip 2>/dev/null || [[ ! -s chromedriver.zip ]]; then
        log_info "Exact version not found, fetching latest for major version $chrome_major..."

        local latest_version
        latest_version=$(curl -sS "https://googlechromelabs.github.io/chrome-for-testing/LATEST_RELEASE_${chrome_major}" 2>/dev/null || true)

        if [[ -n "$latest_version" ]]; then
            chromedriver_url="https://storage.googleapis.com/chrome-for-testing-public/${latest_version}/linux64/chromedriver-linux64.zip"
            curl -sL "$chromedriver_url" -o chromedriver.zip
        else
            log_error "Could not find ChromeDriver for Chrome $chrome_major"
            cd "$PROJECT_ROOT"
            rm -rf "$tmp_dir"
            return 1
        fi
    fi

    # Extract and install
    unzip -q chromedriver.zip

    # Handle both old and new zip structures
    if [[ -f chromedriver-linux64/chromedriver ]]; then
        mv chromedriver-linux64/chromedriver /usr/local/bin/
    elif [[ -f chromedriver ]]; then
        mv chromedriver /usr/local/bin/
    fi

    chmod +x /usr/local/bin/chromedriver

    # Cleanup
    cd "$PROJECT_ROOT"
    rm -rf "$tmp_dir"

    log_info "ChromeDriver installed: $(chromedriver --version)"
}

# Verify Chrome and ChromeDriver versions match
verify_versions() {
    local chrome_version chromedriver_version
    chrome_version=$(get_chrome_version)
    chromedriver_version=$(get_chromedriver_version)

    if [[ -z "$chrome_version" ]]; then
        log_error "Chrome not found"
        return 1
    fi

    if [[ -z "$chromedriver_version" ]]; then
        log_error "ChromeDriver not found"
        return 1
    fi

    local chrome_major="${chrome_version%%.*}"
    local chromedriver_major="${chromedriver_version%%.*}"

    if [[ "$chrome_major" != "$chromedriver_major" ]]; then
        log_error "Version mismatch: Chrome $chrome_version vs ChromeDriver $chromedriver_version"
        return 1
    fi

    log_info "Versions match: Chrome $chrome_version, ChromeDriver $chromedriver_version"
    return 0
}

# Setup Chrome and ChromeDriver
setup_browser() {
    local env
    env=$(detect_environment)
    log_info "Detected environment: $env"

    # Check if Chrome/Chromium and matching ChromeDriver are already available
    if verify_versions 2>/dev/null; then
        log_info "Browser and ChromeDriver already configured correctly"
        return 0
    fi

    case "$env" in
        github-actions)
            # In GitHub Actions, Chrome is installed via action, just need ChromeDriver
            install_chromedriver
            ;;
        docker|local)
            # In Docker or local, may need to install both
            local chrome_version
            chrome_version=$(get_chrome_version)

            if [[ -z "$chrome_version" ]]; then
                log_info "No Chrome/Chromium found, installing..."
                install_chrome
            fi

            if ! verify_versions 2>/dev/null; then
                log_info "ChromeDriver version mismatch or missing, installing..."
                install_chromedriver
            fi
            ;;
    esac

    verify_versions
}

# Run the feature tests
run_tests() {
    local test_args=("$@")

    cd "$PROJECT_ROOT"

    # Set ChromeDriver path for Wallaby
    local chromedriver_bin
    chromedriver_bin=$(find_chromedriver)
    if [[ -n "$chromedriver_bin" ]]; then
        export CHROMEDRIVER_PATH="$chromedriver_bin"
        log_info "Using ChromeDriver at: $CHROMEDRIVER_PATH"
    else
        log_error "ChromeDriver not found!"
        exit 1
    fi

    # Ensure headless mode
    export WALLABY_HEADLESS="${WALLABY_HEADLESS:-true}"

    # Setup database if needed
    if [[ "${SKIP_DB_SETUP:-}" != "true" ]]; then
        log_info "Setting up test database..."
        mix ecto.create --quiet 2>/dev/null || true
        mix ecto.migrate --quiet
    fi

    # Run tests
    log_info "Running feature tests..."
    if [[ ${#test_args[@]} -gt 0 ]]; then
        mix test "${test_args[@]}"
    else
        mix test --only feature
    fi
}

# Main
main() {
    local setup_only=false
    local test_args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --setup)
                setup_only=true
                shift
                ;;
            --help|-h)
                echo "Usage: $0 [OPTIONS] [TEST_FILES...]"
                echo ""
                echo "Options:"
                echo "  --setup     Only install Chrome and ChromeDriver, don't run tests"
                echo "  --help      Show this help message"
                echo ""
                echo "Environment variables:"
                echo "  SKIP_DB_SETUP=true    Skip database setup"
                echo "  WALLABY_HEADLESS=false  Run with visible browser (for debugging)"
                echo ""
                echo "Examples:"
                echo "  $0                                    # Run all feature tests"
                echo "  $0 test/mydia_web/features/auth_test.exs  # Run specific test"
                echo "  $0 --setup                            # Only install browser"
                exit 0
                ;;
            *)
                test_args+=("$1")
                shift
                ;;
        esac
    done

    setup_browser

    if [[ "$setup_only" == "true" ]]; then
        log_info "Setup complete. Skipping tests."
        exit 0
    fi

    run_tests "${test_args[@]}"
}

main "$@"
