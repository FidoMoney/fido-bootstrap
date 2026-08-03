# Fido Bootstrap

The public entry point for setting up a Fido engineering machine.

This repo holds two small scripts — `bootstrap.sh` (macOS) and `bootstrap.ps1`
(Windows) — that do three things and nothing else:

1. Make sure the **GitHub CLI (`gh`)** is available, installing it if it isn't.
2. Log you in to GitHub in your browser, if you aren't already.
3. Fetch the real installer from the private **`FidoMoney/fido-installer`**
   repo and run it, passing along any arguments you gave.

Everything that actually configures your machine lives in the private
installer. This repo is deliberately boring: it's public so that a brand-new
laptop with no tooling and no credentials can reach it.

## Run it

**macOS** — Terminal:

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/FidoMoney/fido-bootstrap/main/bootstrap.sh)
```

**Windows** — PowerShell as Administrator:

```powershell
iex (irm https://raw.githubusercontent.com/FidoMoney/fido-bootstrap/main/bootstrap.ps1)
```

That's the whole setup. The installer takes over from there and walks you
through the rest.

## Who can use it

You need a **GitHub account that's a member of the `FidoMoney` organization**.
If you're new, ask in `#eng-platform` for an invite and accept it before you
start.

Anyone can read this repo and run the bootstrap. Only org members get past
step 3 — the fetch of the private installer. If your account isn't in the org
yet, GitHub returns a 404 for the private repo (it doesn't reveal that the repo
exists at all), and the bootstrap stops with:

```
Your GitHub account isn't in the FidoMoney org yet — ask in #eng-platform for an invite, then re-run this command.
```

Accept the invite, then run the same command again.

### What's public and what isn't

| | Repo | Visibility | Contents |
| --- | --- | --- | --- |
| Stage 1 | `FidoMoney/fido-bootstrap` | **Public** | `gh` install, GitHub login, fetch-and-run. No Fido specifics. |
| Stage 2 | `FidoMoney/fido-installer` | **Private** | The actual installer: internal networking, tooling, and repo configuration. |

The split exists because stage 1 has to be reachable with no credentials, while
stage 2 shouldn't be readable by the public. Nothing in this repo describes
Fido's internal infrastructure — it only knows the name of the org and the repo
to ask GitHub for.

Org members can browse the installer directly at
`FidoMoney/fido-installer`, including its README and the Windows guide.

## Options

| Environment variable | Default | Effect |
| -------------------- | ------- | ------ |
| `FIDO_INSTALLER_REF` | `main`  | Git ref (branch, tag, or commit SHA) of `fido-installer` to fetch. Useful for testing a branch before it merges. |

```bash
FIDO_INSTALLER_REF=my-branch bash <(curl -fsSL https://raw.githubusercontent.com/FidoMoney/fido-bootstrap/main/bootstrap.sh)
```

```powershell
$env:FIDO_INSTALLER_REF = 'my-branch'; iex (irm https://raw.githubusercontent.com/FidoMoney/fido-bootstrap/main/bootstrap.ps1)
```

Any other arguments you pass are handed to the installer untouched, so the
installer's own flags work through the bootstrap when you run it from a
downloaded copy of the script.

## Re-running it

**Run the same one-liner any time.** It's the update path as well as the
install path — both stages are idempotent, so re-running picks up whatever has
changed and skips everything already in place. There's no separate update
command to remember.

## Troubleshooting

**"isn't in the FidoMoney org yet"** — your invite is missing or not yet
accepted. Check your email and <https://github.com/orgs/FidoMoney/invitation>,
then re-run. If you believe you are a member, run `gh auth status` to confirm
you're logged in as the right account — a personal account left over from a
previous login is the usual cause.

**`gh` install fails on macOS** — the bootstrap downloads the official release
from `cli/cli`. If you're behind a proxy that blocks it, install `gh` yourself
(`brew install gh`) and re-run; the bootstrap will use the one on your PATH.

**`winget` not found on Windows** — install **App Installer** from the
Microsoft Store, close and reopen PowerShell, then re-run.

**The browser login doesn't come back** — close the browser tab and re-run.
`gh auth login` is resumable; nothing is left half-done.

## Reporting issues

Post in `#eng-platform`, or file an issue in this repo. Please don't put
internal hostnames, addresses, or configuration in issues here — **this repo is
public**. Use `FidoMoney/fido-installer` for anything specific to the installer
itself.
