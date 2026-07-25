# WordPress Batch API Hardening

Bash script that finds WordPress installs on **cPanel**, **DirectAdmin**, or **Plesk** servers and installs a single-file plugin that rejects unauthenticated REST batch API (`/batch/v1`) requests.

## Requirements

- Run on the hosting server as **root**
- Bash 4+
- Optional: [WP-CLI](https://wp-cli.org/) **or** PHP CLI (for auto-activation)

WP-CLI is **not** required. If it is missing, the script falls back to PHP CLI. If that also fails, it prints manual wp-admin steps.

## Usage

```bash
chmod +x deploy-disable-batch-api.sh
sudo bash deploy-disable-batch-api.sh
```

Dry run (list sites and intended actions, no changes):

```bash
sudo bash deploy-disable-batch-api.sh --dry-run
```

Verbose discovery output:

```bash
sudo bash deploy-disable-batch-api.sh --verbose
```

### Manual mode (no auto-activation)

Only creates the plugin file and prints how to activate it in wp-admin. Use this when WP-CLI is not installed and you prefer not to use PHP CLI activation:

```bash
sudo bash deploy-disable-batch-api.sh --manual
```

## Activation behavior

| Mode | What happens |
|------|----------------|
| Default | 1) WP-CLI → 2) PHP CLI `activate_plugin()` → 3) print manual steps |
| `--manual` | Create file only; print wp-admin activation steps for each site |

### Manual activation in wp-admin

1. Log into WordPress admin
2. Open **Plugins**
3. Activate **Disable Unauthenticated REST Batch API**

The plugin file path is:

`/path/to/wordpress/wp-content/plugins/disable-batch-api-for-unauth.php`

## What it does

1. Scans common document roots (`/home/*/public_html`, DirectAdmin domain paths, Plesk `httpdocs`, etc.)
2. Locates WordPress installs (`wp-config.php` + `wp-content/`)
3. Writes `wp-content/plugins/disable-batch-api-for-unauth.php`
4. Sets ownership to match the `plugins` directory (`chown --reference`)
5. Activates via WP-CLI or PHP when possible; otherwise instructs you to activate manually

Safe to re-run; the plugin file is overwritten so content stays correct.
