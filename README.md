# BoxWatch Agent

The open-source install scripts for [BoxWatch](https://boxwatch.app), simple server monitoring that installs in 60 seconds and won't cost you a Datadog-sized bill.

This repository holds the agent's installer and uninstaller so you can read exactly what runs on your server before you install it. No obfuscation, no precompiled binary, just bash.

```bash
curl -sL https://boxwatch.app/install.sh | bash -s YOUR_AGENT_KEY
```

Sixty seconds later your server is reporting CPU, memory, disk, network, load, and uptime to your dashboard.

## What is BoxWatch?

BoxWatch is a server monitoring service for people who manage anywhere from 2 to 100 servers and don't want to run a Prometheus stack or pay per-host metered pricing. You install a lightweight agent, and you get metrics, trend charts, multi-channel alerts, uptime tracking, status pages, and TV dashboards from one place.

- **One-command install.** No YAML, no agent ecosystem to learn.
- **Lightweight.** The agent is a bash script run by cron. It needs `curl` and `crontab`, both of which you already have.
- **Predictable pricing.** Fixed monthly tiers with server caps. No per-metric charges, no surprise bills.
- **Free tier forever.** 2 servers, no credit card.

Full feature list and sign-up at **[boxwatch.app](https://boxwatch.app)**.

## Install

Get your agent key from your [BoxWatch dashboard](https://boxwatch.app), then run one of the following.

**Standard:**

```bash
curl -sL https://boxwatch.app/install.sh | bash -s YOUR_AGENT_KEY
```

**Safer (keeps your key out of the shell's process list and history):**

```bash
curl -sL https://boxwatch.app/install.sh | BOXWATCH_KEY=your_key bash
```

The installer requires root or `sudo`.

### What the installer does

1. Validates your agent key format.
2. Creates `/opt/boxwatch` and downloads `agent.sh` into it.
3. Verifies the downloaded agent against a known SHA-256 checksum. If the file has been tampered with, the install aborts.
4. Writes your config to `/opt/boxwatch/config` with `600` permissions (readable only by root).
5. Installs a cron entry that runs the agent every minute. The server decides how often data is actually stored based on your plan.
6. Runs the agent once to confirm the connection works.

Push frequency by plan: Hobby every 60 min, Pro and Team every 5 min, Scale every 1 min.

## What the agent collects

Standard host metrics only:

- CPU usage
- Memory usage
- Disk usage
- Network throughput
- Load averages
- Uptime

No file contents, no command output, no application data. The agent sends metrics to `https://api.boxwatch.app` over HTTPS.

## Uninstall

```bash
curl -sL https://boxwatch.app/uninstall.sh | bash
```

This removes the cron entry and deletes `/opt/boxwatch`. Your server stops reporting immediately.

## Security

- **Readable source.** These install scripts are right here. Read them before you pipe them to bash.
- **Checksum-verified agent.** The installer refuses to run an `agent.sh` whose SHA-256 doesn't match the expected value.
- **Locked-down config.** Your agent key is stored at `/opt/boxwatch/config` with `600` permissions and is written via a heredoc so it never appears in the process list.
- **Scoped keys.** Agent keys are write-only. They can report metrics, they cannot read your account.

If you find a security issue, please email watcher@boxwatch.app rather than opening a public issue.

## Files in this repository

| File | Purpose |
| --- | --- |
| `install.sh` | Downloads, verifies, and installs the agent, and sets up the cron job. |
| `uninstall.sh` | Removes the agent, config, and cron job. |

> Note: `agent.sh`, the script that actually collects and pushes metrics, is currently served from `https://boxwatch.app/agent.sh` and verified by checksum at install time. Adding it to this repository is on the roadmap so the full agent can be audited here directly.

## License

The contents of this repository are released under the MIT License. See `LICENSE` for details.

---

Built by [Joe Morganelli](https://github.com/JoeMo-GenX). BoxWatch is built based on what users actually ask for. Open an issue or email with your biggest server-monitoring pain point.
