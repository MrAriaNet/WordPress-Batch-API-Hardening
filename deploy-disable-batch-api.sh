#!/usr/bin/env bash
#
# deploy-disable-batch-api.sh
# Discover WordPress installs on cPanel, DirectAdmin, or Plesk and install a
# single-file plugin that blocks unauthenticated REST batch API requests.
#
# Usage:
#   sudo bash deploy-disable-batch-api.sh [--dry-run] [--verbose] [--manual]
#
# Must be run as root on the hosting server.
#
# Activation order (unless --manual):
#   1) WP-CLI if installed
#   2) PHP CLI + activate_plugin() fallback
#   3) Print manual wp-admin steps if both fail
#

set -euo pipefail

PLUGIN_BASENAME="disable-batch-api-for-unauth.php"
PLUGIN_SLUG="disable-batch-api-for-unauth"
FIND_MAXDEPTH=6

DRY_RUN=0
VERBOSE=0
MANUAL=0

COUNT_PROCESSED=0
COUNT_CREATED=0
COUNT_ACTIVATED=0
COUNT_FAILED=0
COUNT_SKIPPED=0
COUNT_MANUAL=0

log() {
    printf '%s\n' "$*"
}

log_verbose() {
    if [[ "$VERBOSE" -eq 1 ]]; then
        printf '[verbose] %s\n' "$*"
    fi
}

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

usage() {
    cat <<'USAGE'
Usage: sudo bash deploy-disable-batch-api.sh [OPTIONS]

Discover WordPress sites on cPanel / DirectAdmin / Plesk and install
disable-batch-api-for-unauth.php under wp-content/plugins/.

Options:
  --dry-run    Show what would be done without writing files
  --verbose    Print extra discovery and path details
  --manual     Only create the plugin file; skip auto-activation and print
               wp-admin steps (use when WP-CLI / PHP CLI activation is unwanted)
  -h, --help   Show this help and exit

Without --manual, activation tries WP-CLI first, then PHP CLI.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=1
            shift
            ;;
        --verbose)
            VERBOSE=1
            shift
            ;;
        --manual)
            MANUAL=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "Unknown option: $1 (use --help)"
            ;;
    esac
done

if [[ "${EUID:-$(id -u)}" -ne 0 ]]; then
    die "This script must be run as root."
fi

# Write the plugin body to the given path.
write_plugin_file() {
    local dest="$1"
    cat >"$dest" <<'EOF'
<?php
/**
 * Plugin Name: Disable Unauthenticated REST Batch API
 * Description: Requires an authenticated WordPress user for REST batch requests.
 * Version: 1.0.0
 * Requires at least: 5.6
 * License: GPL-2.0-or-later
 */

defined( 'ABSPATH' ) || exit;

/**
 * Reject anonymous requests to the core REST batch endpoint.
 *
 * @param mixed           $result  Pre-calculated dispatch result.
 * @param WP_REST_Server  $server  REST server instance.
 * @param WP_REST_Request $request Current REST request.
 * @return mixed|WP_Error
 */
function wporg_require_authentication_for_rest_batch( $result, $server, $request ) {
    if ( '/batch/v1' !== strtolower( untrailingslashit( $request->get_route() ) ) || is_user_logged_in() ) {
        return $result;
    }

    return new WP_Error(
        'rest_batch_authentication_required',
        'Authentication is required to use the batch API.',
        array( 'status' => 401 )
    );
}

add_filter( 'rest_pre_dispatch', 'wporg_require_authentication_for_rest_batch', -1000, 3 );
EOF
}

# Collect panel-style roots that exist on this server.
collect_search_roots() {
    local roots=()
    local path
    local old_nullglob

    old_nullglob="$(shopt -p nullglob || true)"
    shopt -s nullglob

    # cPanel / DirectAdmin style homes
    if [[ -d /home ]]; then
        for path in /home/*/public_html /home/*/www /home/*/domains/*/public_html; do
            [[ -d "$path" ]] || continue
            roots+=("$path")
        done
    fi

    # Plesk vhosts
    if [[ -d /var/www/vhosts ]]; then
        for path in \
            /var/www/vhosts/*/httpdocs \
            /var/www/vhosts/*/subdomains/*/httpdocs \
            /var/www/vhosts/*/httpdocs/wordpress; do
            [[ -d "$path" ]] || continue
            roots+=("$path")
        done
    fi

    eval "$old_nullglob" 2>/dev/null || shopt -u nullglob

    # Fallback: common web roots if no panel paths were found
    if [[ ${#roots[@]} -eq 0 ]]; then
        for path in /var/www/html /usr/share/nginx/html /srv/www; do
            [[ -d "$path" ]] || continue
            roots+=("$path")
        done
    fi

    if [[ ${#roots[@]} -gt 0 ]]; then
        printf '%s\n' "${roots[@]}"
    fi
}

# Find WordPress install roots (directories containing wp-config.php + wp-content).
discover_wordpress_installs() {
    local -A seen=()
    local root config wp_root real
    local roots

    mapfile -t roots < <(collect_search_roots | sort -u)

    if [[ ${#roots[@]} -eq 0 ]]; then
        log "No panel document-root paths found to search."
        return 0
    fi

    log_verbose "Searching ${#roots[@]} document-root path(s) (maxdepth=${FIND_MAXDEPTH})"

    for root in "${roots[@]}"; do
        log_verbose "Scanning: $root"
        while IFS= read -r -d '' config; do
            wp_root="$(dirname "$config")"
            if [[ ! -d "$wp_root/wp-content" ]]; then
                log_verbose "Skipping (no wp-content): $wp_root"
                continue
            fi
            if command -v realpath >/dev/null 2>&1; then
                real="$(realpath "$wp_root")"
            else
                real="$(cd "$wp_root" && pwd -P)"
            fi
            if [[ -n "${seen[$real]+x}" ]]; then
                continue
            fi
            seen[$real]=1
            printf '%s\n' "$real"
        done < <(find "$root" -maxdepth "$FIND_MAXDEPTH" -type f -name 'wp-config.php' -print0 2>/dev/null)
    done
}

print_manual_activation_steps() {
    local wp_root="$1"
    log "  MANUAL activation required for: $wp_root"
    log "    1. Log into WordPress admin (wp-admin)"
    log "    2. Go to Plugins"
    log "    3. Activate \"Disable Unauthenticated REST Batch API\""
    log "    File: ${wp_root}/wp-content/plugins/${PLUGIN_BASENAME}"
}

# Prefer panel PHP binaries when plain `php` is missing or wrong.
resolve_php_bin() {
    local candidate
    local candidates=(
        php
        php84 php83 php82 php81 php80 php74
        /usr/local/bin/php
        /usr/bin/php
        /opt/cpanel/ea-php84/root/usr/bin/php
        /opt/cpanel/ea-php83/root/usr/bin/php
        /opt/cpanel/ea-php82/root/usr/bin/php
        /opt/cpanel/ea-php81/root/usr/bin/php
        /opt/cpanel/ea-php80/root/usr/bin/php
        /opt/cpanel/ea-php74/root/usr/bin/php
        /usr/local/php84/bin/php
        /usr/local/php83/bin/php
        /usr/local/php82/bin/php
        /usr/local/php81/bin/php
        /opt/plesk/php/8.3/bin/php
        /opt/plesk/php/8.2/bin/php
        /opt/plesk/php/8.1/bin/php
        /opt/plesk/php/8.0/bin/php
        /opt/plesk/php/7.4/bin/php
    )

    for candidate in "${candidates[@]}"; do
        if [[ "$candidate" == */* ]]; then
            [[ -x "$candidate" ]] || continue
            printf '%s\n' "$candidate"
            return 0
        fi
        if command -v "$candidate" >/dev/null 2>&1; then
            command -v "$candidate"
            return 0
        fi
    done
    return 1
}

activate_plugin_via_wpcli() {
    local wp_root="$1"

    command -v wp >/dev/null 2>&1 || return 1

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "  [dry-run] would run: wp plugin activate ${PLUGIN_SLUG} --path=${wp_root} --allow-root"
        return 0
    fi

    if wp plugin activate "$PLUGIN_SLUG" --path="$wp_root" --allow-root >/dev/null 2>&1; then
        log "  Activated plugin via WP-CLI"
        return 0
    fi

    if wp plugin is-active "$PLUGIN_SLUG" --path="$wp_root" --allow-root >/dev/null 2>&1; then
        log "  Plugin already active (WP-CLI)"
        return 0
    fi

    log_verbose "WP-CLI activate failed for: $wp_root"
    return 1
}

activate_plugin_via_php() {
    local wp_root="$1"
    local php_bin
    local out

    if ! php_bin="$(resolve_php_bin)"; then
        log_verbose "No PHP CLI binary found for activation"
        return 1
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "  [dry-run] would activate via PHP (${php_bin}): ${PLUGIN_BASENAME}"
        return 0
    fi

    # Load WordPress and call activate_plugin() without WP-CLI.
    if ! out="$(
        WP_ROOT="$wp_root" PLUGIN_FILE="$PLUGIN_BASENAME" "$php_bin" -d display_errors=0 -r '
            $wp_root = getenv("WP_ROOT");
            $plugin  = getenv("PLUGIN_FILE");
            if ($wp_root === false || $plugin === false || $wp_root === "" || $plugin === "") {
                fwrite(STDERR, "missing env\n");
                exit(2);
            }
            if (!is_readable($wp_root . "/wp-load.php")) {
                fwrite(STDERR, "wp-load.php not readable\n");
                exit(2);
            }
            $_SERVER["HTTP_HOST"] = "localhost";
            $_SERVER["REQUEST_URI"] = "/";
            define("WP_USE_THEMES", false);
            require $wp_root . "/wp-load.php";
            require_once ABSPATH . "wp-admin/includes/plugin.php";
            if (is_plugin_active($plugin)) {
                echo "already_active\n";
                exit(0);
            }
            $result = activate_plugin($plugin);
            if (is_wp_error($result)) {
                fwrite(STDERR, $result->get_error_message() . "\n");
                exit(1);
            }
            echo "activated\n";
            exit(0);
        ' 2>&1
    )"; then
        log_verbose "PHP activation failed for ${wp_root}: ${out}"
        return 1
    fi

    if [[ "$out" == *already_active* ]]; then
        log "  Plugin already active (PHP)"
        return 0
    fi

    log "  Activated plugin via PHP (${php_bin})"
    return 0
}

activate_plugin() {
    local wp_root="$1"

    if [[ "$MANUAL" -eq 1 ]]; then
        if [[ "$DRY_RUN" -eq 1 ]]; then
            log "  [dry-run] would skip auto-activation (--manual)"
        fi
        print_manual_activation_steps "$wp_root"
        return 2
    fi

    if activate_plugin_via_wpcli "$wp_root"; then
        return 0
    fi

    if ! command -v wp >/dev/null 2>&1; then
        log "  WP-CLI not found; trying PHP CLI activation..."
    else
        log "  WP-CLI activation failed; trying PHP CLI activation..."
    fi

    if activate_plugin_via_php "$wp_root"; then
        return 0
    fi

    print_manual_activation_steps "$wp_root"
    return 1
}

process_install() {
    local wp_root="$1"
    local plugins_dir="${wp_root}/wp-content/plugins"
    local target="${plugins_dir}/${PLUGIN_BASENAME}"
    local activate_rc=0

    COUNT_PROCESSED=$((COUNT_PROCESSED + 1))
    log "Processing: $wp_root"

    if [[ ! -d "$plugins_dir" ]]; then
        log "  SKIP: plugins directory missing"
        COUNT_SKIPPED=$((COUNT_SKIPPED + 1))
        return 0
    fi

    if [[ ! -w "$plugins_dir" && "$DRY_RUN" -eq 0 ]]; then
        log "  FAIL: plugins directory not writable"
        COUNT_FAILED=$((COUNT_FAILED + 1))
        return 0
    fi

    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "  [dry-run] would write: $target"
        log "  [dry-run] would chown --reference=${plugins_dir} ${target}"
        COUNT_CREATED=$((COUNT_CREATED + 1))
        activate_plugin "$wp_root" || activate_rc=$?
        if [[ "$activate_rc" -eq 0 ]]; then
            COUNT_ACTIVATED=$((COUNT_ACTIVATED + 1))
        else
            COUNT_MANUAL=$((COUNT_MANUAL + 1))
        fi
        return 0
    fi

    if ! write_plugin_file "$target"; then
        log "  FAIL: could not write plugin file"
        COUNT_FAILED=$((COUNT_FAILED + 1))
        return 0
    fi

    chmod 0644 "$target" || true

    if ! chown --reference="$plugins_dir" "$target"; then
        log "  FAIL: could not set ownership on $target"
        COUNT_FAILED=$((COUNT_FAILED + 1))
        return 0
    fi

    local owner
    owner="$(stat -c '%U:%G' "$target" 2>/dev/null || echo 'unknown')"
    log "  OK: wrote $target (owner ${owner})"
    COUNT_CREATED=$((COUNT_CREATED + 1))

    activate_plugin "$wp_root" || activate_rc=$?
    if [[ "$activate_rc" -eq 0 ]]; then
        COUNT_ACTIVATED=$((COUNT_ACTIVATED + 1))
    else
        COUNT_MANUAL=$((COUNT_MANUAL + 1))
    fi
}

main() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "Mode: dry-run (no files will be modified)"
    fi
    if [[ "$MANUAL" -eq 1 ]]; then
        log "Mode: manual (plugin file only; activate in wp-admin yourself)"
    fi

    local installs=()
    mapfile -t installs < <(discover_wordpress_installs | sort -u)

    if [[ ${#installs[@]} -eq 0 ]]; then
        log "No WordPress installs found."
        exit 0
    fi

    log "Found ${#installs[@]} WordPress install(s)."
    log ""

    local wp_root
    for wp_root in "${installs[@]}"; do
        [[ -n "$wp_root" ]] || continue
        process_install "$wp_root"
        log ""
    done

    log "========== Summary =========="
    log "Processed : ${COUNT_PROCESSED}"
    log "Created   : ${COUNT_CREATED}"
    log "Activated : ${COUNT_ACTIVATED}"
    log "Manual    : ${COUNT_MANUAL}"
    log "Skipped   : ${COUNT_SKIPPED}"
    log "Failed    : ${COUNT_FAILED}"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        log "(dry-run — no changes were made)"
    fi
    if [[ "$COUNT_MANUAL" -gt 0 ]]; then
        log "Note: sites listed under Manual need activation in wp-admin (Plugins screen)."
    fi
}

main
