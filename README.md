# Cloud-Init Post-Deployment Framework

A modular automation framework for configuring Linux servers after initial deployment. Designed for use with Proxmox Cloud-Init VMs, but works with any Linux system that can execute a bootstrap script.

## Problem Statement

When deploying virtual machines at scale, the initial OS installation is only the beginning. Each server requires consistent post-deployment configuration:

- Package installation
- Network configuration (static IPs, VLANs)
- User management and SSH key deployment
- Service registration (DNS, DHCP, monitoring)
- Security hardening (firewall, SSH configuration)

Manually performing these tasks is error-prone and time-consuming. This framework automates the entire post-deployment process with a single command.

## How It Works

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                              PROXMOX HOST                                   │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  Cloud-Init VM Template                                               │  │
│  │  - Base OS (Debian/Ubuntu)                                            │  │
│  │  - Cloud-Init configured with bootstrap command                       │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      │ VM Clone & Start
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                              NEW VM INSTANCE                                │
│                                                                             │
│  1. Cloud-Init runs on first boot                                          │
│  2. Executes bootstrap command (see Quick Start below)                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      │ Bootstrap Downloads Scripts
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           GITHUB REPOSITORY                                 │
│  ┌───────────────────────────────────────────────────────────────────────┐  │
│  │  Scripts/Bash/                                                        │  │
│  │  ├── 000-Packages.sh                                                  │  │
│  │  ├── 001-Variables.sh                                                 │  │
│  │  ├── 002-Directories.sh                                               │  │
│  │  ├── ...                                                              │  │
│  │  └── 100-Firewall.sh                                                  │  │
│  └───────────────────────────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────────────────────────┘
                                      │
                                      │ Execute in Order (000 → 100)
                                      ▼
┌─────────────────────────────────────────────────────────────────────────────┐
│                           CONFIGURED SERVER                                 │
│                                                                             │
│  ✓ Packages installed                                                       │
│  ✓ Network configured                                                       │
│  ✓ Users created with SSH keys                                              │
│  ✓ Services registered                                                      │
│  ✓ Firewall enabled                                                         │
│  ✓ Ready for production                                                     │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Key Features

- **Numbered Execution Order** - Scripts run sequentially (000, 001, 002...) ensuring dependencies are met
- **Hostname-Based Targeting** - Include/exclude patterns control which scripts run on which hosts
- **Idempotent Operations** - Scripts can be re-run safely without causing duplicate changes
- **Centralized Logging** - All script output captured to log files for troubleshooting
- **Private Repository Support** - Authenticates with GitHub API for private repos
- **Sparse Checkout** - Only downloads required scripts, not the entire repository

## Quick Start

**One-liner (public repo - downloads entire repo):**

```bash
curl -fsSL https://raw.githubusercontent.com/Grace-Solutions/Cloud-Init-PostDeployment/main/PostDeploymentBootstrapper.sh | bash
```

**One-liner (private repo - downloads entire repo):**

```bash
curl -fsSL https://raw.githubusercontent.com/Grace-Solutions/Cloud-Init-PostDeployment/main/PostDeploymentBootstrapper.sh | bash -s -- --token "ghp_your_token" --repo "your-org/your-repo"
```

**With sparse checkout (download only a subfolder):**

```bash
curl -fsSL https://raw.githubusercontent.com/Grace-Solutions/Cloud-Init-PostDeployment/main/PostDeploymentBootstrapper.sh | bash -s -- --token "ghp_your_token" --repo "your-org/Cloud-Init" --path "Customers/Production/PostDeployment"
```

### Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `--token` | (none) | GitHub personal access token for private repos |
| `--repo` | `Grace-Solutions/Cloud-Init-PostDeployment` | GitHub repository (owner/repo) |
| `--branch` | `main` | Branch to clone |
| `--path` | `.` | Subfolder path for sparse checkout (`.` = entire repo) |
| `--dest` | `/opt/Cloud-Init-PostDeployment/` | Local destination directory |

## Repository Structure

```
Cloud-Init-PostDeployment/
├── PostDeploymentBootstrapper.sh    # Main entry point
├── Scripts/
│   ├── Bash/                        # Linux scripts (###-Name.sh)
│   └── PowerShell/                  # Windows scripts (###-Name.ps1)
├── Functions/                       # Shared functions
├── Template/                        # Script templates
├── LICENSE
└── README.md
```

## Script Conventions

| Pattern | Description |
|---------|-------------|
| `000-099` | Core configuration (packages, network, users) |
| `097-099` | Agent registration (monitoring, remote access) |
| `100` | Firewall (runs last to avoid lockout) |

Each script includes:
- `ENABLED` flag to enable/disable
- `INCLUDE_PATTERN` regex for hostname matching
- `EXCLUDE_PATTERN` regex for hostname exclusion

## Setting Up a Private Repository

For production use, keep your configuration scripts and secrets in a private repository. The bootstrapper can be fetched directly from the GitHub API using a personal access token.

### Step 1: Create a Private Repository

1. Go to [github.com/new](https://github.com/new)
2. Name your repository (e.g., `Cloud-Init-PostDeployment`)
3. Select **Private**
4. Click **Create repository**
5. Clone this public repo and push to your private repo:

```bash
git clone https://github.com/Grace-Solutions/Cloud-Init-PostDeployment.git
cd Cloud-Init-PostDeployment
git remote set-url origin https://github.com/your-username/your-private-repo.git
git push -u origin main
```

### Step 2: Create a Personal Access Token

1. Go to GitHub → **Settings** → **Developer settings** → **Personal access tokens** → **Tokens (classic)**
2. Click **Generate new token (classic)**
3. Give it a descriptive name (e.g., `cloud-init-bootstrap`)
4. Set expiration as needed
5. Select scope: `repo` (Full control of private repositories)
6. Click **Generate token**
7. **Copy the token immediately** - you won't see it again!

### Step 3: Fetch Scripts via GitHub API

For fully private setups, fetch the bootstrapper directly from the GitHub API:

```bash
# GitHub API configuration
TOKEN="ghp_your_personal_access_token"
USERNAME="your-github-username"
REPO="your-repo-name"
BRANCH="main"
SCRIPT_PATH="PostDeploymentBootstrapper.sh"

# Fetch and execute the bootstrapper
curl -fsSL \
  -H "Authorization: token ${TOKEN}" \
  -H "Accept: application/vnd.github.v3.raw" \
  "https://api.github.com/repos/${USERNAME}/${REPO}/contents/${SCRIPT_PATH}?ref=${BRANCH}" \
  | bash -s -- --token "${TOKEN}" --repo "${USERNAME}/${REPO}"
```

### Cloud-Init Configuration Example

Add this to your Proxmox Cloud-Init custom script or user-data:

```yaml
#cloud-config
runcmd:
  - |
    TOKEN="ghp_your_token"
    USERNAME="your-username"
    REPO="your-repo"
    BRANCH="main"
    curl -fsSL \
      -H "Authorization: token ${TOKEN}" \
      -H "Accept: application/vnd.github.v3.raw" \
      "https://api.github.com/repos/${USERNAME}/${REPO}/contents/PostDeploymentBootstrapper.sh?ref=${BRANCH}" \
      | bash -s -- --token "${TOKEN}" --repo "${USERNAME}/${REPO}"
```

### JSON Configuration for Automation

For integration with automation tools, use this configuration structure:

```json
{
  "github": {
    "personalAccessToken": "ghp_your_token",
    "username": "your-github-username",
    "repo": "your-repo-name",
    "rootUrl": "https://api.github.com/repos",
    "contents": "contents",
    "query": "?ref=",
    "branch": "main",
    "mimeType": "application/vnd.github.v3.raw",
    "downloadsDirectory": "/opt/Cloud-Init-PostDeployment"
  },
  "scripts": [
    {
      "enabled": true,
      "repoPath": "PostDeploymentBootstrapper.sh",
      "params": "--token ${TOKEN} --repo ${USERNAME}/${REPO}",
      "description": "Main bootstrapper - downloads and executes all scripts"
    }
  ]
}
```

The API URL pattern is:
```
${rootUrl}/${username}/${repo}/${contents}/${repoPath}${query}${branch}
```

Which resolves to:
```
https://api.github.com/repos/your-username/your-repo/contents/PostDeploymentBootstrapper.sh?ref=main
```

### Security Best Practices

- **Never commit tokens** - Use environment variables or secure vaults
- **Use fine-grained tokens** when possible (limit to specific repos)
- **Set token expiration** - Rotate tokens periodically
- **Limit token scope** - Only grant `repo` access, nothing more
- **Store tokens securely** - Use Proxmox secrets, HashiCorp Vault, or similar

## License

See [LICENSE](LICENSE) for details.
