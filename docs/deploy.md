# Deploying mobile-tools

This app is deploy-ready for **Fly.io** (managed) and **DigitalOcean via Kamal**
(self-managed). Heroku is possible but requires migrating to Postgres because
Heroku dynos have an ephemeral filesystem.

Stack assumptions: Rails 8.0.3 / Ruby 3.4.7 / SQLite + Solid Cache/Queue/Cable
backed up to S3-compatible storage by Litestream.

---

## Option A — Fly.io (cheapest, recommended)

The `fly.toml` is already configured: shared-cpu-1x @ 512MB, persistent
volume at `/data`, auto-stop on idle. With auto-stop the bill lands at Fly's
**$5/mo platform minimum** for typical usage.

```bash
# one-time
fly auth login
fly launch --copy-config --no-deploy   # creates the app + volume
fly secrets set \
  RAILS_MASTER_KEY="$(cat config/master.key)" \
  GEMINI_API_KEY=... \
  ANTHROPIC_API_KEY=... \
  TELEGRAM_BOT_TOKEN=... \
  TELEGRAM_NOTIFY_CHAT_ID=... \
  AWS_ACCESS_KEY_ID=... \
  AWS_SECRET_ACCESS_KEY=... \
  AWS_ENDPOINT_URL_S3=https://fly.storage.tigris.dev \
  BUCKET_NAME=mobile-tools

# every release
fly deploy
```

---

## Option B — DigitalOcean droplet via Kamal (Rails 8 native deploy tool)

Kamal builds your existing Dockerfile, pushes it to a registry, and runs it on
the droplet behind kamal-proxy (Let's Encrypt-terminated, zero config). This is
the official Rails 8 self-host deploy path.

### 1. Provision the droplet

- DigitalOcean → Create Droplets → **Ubuntu 24.04 LTS** (Distributions tab, NOT a Marketplace image — Kamal installs Docker itself; LAMP/nginx/Apache would conflict with kamal-proxy).
- Droplet type: Basic, **Premium Intel — $8/mo (1 GB / 1 vCPU / 35 GB NVMe / 1 TB transfer)**. NVMe is meaningfully faster than the $6 Regular plan for SQLite's fsync-heavy workload, and you get 10 GB more disk for diff receipts + Active Storage uploads.
- Region: NYC or SFO (or whichever is closest to your users).
- Authentication: SSH key only — paste the public half of the keypair you'll register as the GitHub Actions `SSH_PRIVATE_KEY` secret.
- ✅ enable **Weekly backups** (+20%, $1.60/mo) — your only off-server safety net since Litestream is disabled.
- After the droplet boots, point your DNS A record (e.g. `app.bambuapps.xyz`) at the droplet IP.

Once you can `ssh root@<DROPLET_IP>` successfully, add a 1 GB swap file as a cheap OOM safety net (Rails + ImageMagick + Chromium can briefly peak past 700 MB):

```bash
fallocate -l 1G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
echo '/swapfile none swap sw 0 0' >> /etc/fstab
```

### 2. Pick a registry

| Option | Cost | Notes |
|---|---|---|
| **GitHub Container Registry** (`ghcr.io`) | free for private repos | recommended |
| DigitalOcean Container Registry | $5/mo basic | one-vendor convenience |

If using GHCR: GitHub → Settings → Developer settings → Personal access tokens
→ generate a classic token with `write:packages` scope.

### 3. Storage layout

Both SQLite and uploads live on the droplet's local disk; **no off-server S3-compatible bucket is required**. Two Kamal-managed Docker volumes provide persistence across container restarts and re-deploys:

| Volume | Mount | Holds |
|---|---|---|
| `mobile_tools_data` | `/data` | SQLite DBs (main + Solid Cache/Queue/Cable) |
| `mobile_tools_storage` | `/rails/storage` | Active Storage uploads, saved diff receipts |

Backups: enable DigitalOcean **droplet weekly snapshots** (+20% on droplet cost, ~$1.20/mo for the $6 droplet). That covers point-in-time recovery for both volumes.

If you later want near-real-time SQLite backup off-server, re-enable Litestream by:
1. Creating an S3-compatible bucket (DO Spaces, Cloudflare R2, Backblaze B2, etc.).
2. Adding `AWS_ENDPOINT_URL_S3` and `BUCKET_NAME` to `env.clear` in `config/deploy.yml`.
3. Uncommenting `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` in `.kamal/secrets` and the GitHub Actions workflow.

The Litestream rake task in `lib/tasks/litestream.rake` auto-activates whenever `BUCKET_NAME` is set in the env, so no further code changes are needed.

### 4. Configure Kamal

Edit `config/deploy.yml` and replace the `<PLACEHOLDERS>`:
- `image:` — `ghcr.io/<github-user>/mobile-tools`
- `servers.web` — droplet IP
- `proxy.host` — your domain
- `registry.server` / `registry.username`
- (optional) Litestream endpoint + bucket under `env.clear`

Create `.kamal/secrets` from the template (already gitignored). Fill in your
API keys, registry token, and `RAILS_MASTER_KEY`.

### 5. First deploy

```bash
bin/kamal setup     # installs Docker on the droplet, sets up kamal-proxy, deploys
```

### 6. Subsequent deploys (manual)

```bash
bin/kamal deploy    # builds, pushes, rolls out with zero downtime
bin/kamal logs      # tail logs
bin/kamal console   # rails console on the running container
bin/kamal app exec  # arbitrary commands
```

### 7. Continuous deploy via GitHub Actions

`.github/workflows/deploy.yml` runs `bin/kamal deploy` on every push to `main`
(and on manual `workflow_dispatch`). To make it work, add the following
secrets under **GitHub → repo → Settings → Secrets and variables → Actions**.

| Secret | Where to get it |
|---|---|
| `SSH_PRIVATE_KEY` | The **private** half of an SSH key whose public half you put in the droplet's `~/.ssh/authorized_keys` (for `root`, unless you change `ssh.user` in `config/deploy.yml`). Run `ssh-keygen -t ed25519 -f kamal_deploy -C github-actions`, paste the contents of `kamal_deploy` here, and append `kamal_deploy.pub` on the droplet. |
| `RAILS_MASTER_KEY` | `cat config/master.key` |
| `GEMINI_API_KEY` | Google AI Studio |
| `ANTHROPIC_API_KEY` | console.anthropic.com |
| `TELEGRAM_BOT_TOKEN` | @BotFather |
| `TELEGRAM_NOTIFY_CHAT_ID` | the chat / channel ID for receipt notifications |
| `KAMAL_REGISTRY_PASSWORD` | **Only required if your registry is NOT ghcr.io.** For DOCR, run `doctl registry login --expiry-seconds 0` and use the returned token. For Docker Hub, a Personal Access Token. The workflow falls back to the workflow-scoped `GITHUB_TOKEN` when this isn't set, which is enough for pushing to `ghcr.io/<your-user-or-org>/mobile-tools`. |
| `AWS_ACCESS_KEY_ID` / `AWS_SECRET_ACCESS_KEY` | **Optional** — only if you turn off-server SQLite backup back on (see "Storage layout" above). |

The first deploy still has to be done manually from your laptop with
`bin/kamal setup`, since that step provisions Docker on the droplet over SSH.
Once the server is bootstrapped, GitHub Actions takes over.

To manually trigger a deploy without pushing: GitHub → Actions →
"Deploy via Kamal" → **Run workflow**.

### Cost summary (DO)

| Item | $/mo |
|---|---:|
| Droplet (Premium Intel, 1 GB / 1 vCPU / 35 GB NVMe) | $8.00 |
| Weekly droplet backups (+20%) | $1.60 |
| **Total** | **$9.60** |

Storage stays on the droplet's disk (`/data` for SQLite, `/rails/storage` for
uploads + diff receipts). The 35 GB NVMe is plenty of headroom for the
foreseeable future — you can also resize the droplet later (snapshot →
resize → reboot) without losing data.

If you start seeing OOM kills in the logs (`bin/kamal logs` or `dmesg | grep
-i kill` on the droplet), bump the droplet to **Premium Intel 2 GB ($12/mo)**.

For the absolute floor: drop to the **Regular Disk $6/mo** plan (slower SSD,
25 GB) for $7.20/mo total, or move off DO entirely to **Hetzner CPX11**
(€3.79 ≈ $4.10/mo, 2 vCPU / 2 GB RAM, EU only).

---

## Option C — Heroku (not recommended for this app)

Requires migrating off SQLite because Heroku dynos have an ephemeral filesystem
— SQLite would be wiped on every restart, and Solid Cache/Queue/Cable all
ride on SQLite.

Migration cost: rewrite `config/database.yml`, redo the Solid* migrations on
Postgres, change `DATABASE_URL`, rebuild Litestream replication. ~half a day.

Minimum monthly: **$12** (Basic dyno $7 + Postgres Mini $5). No real upside
over Fly.io, which is cheaper *and* keeps SQLite.
