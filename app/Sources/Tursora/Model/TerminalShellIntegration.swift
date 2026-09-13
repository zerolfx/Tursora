import Foundation

/// Shell-side scripts for the two directions of terminal ↔ browser folder sync.
///
/// Nothing here is ever typed into a running shell and no user startup file is
/// modified: zsh reads a temporary `ZDOTDIR`, bash a temporary `--rcfile` and
/// fish an `--init-command`, and each of those loads the user's own files the
/// way that shell normally would. Navigation paths never enter executable shell
/// text — only a generated directory name and a hex token do; a requested path
/// is read as data from the private request file, and a reported path leaves
/// the shell percent-encoded inside an OSC 7 sequence.
enum TerminalShellIntegration {
    /// Shells with a folder integration. Detection uses the executable name,
    /// the way login shells are configured, so a copy in another directory
    /// still matches; macOS `/bin/sh` stays unintegrated even though it is bash.
    enum Kind: String, Equatable, CaseIterable {
        case zsh, bash, fish

        /// Only zsh can act on a request while the user is sitting at an idle
        /// prompt; bash and fish apply it when the next prompt is drawn.
        var appliesRequestsWhileIdle: Bool { self == .zsh }
    }

    static func kind(forShell path: String) -> Kind? {
        Kind(rawValue: URL(fileURLWithPath: path).lastPathComponent)
    }

    /// Interactive arguments for a shell without an integration.
    static let plainArguments = ["-il"]

    static func shellQuoted(_ path: String) -> String {
        "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - zsh

    /// Reports `$PWD` as OSC 7 from zsh's precmd hook, so the browser can
    /// follow a shell-side `cd` without the user installing anything.
    /// `NO_MULTIBYTE` makes the loop byte-wise, so a non-ASCII path is
    /// percent-encoded as its UTF-8 octets rather than as code points.
    static func zshReporter(token: String) -> String {
        #"""
        function _ts_TOKEN_osc7() {
          builtin emulate -L zsh -o no_multibyte
          builtin local location="$PWD" encoded="" char hex
          builtin local -i index
          for (( index = 1; index <= ${#location}; index++ )); do
            char="${location[index]}"
            if [[ "$char" == [A-Za-z0-9/._-] ]]; then
              encoded+="$char"
            else
              builtin printf -v hex '%%%02X' "'$char"
              encoded+="$hex"
            fi
          done
          builtin print -rn -- $'\e]7;file://'"${HOST}${encoded}"$'\a'
        }
        """#.replacingOccurrences(of: "TOKEN", with: token)
    }

    // MARK: - bash

    /// bash ignores `--rcfile` for a login shell, so the session is started as
    /// an interactive non-login shell and this file reads the same startup
    /// files a login bash would, in the same order, before adding the hook.
    /// `PROMPT_COMMAND` keeps whatever the user's files installed.
    static func bashRunCommands(directory: URL, token: String) -> String {
        let root = shellQuoted(directory.path)
        return #"""
        # Tursora folder integration. This file stands in for the personal
        # startup file of this one shell; the user's own files are read first
        # and are never modified.
        if [ -r /etc/profile ]; then . /etc/profile; fi
        for _ts_TOKEN_startup in "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.profile" "$HOME/.bashrc"; do
          if [ -r "$_ts_TOKEN_startup" ]; then . "$_ts_TOKEN_startup"; break; fi
        done
        unset _ts_TOKEN_startup
        # Byte-wise percent encoding: LC_ALL=C makes ${#s} and ${s:i:1} count
        # octets, so a UTF-8 path encodes the way a file URL expects.
        _ts_TOKEN_osc7() {
          local LC_ALL=C
          local location="$PWD" encoded="" char hex index
          for (( index = 0; index < ${#location}; index++ )); do
            char="${location:index:1}"
            case "$char" in
              [A-Za-z0-9/._-]) encoded="$encoded$char" ;;
              *) printf -v hex '%%%02X' "'$char"; encoded="$encoded$hex" ;;
            esac
          done
          printf '\033]7;file://%s%s\a' "$HOSTNAME" "$encoded"
        }
        # The request is data: it is read NUL-delimited, never run as a command.
        # A request is consumed only once it has been applied, so a manual cd
        # afterwards is not undone at the next prompt.
        _ts_TOKEN_apply() {
          local number target
          [ -r ROOT/request ] || return 0
          { IFS= read -r -d '' number && IFS= read -r -d '' target; } < ROOT/request || return 0
          case "$number" in ''|*[!0-9]*) return 0 ;; esac
          case "$target" in /*) ;; *) return 0 ;; esac
          [ "$number" = "$_ts_TOKEN_last" ] && return 0
          builtin cd -- "$target" 2>/dev/null && _ts_TOKEN_last="$number"
          return 0
        }
        _ts_TOKEN_prompt() {
          local _ts_TOKEN_status=$?
          _ts_TOKEN_apply
          _ts_TOKEN_osc7
          return $_ts_TOKEN_status
        }
        if [ -n "$PROMPT_COMMAND" ]; then
          PROMPT_COMMAND="$PROMPT_COMMAND"$'\n'"_ts_TOKEN_prompt"
        else
          PROMPT_COMMAND="_ts_TOKEN_prompt"
        fi
        """#.replacingOccurrences(of: "TOKEN", with: token).replacingOccurrences(of: "ROOT", with: root)
    }

    // MARK: - fish

    /// fish evaluates `--init-command` after its own configuration, so the
    /// user's `config.fish` is untouched and still wins for everything else.
    /// `string escape --style=url` escapes the separators too; the replacement
    /// puts them back so the result stays an absolute file URL path.
    static func fishInitCommand(directory: URL, token: String) -> String {
        let root = shellQuoted(directory.path)
        return #"""
        function _ts_TOKEN_osc7 --on-variable PWD
            set -l encoded (string replace --all --regex -- '%2[Ff]' / (string escape --style=url -- $PWD))
            printf '\033]7;file://%s%s\a' "$hostname" "$encoded"
        end
        function _ts_TOKEN_prompt --on-event fish_prompt
            _ts_TOKEN_apply
            # The PWD hook stays silent when a request lands on the folder the
            # shell is already in, so every prompt reports as well.
            _ts_TOKEN_osc7
        end
        function _ts_TOKEN_apply
            if not test -r ROOT/request
                return 0
            end
            begin
                read --null --local number
                or return 0
                read --null --local target
                or return 0
                if not string match --quiet --regex -- '^[0-9]+$' "$number"
                    return 0
                end
                if not string match --quiet -- '/*' "$target"
                    return 0
                end
                if test "$number" = "$_ts_TOKEN_last"
                    return 0
                end
                if builtin cd "$target" 2>/dev/null
                    set -g _ts_TOKEN_last "$number"
                end
            end < ROOT/request
            return 0
        end
        _ts_TOKEN_osc7
        """#.replacingOccurrences(of: "TOKEN", with: token).replacingOccurrences(of: "ROOT", with: root)
    }
}
