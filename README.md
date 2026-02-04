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
- **Private Repository Support** - Authenticates with GitHub token for private repos
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

To keep your configuration scripts and secrets private, create your own private fork of this repository.

### Step 1: Create a Private Copy

**Option A: Fork (keeps link to upstream)**

1. Click **Fork** at the top of this repository
2. In the fork dialog, select your account/organization
3. After forking, go to **Settings** → **General** → **Danger Zone**
4. Click **Change visibility** → **Make private**

**Option B: Clone and push to new private repo (no upstream link)**

```bash
# Clone this public repo
git clone https://github.com/Grace-Solutions/Cloud-Init-PostDeployment.git
cd Cloud-Init-PostDeployment

# Create a new private repo on GitHub (via web UI or gh cli)
# Then update the remote and push
git remote set-url origin https://github.com/your-org/your-private-repo.git
git push -u origin main
```

### Step 2: Create a Personal Access Token

1. Go to GitHub → **Settings** → **Developer settings** → **Personal access tokens** → **Tokens (classic)**
2. Click **Generate new token (classic)**
3. Give it a descriptive name (e.g., `cloud-init-bootstrap`)
4. Set expiration as needed
5. Select scopes:
   - `repo` (Full control of private repositories)
6. Click **Generate token**
7. **Copy the token immediately** - you won't see it again!

### Step 3: Update Your Scripts

Edit the scripts in your private repo to include your actual configuration:

- **005-TechnitiumRecordCreation.sh** - Add your DNS server URL and API token
- **006-UserManagement.sh** - Configure your users and SSH keys
- **007-SSHConfiguration.sh** - Add your SSH public keys
- **Other scripts** - Update with your specific settings

### Step 4: Use Your Private Repository

```bash
curl -fsSL https://raw.githubusercontent.com/Grace-Solutions/Cloud-Init-PostDeployment/main/PostDeploymentBootstrapper.sh | bash -s -- --token "ghp_your_token" --repo "your-org/your-private-repo"
```

> **Note:** The bootstrapper is fetched from the public repo, but it clones your private repo using the provided token.

### Security Best Practices

- **Never commit tokens to public repos** - Use environment variables or secure vaults
- **Use fine-grained tokens** when possible (limit to specific repos)
- **Set token expiration** - Rotate tokens periodically
- **Limit token scope** - Only grant `repo` access, nothing more
- **Consider using GitHub Actions secrets** for CI/CD workflows

## License

See [LICENSE](LICENSE) for details.
