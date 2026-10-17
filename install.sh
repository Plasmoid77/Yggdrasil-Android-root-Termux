#!/data/data/com.termux/files/usr/bin/bash
# 1. Checks  2. Packages  3. Binaries  4. Configuration  5. Supervisor
# 6. Install files  7. Start  8. Verify and summary
set -euo pipefail
umask 077
say() { printf '%s\n' "$*"; }
die() { say "ERROR: $*" >&2; exit 1; }
# Quote each argument for su's shell, including paths with spaces or quotes.
root() {
    local command= argument
    for argument in "$PREFIX/bin/bash" "$@"; do
        command+="'${argument//\'/\'\\\'\'}' "
    done
    su -c "exec $command"
}

say '1/8 Checks'
peers=() rebuild=0
while (($#)); do
    case $1 in
        --peer) (($# >= 2)) && [[ $2 == *://?* && $2 != -* ]] || die '--peer needs a URI'
            peers+=("$2"); shift 2 ;;
        --rebuild) rebuild=1; shift ;;
        --help|-h) say 'Usage: bash install.sh [--peer URI]... [--rebuild]'; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[[ -d $source_dir/files && -f $source_dir/patches/android-peer-vpn-bypass.patch ]] ||
    die 'Missing files or patch; run install.sh from a clone of the ultimate branch.'
[[ $(id -u) != 0 ]] || die 'Run as the normal Termux user, without su.'
[[ -n ${PREFIX:-} && -n ${HOME:-} && -x $PREFIX/bin/pkg && -x $PREFIX/bin/bash ]] ||
    die 'Run inside Termux with PREFIX and HOME set.'
[[ $PREFIX == /data/data/com.termux/files/usr ]] ||
    say 'WARNING: Service scripts hardcode /data/data/com.termux/files/usr; this PREFIX differs.'
root -c true || die 'su -c true failed; working root access is required.'
# pm fails when its stdin is a terminal; Android will not accept that descriptor.
if ! root -c 'pm path com.termux.boot' </dev/null 2>/dev/null | grep -q '^package:'; then
    say 'WARNING: Install the Termux:Boot Android app from the same source as Termux.'
fi
say 'Open Termux:Boot once through its launcher icon to activate it.'
service=$PREFIX/var/service/yggdrasil
config=$PREFIX/etc/yggdrasil.conf
boot=$HOME/.termux/boot
endpoint=unix:///data/data/com.termux/files/usr/tmp/yggdrasil.sock
export SVDIR=$PREFIX/var/service LOGDIR=$PREFIX/var/log

say '2/8 Packages'
dpkg-query -W -f='${Status}' root-repo 2>/dev/null | grep -qx 'install ok installed' || pkg install -y root-repo
missing=()
packages=(bash coreutils diffutils termux-tools git golang termux-services iproute2 procps nano curl openssh tcpdump jq)
commands=(bash mkdir cmp termux-wake-lock git go sv ip pgrep nano curl ssh tcpdump jq)
for i in "${!packages[@]}"; do
    command -v "${commands[i]}" >/dev/null || missing+=("${packages[i]}")
done
((${#missing[@]} == 0)) || pkg install -y "${missing[@]}"

say '3/8 Binaries'
mkdir -p -- "$HOME/.cache/yggdrasil-ultimate"
stage=$(mktemp -d "$HOME/.cache/yggdrasil-ultimate/install.XXXXXXXX")
temporary= backup= stopped=0 code_changed=0 new_service=0
cleanup() {
    local result=$?
    trap - EXIT
    [[ -z $temporary ]] || rm -f -- "$temporary"
    rm -rf -- "$stage"
    if ((result && stopped)); then
        # A failure after starting must also leave a disabled, stopped service.
        if [[ ! -e $service/down ]]; then
            touch -- "$service/down"
            sv -w 45 down yggdrasil || {
                say 'ERROR: down is present, but shutdown is unconfirmed; re-run the installer.' >&2
                say "Backup (replaced files only): ${backup:-none}" >&2
                exit "$result"
            }
        fi
        say 'ERROR: Service left stopped with down present; re-run the installer to finish.' >&2
        say "Backup (replaced files only): ${backup:-none}" >&2
    fi
    exit "$result"
}
trap cleanup EXIT
binary=$PREFIX/bin/yggdrasil
control=$PREFIX/bin/yggdrasilctl
if ((rebuild)) || [[ ! -x $control ]] ||
   ! "$binary" -version 2>/dev/null | grep -qx 'Build version: 0.5.14-direct.3'; then
    git clone --depth 1 --branch v0.5.14 https://github.com/yggdrasil-network/yggdrasil-go.git "$stage/yggdrasil-go"
    [[ $(git -C "$stage/yggdrasil-go" rev-parse HEAD) == 422836eeb21a99790caa286aa63d493bbc4766d7 ]] ||
        die 'Unexpected v0.5.14 commit; installed files were not changed.'
    (
        cd -- "$stage/yggdrasil-go"
        git apply --check "$source_dir/patches/android-peer-vpn-bypass.patch" &&
        git apply "$source_dir/patches/android-peer-vpn-bypass.patch" &&
        # Android limits background processes; keep Go package builds small.
        GOFLAGS=-p=2 PKGVER=0.5.14-direct.3 ./build -p -l '-checklinkname=0'
    ) || die 'Build failed; installed Yggdrasil files were not changed.'
    binary=$stage/yggdrasil-go/yggdrasil
    control=$stage/yggdrasil-go/yggdrasilctl
    "$binary" -version | grep -qx 'Build version: 0.5.14-direct.3' || die 'Unexpected build version.'
    [[ -x $control ]] || die 'The build did not produce yggdrasilctl.'
else
    say 'Patched binaries are already installed; skipping build.'
fi

say '4/8 Configuration'
candidate=$config
if [[ -e $config ]]; then
    ((${#peers[@]} == 0)) || say 'WARNING: Existing config kept; --peer did not change its peers.'
    grep -Fq -- "$endpoint" "$config" || say "WARNING: AdminListen differs from $endpoint; control commands may fail."
else
    candidate=$stage/yggdrasil.conf
    peer_json=$(jq -cn --args '$ARGS.positional' "${peers[@]}")
    "$binary" -genconf -json 2>/dev/null |
        jq --arg endpoint "$endpoint" --argjson peers "$peer_json" '
            .IfName = "ygg0" | .AdminListen = $endpoint | .Peers = $peers |
            .Listen = [] | .MulticastInterfaces = [
                {Regex:"^wlan[0-9]+$", Beacon:true, Listen:true, Port:0, Priority:0}]' > "$candidate" || die 'Config generation failed.'
fi
# Parser diagnostics may contain key material, so extract only these fields.
ifname=$("$binary" -useconffile "$candidate" -normaliseconf -json 2>/dev/null |
    jq -er '.IfName') || die 'Cannot validate config; it was not changed.'
[[ $ifname == ygg0 ]] || die 'IfName must be ygg0. Edit the existing config and retry.'
peer_count=$("$binary" -useconffile "$candidate" -normaliseconf -json 2>/dev/null |
    jq -er '.Peers | length') || die 'Cannot validate Peers.'
if ((peer_count == 0)); then
    say "WARNING: Only Wi-Fi multicast neighbours can connect. Add 2–3 public peers to $config"
    say 'Choose peers from https://github.com/yggdrasil-network/public-peers, then sv restart yggdrasil.'
fi
cp -R -- "$source_dir/files" "$stage/files"

say '5/8 Supervisor'
(umask 022; termux-wake-lock; . "$PREFIX/etc/profile.d/start-services.sh")
wait_supervisor() {
    local deadline=$((SECONDS + 15))
    until sv status yggdrasil >/dev/null 2>&1; do
        ((SECONDS < deadline)) || die 'No runit supervisor after 15 s; check service-daemon.'
        sleep 1
    done
}
[[ ! -d $service ]] || wait_supervisor

# Back up only files we replace, never the node configuration.
make_backup() {
    [[ -z $backup ]] || return 0
    backup=$HOME/yggdrasil-backup-$(date +%Y%m%d-%H%M%S)
    mkdir -m 700 -- "$backup" || die 'Backup path exists; retry in a second.'
    say "Backup: $backup"
}
put_file() {
    mkdir -p -- "${2%/*}"
    temporary=$(mktemp "${2%/*}/.ygg-install.XXXXXXXX")
    cp -- "$1" "$temporary"
    chmod "$3" -- "$temporary"
    mv -f -- "$temporary" "$2"
    temporary=
}
put_code() {
    cmp -s -- "$1" "$2" && return 0
    if ((!new_service && !stopped)); then
        local created_down=0
        if [[ ! -e $service/down ]]; then touch -- "$service/down"; created_down=1; fi
        if ! sv -w 45 down yggdrasil; then
            ((created_down == 0)) || rm -f -- "$service/down"
            die 'Could not stop the service; no code replaced. Re-run the installer after fixing supervision.'
        fi
        stopped=1
    fi
    if [[ -f $2 ]]; then
        make_backup
        local saved=$backup/usr/${2#"$PREFIX"/}
        mkdir -p -- "${saved%/*}"
        cp -p -- "$2" "$saved"
    fi
    put_file "$@"
    code_changed=1
}
put_setting() {
    if [[ -e $2 ]]; then
        if [[ $2 == "$boot/10-services.sh" ]] && ! cmp -s -- "$1" "$2"; then
            say "NOTE: Keeping your existing $2"
        fi
        return 0
    fi
    put_file "$@"
}

say '6/8 Install files'
if [[ ! -d $service ]]; then
    # runsvdir ignores dot directories; runsv must see log/ and down at discovery.
    rm -rf -- "$PREFIX/var/service/.yggdrasil"
    mkdir -p -- "$PREFIX/var/service/.yggdrasil/log"
    touch -- "$PREFIX/var/service/.yggdrasil/down"
    mv -- "$PREFIX/var/service/.yggdrasil" "$service"
    new_service=1 stopped=1
fi
mkdir -p -- "$PREFIX/var/log/sv/yggdrasil" "$PREFIX/var/run"
[[ $(stat -c %a -- "$PREFIX/var/log/sv/yggdrasil") == 700 ]] || chmod 700 -- "$PREFIX/var/log/sv/yggdrasil"
put_code "$binary" "$PREFIX/bin/yggdrasil" 755
put_code "$control" "$PREFIX/bin/yggdrasilctl" 755
put_code "$stage/files/usr/var/service/yggdrasil/firewall" "$service/firewall" 700
put_code "$stage/files/usr/var/service/yggdrasil/ula" "$service/ula" 700
put_code "$stage/files/usr/var/service/yggdrasil/finish" "$service/finish" 700
put_code "$stage/files/usr/var/service/yggdrasil/log/run" "$service/log/run" 700
put_code "$stage/files/usr/var/service/yggdrasil/run" "$service/run" 700
put_setting "$candidate" "$config" 600
put_setting "$stage/files/usr/etc/yggdrasil-trusted" "$PREFIX/etc/yggdrasil-trusted" 600
put_setting "$stage/files/usr/var/log/sv/yggdrasil/config" "$PREFIX/var/log/sv/yggdrasil/config" 600
put_setting "$stage/files/home/.termux/boot/10-services.sh" "$boot/10-services.sh" 700
if [[ $candidate != "$config" ]]; then
    say "NOTE: The node identity (private key) is in $config. Keep a private copy; it is not in the installer backup."
fi

say '7/8 Start'
wait_supervisor
firewall_state='existing service was not stopped'
((stopped == 0)) || firewall_state='service is stopped with down present'
"$service/firewall" || die "Firewall setup failed ($firewall_state); re-run the installer."
rm -f -- "$service/down"
if ! sv -w 45 up yggdrasil; then
    say 'WARNING: Service start timed out; continuing to verification.'
fi

say '8/8 Verify and summary'
deadline=$((SECONDS + 45))
running='^run: [^(]*\(pid [0-9]+\) ([0-9]+)s'
while :; do
    status=$(sv status yggdrasil 2>/dev/null) || status=
    node=$(root -c 'ip -6 -o addr show dev ygg0 scope global' 2>/dev/null |
        awk '$3 == "inet6" && $4 ~ /^[23][0-9a-fA-F][0-9a-fA-F]:.*\/7$/ {sub(/\/7$/, "", $4); print $4; exit}') || node=
    rules=$(root -c 'ip -6 rule show' 2>/dev/null) || rules=
    input=$(root -c 'ip6tables -w 10 -S INPUT' 2>/dev/null) || input=
    if [[ $status =~ $running ]] && ((BASH_REMATCH[1] >= 10)) && [[ -n $node ]] &&
       grep -Eq '^1000:[[:space:]]+from all to 200::/7 lookup 200([[:space:]]|$)' <<< "$rules" &&
       [[ $(grep -Fxc -- '-A INPUT -i ygg0 -j YGG_IN' <<< "$input") == 1 ]]; then
        break
    fi
    if ((SECONDS >= deadline)); then
        say 'ERROR: Verification failed. Last service log lines:' >&2
        tail -n 30 -- "$PREFIX/var/log/sv/yggdrasil/current" 2>/dev/null || true
        say "Backup (replaced files only): ${backup:-none}"
        die 'Re-run the installer; to go back, restore the files from the backup with the service down.'
    fi
    sleep 1
done
up=$(root -c 'exec "$1/bin/timeout" 10 "$1/bin/yggdrasilctl" "-endpoint=$2" -json getPeers' \
    ygg-installer "$PREFIX" "$endpoint" 2>/dev/null |
    jq -er '[.peers[] | select(.up == true)] | length') || up=unavailable
say "Node: $node; peers up: $up; code changed: $code_changed"
say "Backup (replaced code files only; no node config): ${backup:-none}"
say "Trusted devices: edit $PREFIX/etc/yggdrasil-trusted; run $service/firewall"
say "Peers: edit $config; then sv restart yggdrasil"
