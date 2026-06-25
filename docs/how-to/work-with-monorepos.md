# Work with monorepos and multiple repos

## Monorepo and multi-repo patterns

Monorepo:

- One container, one workspace tree (example: ${DC_REPOS_DIR:-$HOME/repos}/myapp-monorepo)
- Can combine scopes with dce new ... `<scope1>,<scope2>` ...

Multi-repo with separate trust boundaries:

- Separate containers (frontend/backend) with separate credentials

Single-container multi-repo workspace:

- Put all repos under one host folder for that container
- Example: ${DC_REPOS_DIR:-$HOME/repos}/project-fe/frontend-app, ${DC_REPOS_DIR:-$HOME/repos}/project-fe/shared-ui, ${DC_REPOS_DIR:-$HOME/repos}/project-fe/api-client
- All appear in container under /workspace

