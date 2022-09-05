#region: Init

() {
  0=${(%):-%x}
  fpath+=${0:A:h}/functions
  if [[ "$MANPATH" != *"${0:A:h}/man"* ]]; then
    export MANPATH="${0:A:h}/man:$MANPATH"
  fi

  # the -F option was added in 5.8
  autoload -Uz is-at-least
  typeset -gHa _adote_zparopt_flags
  if is-at-least 5.8; then
    _adote_zparopt_flags=( -D -M -F )
  else
    _adote_zparopt_flags=( -D -M )
  fi

  # setup the environment
  for _fn in ${0:A:h}/functions/*; do
    (( $+functions[${_fn:t}] )) && unfunction ${_fn:t}
    autoload -Uz "${_fn}"
  done
  unset _fn
}

#endregion


#region: Functions

### The main controller for antidote.
function __antidote_main {
  # The reason we use `__antidote_main` instead putting all of this in `antidote`
  # is that this allows the `antidote` function to be overridden via `antidote init`.
  # The init command switches antidote from static mode to dynamic mode, but this
  # core functionality remains.
  setopt extended_glob
  0=${(%):-%x}

  local o_help o_version
  zparseopts $_adote_zparopt_flags -- \
    h=o_help    -help=h    \
    v=o_version -version=v ||
    return 1

  if (( $#o_version )); then
    local ver='1.6.3'
    local gitsha=$(git -C "${0:h}" rev-parse --short HEAD 2>/dev/null)
    [[ -z "$gitsha" ]] || ver="$ver ($gitsha)"
    echo "antidote version $ver"

  elif (( $#o_help )); then
    antidote-help "$@"

  elif [[ $# -eq 0 ]]; then
    antidote-help
    return 2

  elif [[ "$1" = help ]]; then
    local manpage=${2:-antidote}
    antidote-help $manpage

  elif (( $+functions[antidote-${1}] )); then
    local cmd=$1; shift
    antidote-${cmd} "$@"
    return $?

  else
    echo >&2 "antidote: command not found '${1}'" && return 1
  fi
}

### Get the name of the bundle dir.
function __antidote_bundledir {
  # If the bundle is a directory, then we just use that.
  # Otherwise, we assume a git repo. For that, by default, use the legacy antibody format:
  # $ANTIDOTE_HOME/https-COLON--SLASH--SLASH-github.com-SLASH-zsh-users-SLASH-zsh-autosuggestions
  # With `zstyle ':antidote:bundle' use-friendly-names on`, we can simplify to
  # $ANTIDOTE_HOME/zsh-users/zsh-autosuggestions
  emulate -L zsh; setopt local_options extended_glob
  local bundle="$1"
  if [[ -d "$bundle" ]]; then
    echo $bundle
  elif zstyle -t ':antidote:bundle' use-friendly-names; then
    # user/repo format
    # ex: $ANTIDOTE_HOME/zsh-users/zsh-autosuggestions
    bundle=${bundle%.git}
    bundle=${bundle:gs/\:/\/}
    local parts=( $(__antidote_split '/' $bundle) )
    if [[ $#parts -gt 1 ]]; then
      echo $(antidote-home)/${parts[-2]}/${parts[-1]}
    else
      echo $(antidote-home)/$bundle
    fi
  else
    # sanitize URL for safe use as a dir name
    # ex: $ANTIDOTE_HOME/https-COLON--SLASH--SLASH-github.com-SLASH-zsh-users-SLASH-zsh-autosuggestions
    local url=$(__antidote_tourl $bundle)
    url=${url%.git}
    url=${url:gs/\@/-AT-}
    url=${url:gs/\:/-COLON-}
    url=${url:gs/\//-SLASH-}
    echo $(antidote-home)/$url
  fi
}

### Clone a git repo containing a Zsh plugin.
function __antidote_clone {
  emulate -L zsh; setopt local_options extended_glob

  local o_background
  zparseopts $_adote_zparopt_flags -- \
    b=o_background -background=b ||
    return 1

  local bundle=$1
  local branch=$2
  local giturl=$(__antidote_tourl $bundle)
  local bundledir=$(__antidote_bundledir $giturl)

  if [[ ! -d $bundledir ]]; then
    [[ -z "$branch" ]] || branch="--branch=$branch"
    echo >&2 "# antidote cloning $bundle..."
    git clone --quiet --depth 1 --recurse-submodules --shallow-submodules $branch $giturl $bundledir &
    (( $#o_background )) || wait
  fi
}

### Get the path to a plugin's init file.
function __antidote_initfiles {
  emulate -L zsh; setopt local_options extended_glob

  REPLY=()
  local dir=$1
  if [[ ! -d "$dir" ]]; then
    echo >&2 "antidote: bundle directory not found '$dir'."
    return 1
  fi

  local initfiles=($dir/*.plugin.zsh(N))
  [[ $#initfiles -gt 0 ]] || initfiles=($dir/*.zsh(N))
  [[ $#initfiles -gt 0 ]] || initfiles=($dir/*.sh(N))
  [[ $#initfiles -gt 0 ]] || initfiles=($dir/*.zsh-theme(N))
  [[ $#initfiles -gt 0 ]] || {
    echo >&2 "antidote: no plugin init file detected in '$dir'."
    return 1
  }

  REPLY=($initfiles)
  local f
  for f in $initfiles; do
    echo $f
  done
}

### Join an array into a string.
function __antidote_join {
  local sep=$1; shift
  echo ${(pj.$sep.)@}
}

### Determine bundle type: file, dir, url, repo
function __antidote_bundle_type {
  emulate -L zsh; setopt local_options
  REPLY=
  if [[ -z "$1" ]]; then
    echo >&2 "Expecting bundle argument"
    return 1
  elif [[ -f $1 ]]; then
    REPLY=file
  elif [[ -d $1 ]]; then
    REPLY=dir
  elif [[ $1 = /* ]]; then
    echo >&2 "File/Directory bundle does not exist '$1'."
    return 1
  elif [[ $1 = *://* || $1 = git@*:*/* ]]; then
    REPLY=url
  elif [[ $1 = */* ]]; then
    REPLY=repo
  else
    echo >&2 "Unrecognized bundle type '$1'."
    return 1
  fi
  echo $REPLY
}

### Parse antidote's bundle DSL.
function __antidote_parsebundles {
  emulate -L zsh; setopt local_options extended_glob

  # handle bundles as newline delimited arg strings,
  # or as <redirected or piped| input
  local data bundles=()
  if [[ $# -gt 0 ]]; then
    bundles=("${(s.\n.)${@}}")
  elif [[ ! -t 0 ]]; then
    while IFS= read -r data || [[ -n "$data" ]]; do
      bundles+=($data)
    done
  fi
  (( $#bundles )) || return 1

  local bundlestr parts optstr bundle
  for bundlestr in $bundles; do
    # normalize whitespace and remove comments
    bundlestr=${bundlestr//[[:space:]]/ }
    bundlestr=${bundlestr%%\#*}

    # split on spaces into parts array and skip empty lines
    parts=( ${(@s: :)bundlestr} )
    (( $#parts )) || continue

    # the first element is the bundle name, and the remainder are a:b annotations
    # split annotations into key/value pairs
    bundle=( name $parts[1] )
    optstr=( ${parts[@]:1} )
    if (( $#optstr )); then
      parts=( ${(@s/:/)optstr} )
      [[ $(( $#parts % 2 )) -eq 0 ]] || {
        echo >&2 "antidote: bad annotation '$optstr'." && return 1
      }
      bundle+=( $parts )
    fi

    # output the parsed associative array
    __antidote_join $'\t' $bundle
  done
}

### Split a string into an array
function __antidote_split {
  local sep=$1; shift
  echo ${(ps.$sep.)@}
}

### Get the url from a repo bundle.
function __antidote_tourl {
  emulate -L zsh
  setopt local_options extended_glob

  local bundle=$1
  local url=$bundle
  if [[ $bundle != *://* && $bundle != git@*:*/* ]]; then
    url=https://github.com/$bundle
  fi
  echo $url
}

#endregion


#region Completions

_antidote() {
	IFS=' ' read -A reply <<< "help bundle update home purge list load path init install"
}
compctl -K _antidote antidote

#endregion
