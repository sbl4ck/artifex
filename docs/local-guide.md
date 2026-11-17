# Local install and usage guide

A step-by-step walkthrough for running ARTIFEX on your own machine and driving your first
authorized scan. For the full reference (every install option, reverse-proxy, updating,
architecture) see the [main README](../README.md); this guide is the short path.

> **Authorization first.** ARTIFEX is an autonomous penetration-testing tool. Run it only against
> systems you own or are explicitly authorized to test. See the README's
> [Permitted use / Prohibited](../README.md#license-and-disclaimer) terms.

---

## 1. What you are installing

ARTIFEX is a single Go backend with the Next.js frontend embedded, plus a **PostgreSQL** database.
Agent exploration also needs an **LLM** (Anthropic or OpenAI-compatible). Once running it serves a
web console on **http://localhost:8787** and a traffic-capture proxy on **:8788**.

You need, at minimum:

- A machine running Linux, macOS or Windows 10/11 (on Windows it runs inside WSL2).
- A reachable **PostgreSQL** instance (the setup scripts install one for you).
- A **model** for the agents: a local one through Ollama (the setup scripts' default, no key
  needed), or an `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`. Nothing explores until a model is configured.

---

## 2. Prerequisites

Pick one of the two paths below. You do **not** need both toolchains.

| Path | What you need |
| --- | --- |
| **A. Docker (simplest)** | Docker + Docker Compose. Everything (app + Postgres) runs in containers. |
| **B. Build from source** | Go **1.27+**, Node.js **24 LTS** (22/20 also build), and a PostgreSQL you can connect to. |

Check your toolchains:

```bash
docker compose version      # path A
go version && node -v       # path B  (expect go1.27+, node v24/22/20)
```

---

## 3. Get the code

```bash
git clone https://github.com/sebastian93921/ARTIFEX.git
cd artifex
```

---

## 4. Install — the one-command route (recommended)

`setup.sh` (Linux and macOS) and `setup-windows.cmd` (Windows) take a fresh checkout to a running,
fully configured console. When they finish there is nothing left to click through.

By default the agents use a **local model through [Ollama](https://ollama.com)**: no API key, and
prompts, target data and findings never leave your machine. Cloud keys remain an option.

```bash
./setup.sh                                 # local model (qwen3:8b), the default
./setup.sh --local-model qwen3:14b         # a bigger local model: better agent, more memory
./setup.sh --anthropic-key sk-ant-...      # or use a cloud API instead
```

### On Windows

Double-click **`setup-windows.cmd`** in the ARTIFEX folder, or run it from a terminal:

```bat
setup-windows.cmd                          :: local model, the default
setup-windows.cmd -Model qwen3:14b         :: bigger local model
setup-windows.cmd -Status | -Stop | -Start | -Logs | -Uninstall
```

The agents run Linux commands, so on Windows ARTIFEX runs inside **WSL2**. The script:

1. Installs WSL2 if it's missing. It asks for administrator rights once, and may need a restart;
   setup then continues by itself when you sign in.
2. Creates a separate Linux environment named `ARTIFEX`, **locked down so it can't see your Windows
   drives or start Windows programs**. Whatever the agents run stays inside it.
3. Puts the model where your GPU can run it:
   - **NVIDIA:** Ollama runs inside WSL, which reaches NVIDIA GPUs through the Windows driver.
   - **AMD Radeon (e.g. RX 9070) or Intel Arc:** WSL can't use these GPUs, so Ollama is installed
     **on Windows**, and WSL is switched to *mirrored networking* so ARTIFEX reaches it at
     `127.0.0.1`. Ollama stays off your network. This changes `%USERPROFILE%\.wslconfig` for all
     your WSL distributions; the old file is kept as `.wslconfig.artifex-backup`. At the end the
     script checks the model really runs on the GPU. If it doesn't, it tries Ollama's Vulkan
     backend, and it tells you if only part of the model fits in video memory.
   - **No GPU:** Ollama runs inside WSL on the CPU.

   With 16 GB or more of video memory it picks `qwen3:14b`, otherwise `qwen3:8b`. Override with
   `-Model`, or force where Ollama runs with `-OllamaLocation Windows|Wsl`.
4. Copies the folder in and runs `setup.sh` there (PostgreSQL, the agents' tools, the build, the
   admin password, the model connection).
5. Starts ARTIFEX now and whenever you sign in, adds an `ARTIFEX` desktop shortcut, and opens the
   console. The password is saved in `%LOCALAPPDATA%\ARTIFEX\credentials.txt`.

Requirements: Windows 10 version 2004 or newer (or Windows 11), virtualization enabled in the BIOS
(usually on already), and about 25 GB of free disk. Using an AMD or Intel GPU needs **Windows 11
22H2 or newer** (for mirrored networking) and a current driver (AMD Software: Adrenalin Edition).
On older Windows the model runs on the CPU, which works but is slow.

### Choosing a local model

| Model | Download | Free memory needed | Notes |
| --- | --- | --- | --- |
| `qwen3:4b` | ~2.5 GB | ~5 GB | For 8–12 GB PCs. Weak agent. |
| `qwen3:8b` (default) | ~5 GB | ~8 GB | Reasonable on 16 GB PCs. |
| `qwen3:14b` | ~9 GB | ~12 GB | Noticeably better. GPU recommended. |
| `qwen3:32b` | ~20 GB | ~24 GB | Best of these. Needs a large GPU or lots of RAM. |

Local models are much weaker agents than the large cloud models, so expect shorter, less reliable
exploration chains. Pick the biggest model your hardware runs comfortably. On Windows, WSL gets
half of the PC's memory by default. The script gives the model a 32K-token context window
(`--local-context` / `-Context` to change it), because Ollama's default is too small for agents.

What it does:

1. **Picks a mode.** Docker (app + Postgres in containers, with the scanning tools bundled) when a
   Docker daemon is running; otherwise a **native** build. Force one with `--mode docker|native`.
2. **Native mode only:** uses your Go/Node.js if they're new enough, otherwise downloads Go 1.27.3
   and Node.js 24 into `./.toolchain` (checksums verified, no root needed). Sets up Postgres in a
   Docker container on `127.0.0.1:5433` (`--db docker`), from the system package manager
   (`--db system`), or uses yours (`--pg-dsn postgres://...`). Builds the single binary.
3. **Starts ARTIFEX in the background** with automatic restarts: a systemd user service on Linux, a
   launchd agent on macOS, or a supervised background process otherwise.
4. **Sets the admin password** (random unless you pass `--admin-password`) and saves it to
   `.artifex/credentials` (mode 600).
5. **Sets up the model.** For the local default it installs Ollama, downloads the model, makes a copy
   with a usable context window, and connects it. With a cloud key it saves that instead. Either way
   it then sends one small test request. Add `--with-tools` to also install the tools the Docker
   image bundles (nmap, ripgrep, dig, jq, Playwright with Chromium); the Windows installer always does.
6. **Checks the result** and prints the URL and where the password is.

Safer defaults than a manual install: the console and proxy listen on `127.0.0.1` only (add
`--expose` to listen on all interfaces), config and secret files are mode 600, and the LLM key is
stored as an app profile rather than in environment files that agent commands can read.

Re-running is safe. It reuses the generated passwords from `.artifex/state.env` and updates its own
LLM profile instead of adding another. Day to day:

```bash
./setup.sh status | stop | start | restart | logs
./setup.sh --help                                  # all options
```

Unattended install (CI, provisioning): `./setup.sh -y --mode native --db system --anthropic-key "$KEY"`.

When it finishes, open **http://127.0.0.1:8787** and sign in as `ARTIFEX` with the password from
`.artifex/credentials`. Skip to [section 8](#8-using-it--your-first-task).

The older interactive `./install.sh` still works; it leaves the admin password and LLM setup to the
browser ([section 7](#7-first-run-setup)). To do everything by hand, use section 5 (Docker) or
section 6 (source).

---

## 5. Install — Docker Compose by hand

```bash
cp .env.example .env          # set POSTGRES_PASSWORD; optionally ANTHROPIC_API_KEY
docker compose up -d --build  # builds the artifex image locally + starts postgres
```

Edit `.env` before bringing it up:

```ini
POSTGRES_PASSWORD=change-me-please
ANTHROPIC_API_KEY=sk-...        # optional now, can be set later in the UI
```

Then open **http://localhost:8787**.

Useful commands:

```bash
docker compose logs -f artifex   # follow logs
docker compose down              # stop (keeps the pgdata volume and ./data)
```

> The default compose file uses `network_mode: host` on purpose — it avoids TLS handshakes hanging
> behind VPNs/tunnels with small MTUs. Keep it unless you know you need bridged networking.

---

## 6. Install — build from source locally

Use this if you want a native binary and already have a PostgreSQL to point at.

**6.1 Create the database** (example using a local Postgres):

```sql
CREATE USER artifex WITH PASSWORD 'yourpass';
CREATE DATABASE artifex OWNER artifex;
```

The schema is created automatically on first start — no manual migration step.

**6.2 Write `config.json`** (only `database` and `skill_dir` are read from this file):

```bash
cp config.example.json config.json
```

```json
{
  "database": {
    "host": "127.0.0.1", "port": 5432,
    "user": "artifex", "password": "yourpass",
    "dbname": "artifex", "sslmode": "disable"
  }
}
```

**6.3 Build the single binary** (the `embedui` tag bakes the frontend in):

```bash
cd web && npm ci && npm run build:static && cd ..
mkdir -p server/webui/dist
cp -R web/out/. server/webui/dist/
CGO_ENABLED=0 go build -tags embedui -o artifex ./cmd/artifex
```

**6.4 Start it** (always via the supervisor script, not `./artifex` directly):

```bash
export ANTHROPIC_API_KEY=sk-...   # or OPENAI_API_KEY, or set later in the UI
./start.sh                        # → http://localhost:8787
```

Run it in the background with `nohup ./start.sh >artifex.log 2>&1 &`.

> **Developer loop:** `./dev.sh` runs the backend (:8787), proxy (:8788) and a hot-reloading
> frontend dev server at **http://localhost:5173**. Tests: `go test ./...`.

---

## 7. First-run setup

1. Open **http://localhost:8787**. The first visit redirects to **`/setup`** — set the admin
   password there.
2. Sign in with that password.
3. Go to **LLM configuration** → **New**. Paste your API key (and optionally pick a provider
   template, e.g. GLM). Save and mark a configuration **active**. Explorations use the active LLM.
   - Or set it by environment variable before start: `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`,
     with optional `ARTIFEX_LLM_PROVIDER` / `ARTIFEX_LLM_MODEL` / `ARTIFEX_LLM_BASE_URL`.
4. (Optional) In **System settings**, set the **concurrency** — the number of worker agents per
   task (default 3).

---

## 8. Using it — your first task

1. **Define scope.** On the **Assets** side you set the company/asset scope the agents are allowed
   to explore. Optionally sync assets from ScopeSentry (Asset sync page) instead of entering them by
   hand.
2. **Create a task.** From the **Tasks** view, create a new task and give it a goal/target that
   falls inside your authorized scope.
3. **Watch it run.** Workers plan, explore, and record observations. You can follow:
   - the **exploration graph** (what each agent is trying and finding),
   - the **asset graph** (targets → observations → evidence),
   - and individual **worker traces/conversations**.
4. **Approvals.** When an agent wants to run an intercepted/sensitive action, it surfaces an
   **approval card** (global "Approval records" view and the in-task "Interception approval"
   panel). Expand it to see full detail and approve or reject.
5. **Review findings.** Confirmed vulnerabilities land in the findings list with their evidence.
6. **Retest a fix.** On the task-detail **Retest** tab (or a vulnerability's "Start retest"), launch
   a by-hand retest after you've patched something. Conclusions are *Still reproducible*, *Fixed*, or
   *Cannot confirm*; a successful *Fixed* retest updates the vulnerability status automatically.
7. **Export.** Export reports / CSV / ZIP; labels follow the export request's language.

> **Traffic proxy.** The capture proxy listens on **:8788**. Point a target client or browser at it
> to feed recorded traffic in as evidence. See [traffic evidence](traffic-evidence.md).

---

## 9. Day-to-day operations

**Start / stop**

```bash
# source / binary install
./start.sh                 # start (foreground)
# Ctrl-C to stop, or kill the start.sh process

# docker install
docker compose up -d       # start
docker compose down        # stop (data preserved)
```

**Common flags** (passed straight through by `start.sh`):

```bash
./start.sh -addr :8787 -proxy :8788
```

`-addr` is the frontend + API; `-proxy` is the traffic-capture proxy.

**Logs**

```bash
docker compose logs -f artifex          # docker
tail -f artifex.log                     # backgrounded start.sh
```

**Update**

- In-app: **System configuration → Version and updates → Update** (downloads, verifies SHA256,
  smoke-tests, swaps in, relaunches via `start.sh`; rolls back automatically on repeated failure).
- Script: `./update.sh` (Docker rebuild or local rebuild).
- Your data is preserved across updates — the `pgdata` volume, `./data`, and `./skills` stay put,
  and the schema re-runs idempotently on start. Back up `./data` and the database before upgrading.

---

## 10. Troubleshooting

| Symptom | Likely cause / fix |
| --- | --- |
| `/setup` never loads / connection refused | App not up — check `docker compose logs -f artifex` or `artifex.log`. |
| App starts but tasks don't explore | No **active LLM**. Add a key under LLM configuration and mark it active, or set `ANTHROPIC_API_KEY`/`OPENAI_API_KEY`. |
| Database connection errors | Wrong `config.json` database block, or Postgres not reachable. Confirm host/port/user/password and `sslmode`. |
| HTTP works but HTTPS hangs at "Client hello" (in a container) | Small-MTU VPN/tunnel path — keep `network_mode: host` (the default). |
| Updates can't reach GitHub | Set the **global proxy** on the System settings page; the update path uses it. |
| Forgot the admin password | Run `./reset-password.sh`. |

---

## See also

- [Main README](../README.md) — full install options, reverse-proxy, updating, architecture.
- [LLM provider templates](llm-providers.md)
- [Coding-agent adapter (Claude Code / Codex / Pi)](../adapters/agent/README.md)
- [Traffic evidence](traffic-evidence.md)
- [Verification and known limitations](VERIFICATION.md)
