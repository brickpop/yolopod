# lib.sh — the logic shared by every yolopod launcher. Sourced, never run.
#
# A launcher (see pclaude, pcodex) sets:
#   NAME     its command name, e.g. pclaude; also the --NAME-* option namespace
#   PREFIX   its environment namespace, e.g. PCLAUDE (PCLAUDE_IMAGE, PCLAUDE_ARGS...)
#   TOOL     the harness, for messages, e.g. "Claude Code"
#   FORWARD  host env vars passed into the container when set, on top of the common ones
#   SHARE    the dir holding this file and the Containerfile
# defines:
#   harness_examples   usage lines for --NAME-help
#   harness_before     host-side preparation (config dirs, logins); may die
#   harness_mounts     its config mounts, via `volume`
#   harness_cmd        sets `cmd` to the harness command line
#   harness_after      host-side cleanup once the container exits
# and finally calls `yolopod_main "$@"`.

# The value of ${PREFIX}_$1, e.g. `opt ARGS` reads PCLAUDE_ARGS from pclaude.
opt() { local var="${PREFIX}_$1"; printf '%s' "${!var-}"; }

die() { printf '%s: %s\n' "$NAME" "$*" >&2; exit 1; }

usage() {
  cat <<EOF
Usage: $NAME [--$NAME-*] [args...]

Everything that is not a --$NAME-* option goes to $TOOL untouched:
$(harness_examples)

Launcher options (before the other args):
  --$NAME-build    Build the image
  --$NAME-update   Rebuild it from scratch (--pull --no-cache)
  --$NAME-shell    Open a shell in the container instead of $TOOL
  --$NAME-help     This message

Environment:
  ${PREFIX}_IMAGE       Image name                 (default: localhost/yolopod)
  ${PREFIX}_HOME        Dir with the Containerfile (default: ~/.local/share/yolopod)
  ${PREFIX}_ARGS        Extra podman run args      (e.g. "-v /data:/data:z -e FOO=bar")
  ${PREFIX}_NO_YOLO     Set to 1 to bring back $TOOL's approval prompts
  ${PREFIX}_RELABEL     SELinux mount label: auto (default), z, Z or off
  ${PREFIX}_ALLOW_HOME  Set to 1 to allow running in \$HOME
EOF
}

build_image() {
  [ -f "$SHARE/Containerfile" ] || die "no Containerfile in $SHARE — re-run install.sh from the repo"
  podman build -t "$IMAGE" "$@" "$SHARE"
}

# volume SRC DST [ro] — bind mount with the SELinux relabel suffix, if any.
volume() {
  local opts="${3:-}"
  [ -z "$Z" ] || opts="${opts:+$opts,}$Z"
  args+=(--volume "$1:$2${opts:+:$opts}")
}

yolopod_main() {
  # Fully qualified so Podman resolves this locally instead of querying registries.
  IMAGE="$(opt IMAGE)"; IMAGE="${IMAGE:-localhost/yolopod}"
  local mode=run var status relabel extra=()

  while [ $# -gt 0 ]; do
    case "$1" in
      "--$NAME-help")   usage; exit 0 ;;
      "--$NAME-build")  mode=build; shift ;;
      "--$NAME-update") mode=update; shift ;;
      "--$NAME-shell")  mode=shell; shift ;;
      *) break ;;
    esac
  done

  case "$mode" in
    build)  build_image "$@"; exit 0 ;;
    update) build_image --pull --no-cache "$@"; exit 0 ;;
  esac

  # Guard against relabelling / exposing an entire home directory by accident.
  case "$PWD" in
    /) die "refusing to run in /" ;;
    "$HOME") [ "$(opt ALLOW_HOME)" = 1 ] || die "refusing to mount all of \$HOME (set ${PREFIX}_ALLOW_HOME=1 to override)" ;;
  esac

  # SELinux hosts (Fedora, RHEL...) need a relabel suffix on bind mounts:
  #   z    shared label, lets concurrent sessions share the harness config
  #   Z    private label, stricter, for one session at a time
  #   off  plain bind mounts
  relabel="$(opt RELABEL)"; relabel="${relabel:-auto}"
  if [ "$relabel" = auto ]; then
    if [ -f /sys/fs/selinux/enforce ]; then relabel=z; else relabel=off; fi
  fi
  case "$relabel" in
    z|Z) Z="$relabel" ;;
    off) Z="" ;;
    *)   die "${PREFIX}_RELABEL must be z, Z, off or auto" ;;
  esac

  if ! podman image exists "$IMAGE"; then
    echo "$NAME: image $IMAGE not found, building it once..." >&2
    build_image
  fi

  harness_before

  # The project keeps its host path inside the container, so the harness keys its
  # per-project session history the same way it does on the host.
  args=(
    --rm --interactive --tty
    --hostname "$NAME"
    # The harness runs unprivileged and needs no capabilities; nothing may regain them via setuid.
    --cap-drop all
    --security-opt no-new-privileges
    --userns "keep-id:uid=1000,gid=1000"
  )
  volume "$PWD" "$PWD"
  args+=(--workdir "$PWD")
  harness_mounts
  if [ -f "$HOME/.gitconfig" ]; then volume "$HOME/.gitconfig" /home/node/.gitconfig ro; fi

  for var in "${FORWARD[@]}" GH_TOKEN TERM COLORTERM; do
    if [ -n "${!var-}" ]; then args+=(--env "$var=${!var}"); fi
  done

  # Word-split ${PREFIX}_ARGS the way a shell would.
  if [ -n "$(opt ARGS)" ]; then
    read -r -a extra <<<"$(opt ARGS)"
    args+=("${extra[@]}")
  fi

  # Name the command explicitly, so any other one can replace it.
  if [ "$mode" = shell ]; then cmd=(bash); else harness_cmd; fi

  # No exec: harness_after still has to run once the container exits.
  status=0
  podman run "${args[@]}" "$IMAGE" "${cmd[@]}" "$@" || status=$?
  harness_after
  exit "$status"
}
