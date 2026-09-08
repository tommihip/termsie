import Foundation

/// The generated zsh startup files, embedded in the binary rather than shipped as bundle
/// resources: a resource that fails to load would mean a broken shell, not a missing feature.
///
/// Why these exist at all: setting `ZDOTDIR` makes zsh read `$ZDOTDIR/.zshenv` *instead of*
/// `~/.zshenv`, so a naive shim silently drops whatever the user's own `.zshenv` does — commonly
/// their PATH. Each file below therefore points `ZDOTDIR` back at the user's directory, sources
/// their real file, and only then restores our own.
enum ShimScripts {
    /// Bump when any script below changes; generated directories carry this and regenerate on
    /// mismatch after an app upgrade.
    static let version = "1"

    private static let header = """
    # Termsie shell integration — generated, do not edit. Regenerated when Termsie updates.
    # zsh is reading this instead of your own file because Termsie set ZDOTDIR.
    # Your file is sourced below, so everything in it still applies.
    """

    /// Swaps ZDOTDIR back to the user's, sources their file, and swaps ours back in.
    /// `function_argzero` is turned off around the source so `$0` matches what zsh itself would
    /// present for a startup file rather than what `source` would.
    private static func sourceUserFile(_ name: String) -> String {
        """
        __termsie_shim_dir=$ZDOTDIR
        if (( ${+TERMSIE_ORIG_ZDOTDIR} )); then ZDOTDIR=$TERMSIE_ORIG_ZDOTDIR; else unset ZDOTDIR; fi
        __termsie_user_zdotdir=${ZDOTDIR:-$HOME}
        if [[ -r $__termsie_user_zdotdir/\(name) ]]; then
            if [[ -o function_argzero ]]; then
                unsetopt function_argzero
                source $__termsie_user_zdotdir/\(name)
                setopt function_argzero
            else
                source $__termsie_user_zdotdir/\(name)
            fi
        fi
        """
    }

    static let zshenv = """
    \(header)

    \(sourceUserFile(".zshenv"))

    if [[ ! -o rcs ]]; then
        # The user's .zshenv turned RCS off, so no later startup file runs — not even ours.
        # Pin here and get out of the way.
        if [[ -o interactive && -n ${TERMSIE_HISTFILE:-} ]]; then
            HISTFILE=$TERMSIE_HISTFILE
            setopt inc_append_history
            unsetopt share_history
        fi
        unset __termsie_shim_dir __termsie_user_zdotdir
        return 0
    fi

    if [[ -o interactive || -o login ]]; then
        typeset -g ZDOTDIR=$__termsie_shim_dir
    else
        # A plain `zsh -c` runs nothing else of ours; leave the user's ZDOTDIR in place.
        unset __termsie_shim_dir __termsie_user_zdotdir
    fi
    """

    static let zprofile = """
    \(header)

    \(sourceUserFile(".zprofile"))

    typeset -g ZDOTDIR=$__termsie_shim_dir
    unset __termsie_shim_dir __termsie_user_zdotdir
    """

    static let zshrc = """
    \(header)

    __termsie_shim_dir=$ZDOTDIR
    if (( ${+TERMSIE_ORIG_ZDOTDIR} )); then ZDOTDIR=$TERMSIE_ORIG_ZDOTDIR; else unset ZDOTDIR; fi
    __termsie_user_zdotdir=${ZDOTDIR:-$HOME}

    # /etc/zshrc has already run and pointed HISTFILE at ${ZDOTDIR:-$HOME}/.zsh_history, which is
    # inside our shim directory. Put it back so the user's rc sees what it would see natively.
    if [[ $HISTFILE == $__termsie_shim_dir/* ]]; then
        HISTFILE=$__termsie_user_zdotdir/.zsh_history
    fi

    if [[ -r $__termsie_user_zdotdir/.zshrc ]]; then
        if [[ -o function_argzero ]]; then
            unsetopt function_argzero
            source $__termsie_user_zdotdir/.zshrc
            setopt function_argzero
        else
            source $__termsie_user_zdotdir/.zshrc
        fi
    fi

    typeset -g ZDOTDIR=$__termsie_shim_dir
    unset __termsie_shim_dir __termsie_user_zdotdir

    # ------------------------------------------------------------------ history
    # No `emulate -L zsh` here: it localises options, which would undo the setopt below
    # the moment the function returns.
    __termsie_pin_history() {
        [[ -o interactive ]] || return 0
        [[ -n ${TERMSIE_HISTFILE:-} ]] || return 0
        # A user who deliberately asked for one shared history keeps it.
        if [[ -o share_history ]] && (( ${TERMSIE_HISTORY_RESPECT_SHARE:-1} )); then
            return 0
        fi
        if [[ -z ${TERMSIE_GLOBAL_HISTFILE:-} && -n $HISTFILE ]]; then
            typeset -g TERMSIE_GLOBAL_HISTFILE=$HISTFILE
        fi
        typeset -g HISTFILE=$TERMSIE_HISTFILE
        [[ -n ${TERMSIE_HISTSIZE:-} ]] && typeset -g HISTSIZE=$TERMSIE_HISTSIZE
        [[ -n ${TERMSIE_SAVEHIST:-} ]] && typeset -g SAVEHIST=$TERMSIE_SAVEHIST
        unsetopt share_history
        setopt inc_append_history
        return 0
    }
    # Runs before zsh loads any history, so isolation is clean from the first command.
    __termsie_pin_history

    # --------------------------------------------------------- startup commands
    typeset -ga __termsie_startup=()
    () {
        local v i
        for (( i = 1; i <= ${TERMSIE_STARTUP_COUNT:-0}; i++ )); do
            v=TERMSIE_STARTUP_$i
            __termsie_startup+=( "${(P)v}" )
            unset $v
        done
    }
    unset TERMSIE_STARTUP_COUNT

    __termsie_precmd() {
        if (( ! ${TERMSIE_DID_HIST_CHECK:-0} )); then
            typeset -g TERMSIE_DID_HIST_CHECK=1
            # Anything registered after us may have moved HISTFILE. History is already loaded by
            # now, so re-read explicitly after re-pinning.
            if [[ -n ${TERMSIE_HISTFILE:-} && $HISTFILE != $TERMSIE_HISTFILE ]]; then
                __termsie_pin_history
                [[ $HISTFILE == $TERMSIE_HISTFILE && -s $HISTFILE ]] && fc -R -- $HISTFILE
            fi
        fi
        # Drain the whole queue in this one pass. precmd fires once per prompt, and no new prompt
        # appears until the user types something — so dequeuing one command per call would leave
        # everything after the first waiting for input that never comes.
        #
        # The loop is still strictly sequential: each eval returns before the next begins, so a
        # command never receives the input intended for the one after it.
        if (( ${#__termsie_startup} )); then
            local cmd
            for cmd in "${__termsie_startup[@]}"; do
                (( ${TERMSIE_STARTUP_ECHO:-1} )) && print -Pr -- "%F{8}> ${cmd//\\%/%%}%f"
                (( ${TERMSIE_STARTUP_RECORD:-0} )) && print -s -- $cmd
                # eval at precmd time, not inside .zshrc: the shell is in its normal interactive
                # loop, so job control is settled and Ctrl-C kills the command, not the shell.
                eval $cmd
            done
            __termsie_startup=()
        fi
        precmd_functions=( "${(@)precmd_functions:#__termsie_precmd}" )
        unset -f __termsie_precmd 2>/dev/null
        return 0
    }
    typeset -ga precmd_functions
    precmd_functions+=( __termsie_precmd )

    # ------------------------------------------------------ merge back on exit
    __termsie_merge_history() {
        (( ${TERMSIE_HISTORY_MERGE:-1} )) || return 0
        [[ -n ${TERMSIE_GLOBAL_HISTFILE:-} && -n ${TERMSIE_HISTFILE:-} ]] || return 0
        [[ $TERMSIE_GLOBAL_HISTFILE == $TERMSIE_HISTFILE ]] && return 0
        fc -A 2>/dev/null
        [[ -s $TERMSIE_HISTFILE ]] || return 0
        # Absolute path: PATH may have been rearranged by now.
        { /bin/cat -- $TERMSIE_HISTFILE >> $TERMSIE_GLOBAL_HISTFILE } 2>/dev/null
        return 0
    }
    typeset -ga zshexit_functions
    zshexit_functions+=( __termsie_merge_history )

    # A non-login shell has no .zlogin to run, so restore ZDOTDIR now. Assigning after `unset`
    # creates a non-exported parameter, so children never see the shim directory.
    if [[ ! -o login ]]; then
        if (( ${+TERMSIE_ORIG_ZDOTDIR} )); then typeset -g ZDOTDIR=$TERMSIE_ORIG_ZDOTDIR; else unset ZDOTDIR; fi
    fi
    """

    static let zlogin = """
    \(header)

    \(sourceUserFile(".zlogin"))

    # .zlogin runs after .zshrc, so pin once more in case the user's file moved HISTFILE.
    (( ${+functions[__termsie_pin_history]} )) && __termsie_pin_history

    if (( ${+TERMSIE_ORIG_ZDOTDIR} )); then typeset -g ZDOTDIR=$TERMSIE_ORIG_ZDOTDIR; else unset ZDOTDIR; fi
    unset __termsie_shim_dir __termsie_user_zdotdir
    """

    static var files: [String: String] {
        [".zshenv": zshenv, ".zprofile": zprofile, ".zshrc": zshrc, ".zlogin": zlogin]
    }
}
