# Set up personal dotfiles

## Personal configuration (dotfiles)

Each team member sets up their own dotfiles for personal preferences (git identity, editor config, shell customizations).

### VS Code (automatic on create/rebuild)

In VS Code user settings (`Cmd+,` on macOS, `Ctrl+,` on Linux/Windows), point at a git repo or a local path:

Using a git repo:

```json
{
  "dev.containers.dotfilesRepository": "https://github.com/YOUR_USERNAME/dotfiles",
  "dev.containers.dotfilesInstallCommand": "install.sh"
}
```

Using a local path (an absolute path under your home directory — `/home/you/...` on Linux/WSL2, `/Users/you/...` on macOS):

```json
{
  "dev.containers.dotfilesRepository": "/home/you/.dotfiles",
  "dev.containers.dotfilesInstallCommand": "install.sh"
}
```

The Dev Containers extension clones or copies your dotfiles and runs the install script automatically after every container creation or rebuild.

### Command line (any backend)

```
dce install myapp ~/.dotfiles
```

Copies the dotfiles directory into the running container and executes its `install.sh`. Safe to re-run — idempotent if your install script is. This works with all backends and is the only option for the apple/container backend since it doesn't use the Dev Containers extension.

### What goes where

- Shared essentials → `Containerfile.base`
- Overlay examples (copy-first templates) → `Containerfiles/example/` (`Containerfile.all`, `Containerfile.nodejs`, `Containerfile.golang`, and any others you add)
- Preferred day-to-day tools → user overlay Containerfile(s) layered during `dce new`/`dce rebuild-image`
- Project secrets (PAT, SSH key, .npmrc) → `~/.config/dce-enclave/<name>/`
- Personal preferences (git identity, vim, shell) → your dotfiles repo

### Starter dotfiles

See `templates/dotfiles/` in this repo for a ready-to-fork example.

