# Work with monorepos and multiple repos

## Monorepo and multi-repo patterns

Monorepo:

- One container, one repo mounted under `/workspace/<repo-name>` (or multiple app folders within that repo)
- Can combine scopes with dce new ... `<scope1>,<scope2>` ...

Multi-repo with separate trust boundaries:

- Separate containers (frontend/backend) with separate credentials

Single-container multi-repo workspace:

- Use repeatable `--repo` (or `dce repo add`) so one project owns 1..N repos
- Example: `dce new project-fe --repo frontend-app=~/repos/frontend-app --repo shared-ui=~/repos/shared-ui --repo api-client=~/repos/api-client`
- Repos appear in the container under `/workspace/<repo-name>`
