# dotfiles

Personal configuration for dev containers. The VS Code Dev Containers extension
clones or copies your dotfiles and runs `install.sh` automatically after container
creation or rebuild.

## Files

| File | Purpose |
|------|---------|
| `install.sh` | Entry point called by Dev Containers extension |
| `gitconfig` | Symlinked to `~/.gitconfig` (user.name, user.email, aliases) |
| `vimrc` | Symlinked to `~/.vimrc` (editor settings) |
| `zshrc-additions` | Appended to `~/.zshrc` (aliases, prompt, etc.) |

## Setup

1. Copy this directory to a permanent location (e.g., `~/.dotfiles`) or fork it as a git repo
2. Edit `gitconfig` with your name and email
3. Customize `vimrc` and `zshrc-additions` as needed
4. In VS Code user settings (`Cmd+,`):

Git repo:

```json
{
  "dev.containers.dotfilesRepository": "https://github.com/YOUR_USERNAME/dotfiles",
  "dev.containers.dotfilesInstallCommand": "install.sh"
}
```

Local path:

```json
{
  "dev.containers.dotfilesRepository": "/Users/YOU/.dotfiles",
  "dev.containers.dotfilesInstallCommand": "install.sh"
}
```

## How it works

- `install.sh` is idempotent — safe to re-run on every rebuild
- Existing files are backed up (`.bak`) before being replaced by symlinks
- zsh additions are guarded by a marker comment to avoid duplicates

## Adding more modules

Add a new file (e.g., `tmux.conf`) and add a `setup_tmux` function to
`install.sh` following the same pattern as the existing modules.
