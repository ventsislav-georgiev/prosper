import Foundation

// #917 S3 (spec 4.5 item 2, errata A6, A7, C12, C13; supervisor rulings E-3, E-4): the runner
// script `prosper-kit-run` as a value, and the two files it reads. Nothing here writes a file.
//
// Argument layout the script parses (KitRender.runnerLine builds it):
//   prosper-kit-run <ext-id> <piece-id> <name> [<interpreter>] </abs/target> [args...]
// $4 starting with "/" is the target; otherwise $4 is the interpreter (a program on the PATH: `command -v` must give an absolute path, so a
// builtin, function or alias is refused) and $5 the
// target. The args after the target go to .pre, the target and .post alike.
// The kits folder is <dir of the runner>/../kits (never HOME, never a variable); per kit the runner
// reads kits/<ext-id>/kit.env (kitEnvText) and <KIT_CONFIG>/.settings.env (settingsEnvText), both
// parsed line by line as KEY='value' text, never sourced.
// Exit codes: 64 bad arguments or ids, 78 kit.env missing or unsafe, 70 no temp file, a .pre's
// non-zero status, else the target's status.

enum KitRunner {
    static let script = #"""
    #!/bin/sh
    # prosper-kit-run: written by Prosper, rewritten on every Prosper update. Do not edit.
    # usage: prosper-kit-run <ext-id> <piece-id> <name> [<interpreter>] </abs/target> [args...]
    set -u
    unset KIT_DIR KIT_BIN KIT_CONFIG KIT_STATE_DIR KIT_STATUS
    die() { printf 'prosper-kit-run: %s\n' "$1" >&2; exit "$2"; }
    idok() { case $1 in ''|.|..|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
    [ "$#" -ge 4 ] || die 'usage: <ext-id> <piece-id> <name> [<interpreter>] <target> [args]' 64
    idok "$1" && idok "$2" && idok "$3" || die 'refused: an id or the name is empty, "." or "..", or holds a character outside [A-Za-z0-9._-]' 64
    ext=$1 piece=$2 name=$3 interp=
    case $4 in
      /*) target=$4; shift 4 ;;
      *) [ "$#" -ge 5 ] || die 'usage: an interpreter needs a target after it' 64
         interp=$4 target=$5
         case $interp in -*|*[!A-Za-z0-9._+-]*) die 'refused: the interpreter is not a command name' 64 ;; esac
         case $target in /*) ;; *) die 'refused: the target is not an absolute path' 64 ;; esac
         shift 5 ;;
    esac
    # Resolved once, for both paths: a builtin (eval, ., exec), a function or an alias has no path.
    if [ -n "$interp" ]; then
      ip=$(command -v "$interp" 2>/dev/null)
      case $ip in /*) interp=$ip ;; *) die 'refused: the interpreter is not a program on the PATH' 64 ;; esac
    fi
    case $0 in */*) here=${0%/*} ;; *) die 'refused: run the runner by its path' 64 ;; esac
    case $here in /*) ;; *) here=./$here ;; esac
    kd=$here/../kits/$ext
    uid=$(id -u) || die 'cannot read the user id' 70
    safe() { [ -n "$(find "$1" -prune -type f -user "$uid" ! -perm -020 ! -perm -002 -print 2>/dev/null)" ]; }
    q="'\\''"
    kv() {
      case $1 in KIT_*=\'*\') ;; *) return 1 ;; esac
      k=${1%%=*}
      case $k in KIT_|*[!A-Z0-9_]*) return 1 ;; esac
      r=${1#*=}; r=${r#\'}; r=${r%\'}; v=
      while case $r in *"$q"*) true ;; *) false ;; esac; do
        s=${r%%"$q"*}
        case $s in *\'*) return 1 ;; esac
        v=$v$s\'; r=${r#*"$q"}
      done
      case $r in *\'*) return 1 ;; esac
      v=$v$r
    }
    load() {
      while IFS= read -r line || [ -n "$line" ]; do
        kv "$line" || continue
        case $2:$k in
          env:KIT_DIR|env:KIT_BIN|env:KIT_CONFIG|env:KIT_STATE_DIR) ;;
          env:*|*:KIT_DIR|*:KIT_BIN|*:KIT_CONFIG|*:KIT_STATE_DIR|*:KIT_STATUS) continue ;;
        esac
        export "$k=$v"
      done < "$1"
    }
    safe "$kd/kit.env" || die 'refused: kit.env is missing, not a regular file, not yours, or group- or world-writable' 78
    load "$kd/kit.env" env
    for p in "${KIT_DIR-}" "${KIT_BIN-}" "${KIT_CONFIG-}" "${KIT_STATE_DIR-}"; do
      case $p in /*) ;; *) die 'refused: kit.env lacks an absolute KIT_DIR, KIT_BIN, KIT_CONFIG or KIT_STATE_DIR' 78 ;; esac
    done
    se=$KIT_CONFIG/.settings.env
    if [ -e "$se" ] || [ -h "$se" ]; then
      if safe "$se"; then load "$se" settings
      else printf 'prosper-kit-run: skipped .settings.env: not a regular file of yours, or group- or world-writable\n' >&2; fi
    fi
    mkdir -m 700 -p "$kd/fired" 2>/dev/null && touch "$kd/fired/$piece" 2>/dev/null
    hook() {
      [ -e "$1" ] || [ -h "$1" ] || return 1
      if safe "$1" && [ -x "$1" ]; then return 0; fi
      printf 'prosper-kit-run: skipped %s: not a regular executable file of yours, or group- or world-writable\n' "${1##*/}" >&2
      return 1
    }
    pre= post=
    hook "$KIT_CONFIG/hooks/$name.pre" && pre=$KIT_CONFIG/hooks/$name.pre
    hook "$KIT_CONFIG/hooks/$name.post" && post=$KIT_CONFIG/hooks/$name.post
    if [ -z "$pre$post" ]; then
      [ -n "$interp" ] && exec "$interp" "$target" ${1+"$@"}
      exec "$target" ${1+"$@"}
    fi
    tmpf=
    if [ ! -t 0 ]; then
      trap 'rm -f "$tmpf"' EXIT
      trap 'exit 129' HUP; trap 'exit 130' INT; trap 'exit 143' TERM
      mkdir -m 700 -p "$kd/tmp" || die 'cannot make the tmp folder' 70
      tmpf=$(mktemp "$kd/tmp/stdin.XXXXXX") || die 'cannot make the stdin temp file' 70
      cat > "$tmpf"
    fi
    run() { if [ -n "$tmpf" ]; then command "$@" < "$tmpf"; else command "$@"; fi; }
    if [ -n "$pre" ]; then
      run "$pre" ${1+"$@"} >&2
      rc=$?
      [ "$rc" -eq 0 ] || exit "$rc"
    fi
    if [ -n "$interp" ]; then run "$interp" "$target" ${1+"$@"}; else run "$target" ${1+"$@"}; fi
    st=$?
    if [ -n "$post" ]; then
      KIT_STATUS=$st; export KIT_STATUS
      run "$post" ${1+"$@"} > /dev/null
    fi
    exit "$st"

    """#

    /// kits/<ext-id>/kit.env (E-3; Prosper writes it 0600). nil when a path cannot be one line.
    static func kitEnvText(_ c: KitRenderContext, stateDir: String) -> String? {
        assignments([("KIT_DIR", c.kitDir), ("KIT_BIN", c.kitBin), ("KIT_CONFIG", c.kitConfig), ("KIT_STATE_DIR", stateDir)])
    }

    /// <KIT_CONFIG>/.settings.env: one KIT_<KEY>='value' per setting, sorted by key. nil (nothing is
    /// written) for a key that is not [A-Za-z0-9_] ASCII, one that would shadow a runner variable,
    /// or a value holding NUL or a line break.
    static func settingsEnvText(_ settings: [String: String]) -> String? {
        var pairs: [(String, String)] = []
        for (key, value) in settings.sorted(by: { $0.key < $1.key }) {
            guard !key.isEmpty, key.unicodeScalars.allSatisfy({ $0.isASCII && (CharacterSet.alphanumerics.contains($0) || $0 == "_") })
            else { return nil }
            let name = "KIT_" + key.uppercased()
            guard !reserved.contains(name) else { return nil }
            pairs.append((name, value))
        }
        return assignments(pairs)
    }

    static let reserved: Set<String> = ["KIT_DIR", "KIT_BIN", "KIT_CONFIG", "KIT_STATE_DIR", "KIT_STATUS"]

    private static func assignments(_ pairs: [(String, String)]) -> String? {
        var out = ""
        for (name, value) in pairs {
            // The runner reads one line per key: a line break would end the value early.
            guard !value.unicodeScalars.contains(where: { $0 == "\0" || $0 == "\n" || $0 == "\r" || $0 == "\u{2028}" || $0 == "\u{2029}" || $0 == "\u{85}" })
            else { return nil }
            out += name + "=" + KitRender.shellQuote(value) + "\n"
        }
        return out
    }
}
