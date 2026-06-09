#compdef dc

_dc_complete_root_dir() {
  if [[ -z "${_DC_ROOT_DIR:-}" ]]; then
    local self="${(%):-%x}"
    if [[ -n "$self" && -f "$self" ]]; then
      _DC_ROOT_DIR="${self:A:h:h}"
    else
      local alias_target
      alias_target="${${(s:=:)"$(alias dc 2>/dev/null)"}[2]}"
      alias_target="${alias_target#\'}"
      alias_target="${alias_target%\'}"
      if [[ -n "$alias_target" && -f "${alias_target:a}" ]]; then
        _DC_ROOT_DIR="${alias_target:a:h:h}"
      fi
    fi
  fi
}

_dc_project_names() {
  _dc_complete_root_dir
  local projects_dir="${_DC_ROOT_DIR}/projects"
  local -a names=()
  if [[ -d "$projects_dir" ]]; then
    for d in "$projects_dir"/*(/N); do
      [[ -f "$d/config" ]] && names+=("${d:t}")
    done
  fi
  _describe 'project' names
}

_dc_subcommands() {
  local -a cmds=(
    'new:Create a new dev container project'
    'start:Start project(s)'
    'stop:Stop project(s)'
    'status:Show detailed container status'
    's:Alias for status'
    'list:List containers and status'
    'ls:Alias for list'
    'shell:Open a shell or run a command in a container'
    'rebuild:Destroy and recreate a container'
    'rebuild-image:Rebuild container images'
    'clean:Remove old image tags'
    'install:Install dotfiles into a container'
    'help:Show usage help'
  )
  _describe 'command' cmds
}

_dc_types() {
  local -a types=(
    'nodejs:Node.js runtime'
    'golang:Go runtime'
    'nodejs,golang:Combined Node.js and Go runtime'
  )
  _describe 'type' types
}

_dc_rebuild_image_targets() {
  local -a targets=(
    'all:Rebuild all images'
    'base:Rebuild base image only'
    'nodejs:Rebuild Node.js image'
    'golang:Rebuild Go image'
  )
  _describe 'target' targets
}

_dc() {
  local curcontext="$curcontext" state line
  typeset -A opt_args

  _arguments -C \
    '1: :_dc_subcommands' \
    '*::arg:->args'

  case $words[1] in
    new)
      _arguments \
        '1:name: ' \
        '2:type:_dc_types'
      ;;
    start|stop)
      _arguments \
        '1:project:_dc_project_names'
      ;;
    shell)
      _arguments \
        '1:project:_dc_project_names' \
        '2:command: '
      ;;
    rebuild)
      _arguments \
        '1:project:_dc_project_names' \
        '2:flag:(--rotate-keys)'
      ;;
    rebuild-image)
      _arguments \
        '1:target:_dc_rebuild_image_targets'
      ;;
    clean)
      _arguments \
        '1:flag:(--dry-run)'
      ;;
    install)
      _arguments \
        '1:project:_dc_project_names' \
        '2:path:_directories'
      ;;
    status|s|list|ls|help|--help|-h)
      ;;
  esac
}

compdef _dc dc
