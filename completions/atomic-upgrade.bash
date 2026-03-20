# bash completion for atomic-upgrade

_atomic_upgrade() {
    local cur prev words cword
    _init_completion || return

    local i has_dashdash=0
    for ((i=1; i < cword; i++)); do
        [[ "${words[i]}" == "--" ]] && { has_dashdash=1; break; }
    done

    if [[ $has_dashdash -eq 1 ]]; then
        COMPREPLY=( $(compgen -c -- "$cur") )
        return
    fi

    case "$prev" in
        -t|--tag|--copy-files) return ;;
    esac

    if [[ "$cur" == -* ]]; then
        COMPREPLY=( $(compgen -W "-h --help -V --version -n --dry-run -t --tag --no-gc --separate-home --copy-files --" -- "$cur") )
    fi
}

complete -F _atomic_upgrade atomic-upgrade
