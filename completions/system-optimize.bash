# Bash completion for system_optimize.sh and network_optimize.sh
#
# Install (user):
#   mkdir -p ~/.local/share/bash-completion/completions
#   cp completions/system-optimize.bash \
#      ~/.local/share/bash-completion/completions/system_optimize.sh
#   ln -sf system_optimize.sh \
#      ~/.local/share/bash-completion/completions/network_optimize.sh
#
# Install (system-wide):
#   sudo cp completions/system-optimize.bash \
#      /etc/bash_completion.d/system-optimize

_system_optimize_complete() {
    local cur prev words cword script
    COMPREPLY=()
    cur="${COMP_WORDS[COMP_CWORD]}"
    prev="${COMP_WORDS[COMP_CWORD - 1]}"
    script="${COMP_WORDS[0]##*/}"

    local profiles='server vm workstation laptop latency auto'
    local congestion_algos='bbr cubic reno vegas westwood htcp bic illinois'

    local system_opts='
        --profile=
        --disable-mitigations
        --disable-smt
        --low-latency
        --isolate-cpus=
        --relax-security
        --disable-services
        --reclaim-memory
        --apply-fs-tuning
        --report
        --verify
        --yes
        --dry-run
        --verbose
        --cleanup
        --restore-from=
        --help
    '

    local network_opts='
        --profile=
        --congestion=
        --high-throughput
        --low-latency
        --dry-run
        --report
        --verify
        --cleanup
        --restore-from=
        --help
    '

    # Value completion for --foo=VALUE (Bash splits the = as its own word)
    if [[ ${prev} == "=" ]]; then
        local opt="${COMP_WORDS[COMP_CWORD - 2]}"
        case ${opt} in
            --profile)
                COMPREPLY=($(compgen -W "${profiles}" -- "${cur}"))
                return 0
                ;;
            --congestion)
                COMPREPLY=($(compgen -W "${congestion_algos}" -- "${cur}"))
                return 0
                ;;
            --restore-from)
                COMPREPLY=($(compgen -d -- "${cur}"))
                return 0
                ;;
            --isolate-cpus)
                return 0
                ;;
        esac
    fi

    # Value completion for "--foo=val" style (single-token)
    case ${cur} in
        --profile=*)
            COMPREPLY=($(compgen -W "${profiles}" -- "${cur#--profile=}"))
            return 0
            ;;
        --congestion=*)
            COMPREPLY=($(compgen -W "${congestion_algos}" -- "${cur#--congestion=}"))
            return 0
            ;;
        --restore-from=*)
            COMPREPLY=($(compgen -d -- "${cur#--restore-from=}"))
            return 0
            ;;
    esac

    # Flag completion — choose option set based on script basename
    local opts
    case ${script} in
        network_optimize.sh|network-optimize) opts="${network_opts}" ;;
        *) opts="${system_opts}" ;;
    esac

    if [[ ${cur} == -* ]]; then
        COMPREPLY=($(compgen -W "${opts}" -- "${cur}"))
        # Don't append a trailing space after "--foo="
        [[ ${COMPREPLY[*]} == *= ]] && compopt -o nospace 2>/dev/null
        return 0
    fi

    COMPREPLY=($(compgen -W "${opts}" -- "${cur}"))
    return 0
}

complete -F _system_optimize_complete system_optimize.sh
complete -F _system_optimize_complete network_optimize.sh
complete -F _system_optimize_complete ./system_optimize.sh
complete -F _system_optimize_complete ./network_optimize.sh
