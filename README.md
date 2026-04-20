# FounderOS Skill Pack Releases

Public distribution for FounderOS install/upgrade artifacts.

## Install

```bash
curl -sSL https://raw.githubusercontent.com/Instabidsai/founderos-pack/main/install.sh | bash -s -- YOUR-TOKEN
```

Or:

```bash
curl -sSL https://raw.githubusercontent.com/Instabidsai/founderos-pack/main/founderos.sh | bash -s -- YOUR-TOKEN
```

Both work. `founderos.sh` is the one-command wrapper that always points at the current `install.sh`.

## Resumable

Re-running with the same token resumes from the last completed phase. State: `~/.founderos/install.state`.

## Source

Private repo: `Instabidsai/founderos`. This repo holds only the release artifacts + public installer.
