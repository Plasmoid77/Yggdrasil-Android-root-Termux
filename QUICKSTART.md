# Yggdrasil on rooted Android via Termux — Quick Setup

> **Tested with Yggdrasil v0.5.14 on LineageOS 23 (Android 16).**
>
> **Guide by Plasmoid (Neuroslopped)**

Installation steps. See the [full installation guide](docs/INSTALL.md) for explanations and verification.

This branch includes direct TCP-based and QUIC/UDP peer transport outside an Android VPN, the event-driven ULA handler and the existing firewall. Android chooses Wi-Fi or mobile data without an extra switching service. [Transport details and verification](DIRECT-TRANSPORT.md).

## 1. Requirements

- Rooted Android with working `su -c`.
- Termux and the separate **Termux:Boot Android app**.

Use the same signing source for both APKs (F-Droid or official GitHub releases); mixed signatures prevent installation. [Termux installation requirements](https://github.com/termux/termux-app#installation).

### Install and activate Termux:Boot first

1. **Install Termux:Boot as an Android app**, using matching signatures with Termux. It is not installed by `pkg`.
2. **Open Termux:Boot once through its launcher icon** to enable automatic execution at boot. Opening Termux does not replace this step.

The steps below create both boot scripts and enable the service. After completing them, you do not need to open Termux after every reboot. [Official Termux:Boot instructions](https://github.com/termux/termux-boot#how-to-use).

## 2. Install packages

```sh
pkg update
```

```sh
pkg install root-repo
```

```sh
pkg update
```

```sh
pkg install bash coreutils termux-tools git golang termux-services iproute2 procps nano curl openssh tcpdump
```

Run package and build commands as the normal Termux user. `bash`, `coreutils` and `termux-tools` supply the shell, file utilities and wake lock; `git`/`golang` build the binaries, and `termux-services`/`iproute2`/`procps` supply supervision and networking tools. `nano` is the editor. `curl`, `openssh` and `tcpdump` are used by the full guide's verification steps. Root comes from `su`; no `sudo` or `tsu` package is needed.

## 3. Build Yggdrasil

```sh
cd ~
git clone --depth 1 --branch ultimate https://github.com/Plasmoid77/Yggdrasil-Android-root-Termux.git yggdrasil-android-guide
```

```sh
cd ~
```

```sh
git clone --depth 1 --branch v0.5.14 https://github.com/yggdrasil-network/yggdrasil-go.git
```

```sh
cd ~/yggdrasil-go
```

```sh
git apply --check ~/yggdrasil-android-guide/patches/android-peer-vpn-bypass.patch
git apply ~/yggdrasil-android-guide/patches/android-peer-vpn-bypass.patch
PKGVER=0.5.14-direct.3 ./build -p -l "-checklinkname=0"
```

Use fresh source: apply the patch once. `git apply --check` only checks applicability; `git apply` changes source; `./build` produces both binaries for the installation step below. `PKGVER` labels the build, `-p` enables PIE and `-l` passes a linker option. VPN bypass comes from marking TCP and QUIC/UDP sockets in the modified source. [Command explanations and patch internals](docs/INSTALL.md#5-build-yggdrasil-natively-for-android). For an existing node, preserve its key/configuration and follow [the update procedure](docs/INSTALL.md#19-updating-yggdrasil).

## 4. Create the configuration

The generation command below is for a new node. When reinstalling, back up the installed binaries, configuration and service/boot scripts, then copy `$PREFIX/etc/yggdrasil.conf` to `~/yggdrasil.conf` with mode600 instead of generating a new identity. Use fresh clone directories for a rebuild.

```sh
./yggdrasil -genconf > ~/yggdrasil.conf
```

```sh
nano ~/yggdrasil.conf
```

Add **2–3 current nearby peers** using a supported transport from:

https://github.com/yggdrasil-network/public-peers

Tested example (check current peer availability):

```text
Peers: [
  tcp://87.249.44.53:18226
  tcp://217.144.163.22:7991
]
InterfacePeers: {}
Listen: []
MulticastInterfaces: [
  {
    Regex: "^wlan[0-9]+$"
    Beacon: true
    Listen: true
    Port: 0
    Priority: 0
  }
]
```

Use ordinary `Peers` without pinned interface names. IPv4 literals avoid peer DNS through the VPN. The patch covers all outgoing peer schemes in v0.5.14: TCP, TLS, WS, WSS, SOCKS, SOCKS+TLS and QUIC; UNIX sockets are local. For SOCKS, the marked socket reaches the proxy; its onward route is controlled by that proxy. [Coverage](docs/INSTALL.md#104-direct-peer-transport).

Multicast advertises and discovers local Yggdrasil nodes on Wi-Fi (`wlanN`) through IPv6 link-local UDP port 9001, then establishes TLS/TCP peer connections. `Port: 0` selects the local TCP port automatically; keep the regular `Listen: []`. A direct local peer connection lets a compatible OpenWrt status module show the phone's `node` address. The Wi-Fi regex only limits discovery: public peers still work over Wi-Fi or mobile data. No extra service or firewall rule is needed. To disable discovery, use `MulticastInterfaces: []`. [Details](docs/INSTALL.md#wi-fi-multicast-discovery).

Set:

```text
IfName: ygg0
```

Add `AdminListen` as a top-level field inside the outer `{ ... }` configuration object if it is not already present:

```text
AdminListen: unix:///data/data/com.termux/files/usr/tmp/yggdrasil.sock
```

## 5. Install binaries and configuration

For an existing installation, stop the service before replacing its files:

```sh
sv -w 25 down yggdrasil
```

Keep it stopped until the firewall is applied and the service is enabled below.

```sh
install -m 755 ~/yggdrasil-go/yggdrasil "$PREFIX/bin/yggdrasil"
```

```sh
install -m 755 ~/yggdrasil-go/yggdrasilctl "$PREFIX/bin/yggdrasilctl"
```

```sh
install -m 600 ~/yggdrasil.conf "$PREFIX/etc/yggdrasil.conf"
```

## 6. Create the runit service

```sh
mkdir -p "$PREFIX/var/service/yggdrasil"
```

```sh
touch "$PREFIX/var/service/yggdrasil/down"
```

Create `run`:

```sh
nano "$PREFIX/var/service/yggdrasil/run"
```

```sh
#!/data/data/com.termux/files/usr/bin/sh
# Yggdrasil uses ygg0; Android VpnService uses tunN.
# Merge stderr into stdout for runit service output.
exec 2>&1

# Run the following Bash block in one persistent root session.
# Keep the outer shell waitable by runit; finish stops Yggdrasil.
su -c 'exec /data/data/com.termux/files/usr/bin/bash -s' <<'YGG_ROOT' &
children=()

# Stop and reap all owned child processes when the root session exits.
cleanup() {
    trap - EXIT
    ((${#children[@]})) && kill "${children[@]}" 2>/dev/null
    wait 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 0' TERM INT HUP

# Subscribe before taking the initial snapshot so startup events are queued.
coproc NET_EVENTS { exec ip -o monitor link address route rule; }
monitor_pid=$NET_EVENTS_PID
children+=("$monitor_pid")
# Duplicate the event stream so the background worker can read it.
exec 3<&"${NET_EVENTS[0]}"

# Wait up to five seconds for the Netlink subscription at startup only.
subscribed=0
for ((attempt=0; attempt<100; attempt++)); do
    while read -r socket protocol port groups rest; do
        if [[ $protocol == 0 && $port == "$monitor_pid" && $groups != 00000000 ]]; then
            subscribed=1; break
        fi
    done < /proc/net/netlink
    ((subscribed)) && break
    kill -0 "$monitor_pid" 2>/dev/null || break
    sleep 0.05
done
((subscribed)) || { echo 'ERROR: Netlink subscription failed'; exit 1; }

# Maintain one fixed ULA on UP TUN interfaces named tunN.
# Derive the fixed address from this node and use it on physical interfaces too.
# Add a local IPv6 path only to IPv4-only physical interfaces.
# The same path now covers IPv4-only TUN interfaces as well.
# These addresses are not public IPv6 connectivity or Yggdrasil identities.
ula=
primary_dev=
declare -A ula_index=() ula_original=() ula_failed=()
declare -A ula_window=() ula_updates=()

init_ula() {
    local index dev family address rest
    while read -r index dev family address rest; do
        [[ $family == inet6 && $address =~ ^[23][0-9a-f]{2}:.*/7$ ]] || continue
        # Preserve canonical formatting and the node's low 112 bits; avoid LAN duplicates.
        ula="fd42:${address#*:}"
        ula="${ula%/7}/128"
        return 0
    done < <(ip -6 -o addr show dev ygg0 scope global)
    return 1
}

other_ipv6() {
    local index dev family address rest
    while read -r index dev family address rest; do
        [[ $family == inet6 && $address != "$ula" ]] && return 0
    done <<< "$1"
    return 1
}

release_ula() {
    local dev=$1 current addresses ula=$ula
    [[ $dev != tun* ]] || ula=fd42::1/128
    [[ -n ${ula_index[$dev]:-} ]] || return 0
    current=$(cat "/sys/class/net/$dev/ifindex" 2>/dev/null) || current=
    if [[ $current == "${ula_index[$dev]}" ]]; then
        ip -6 addr del "$ula" dev "$dev" 2>/dev/null || true
        addresses=$(ip -6 -o addr show dev "$dev" scope global 2>/dev/null) || addresses=
        # Never disable IPv6 after the network acquires its own global address.
        if [[ ${ula_original[$dev]} == 1 ]] && ! other_ipv6 "$addresses"; then
            printf '1\n' > "/proc/sys/net/ipv6/conf/$dev/disable_ipv6" || true
        fi
    fi
    unset 'ula_index[$dev]' 'ula_original[$dev]'
}

cleanup_ula() {
    local dev
    for dev in "${!ula_index[@]}"; do release_ula "$dev"; done
}

ensure_ula() {
    local dev=$1 index flags ipv4 addresses disabled current tun_flags ula=$ula
    [[ $dev != tun* ]] || ula=fd42::1/128
    [[ -n $ula ]] || return 0
    [[ $dev =~ ^(tun|rmnet_data|wlan)[0-9]+$ ]] || return 0
    if [[ $dev == tun* ]]; then
        read -r tun_flags < "/sys/class/net/$dev/tun_flags" 2>/dev/null || return 0
        # Require TUN and UP; skip TAP and interfaces that are down.
        ((tun_flags & 1)) || return 0
    fi
    [[ $dev == tun* || $dev == "$primary_dev" ]] || { release_ula "$dev"; return 0; }
    { read -r index < "/sys/class/net/$dev/ifindex" &&
      read -r flags < "/sys/class/net/$dev/flags"; } 2>/dev/null || { release_ula "$dev"; return 0; }
    if [[ ${ula_index[$dev]:-} != "$index" ]]; then
        unset 'ula_index[$dev]' 'ula_original[$dev]'
    fi
    ipv4=$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null) || ipv4=
    if (( !(flags & 1) )) || [[ -z $ipv4 ]]; then release_ula "$dev"; return 0; fi
    addresses=$(ip -6 -o addr show dev "$dev" scope global 2>/dev/null) || return 0
    if other_ipv6 "$addresses"; then release_ula "$dev"; return 0; fi
    # Leave the address unchanged when it is already present.
    [[ $addresses == *"inet6 $ula "* ]] && return 0
    [[ ${ula_failed[$dev]:-} != "$index" ]] || return 0
    read -r disabled < "/proc/sys/net/ipv6/conf/$dev/disable_ipv6" || return 0
    [[ $disabled == 0 || $disabled == 1 ]] || return 0

    # Stop an address-reset feedback burst instead of spending CPU in a loop.
    if [[ ${ula_window[$dev]:-} != "$index:"* ]] ||
       (( SECONDS - ${ula_window[$dev]#*:} >= 10 )); then
        ula_window[$dev]="$index:$SECONDS"
        ula_updates[$dev]=0
    fi
    if (( ${ula_updates[$dev]:-0} >= 4 )); then
        echo "[ULA] Repeated resets on $dev; waiting for a later network event"
        return 0
    fi
    ula_updates[$dev]=$(( ${ula_updates[$dev]:-0} + 1 ))
    if [[ -z ${ula_index[$dev]:-} ]]; then
        ula_index[$dev]=$index
        ula_original[$dev]=$disabled
    fi
    current=$(cat "/sys/class/net/$dev/ifindex" 2>/dev/null) || current=
    [[ $current == "$index" ]] || { release_ula "$dev"; return 0; }
    if { [[ $disabled == 0 ]] || printf '0\n' > "/proc/sys/net/ipv6/conf/$dev/disable_ipv6"; } &&
       ip -6 addr replace "$ula" dev "$dev"; then
        echo "[ULA] Added $ula to $dev"
    else
        release_ula "$dev"
        ula_failed[$dev]=$index
        echo "[ULA] Setup failed on $dev; waiting for interface recreation"
    fi
}

refresh_primary() {
    local route previous=$primary_dev
    primary_dev=
    route=$(ip -4 route get 1.1.1.1 mark 0x20000 2>/dev/null) || route=
    [[ $route =~ [[:space:]]dev[[:space:]]([^[:space:]]+) ]] && primary_dev=${BASH_REMATCH[1]}
    [[ $primary_dev != "$previous" ]] || return 0
    [[ -z $previous ]] || ensure_ula "$previous"
    [[ -z $primary_dev ]] || ensure_ula "$primary_dev"
}

# Send all traffic destined for the Yggdrasil 200::/7 network to routing table 200.
ip -6 rule add to 200::/7 lookup 200 prio 1000 2>/dev/null || true

# Remove a stale ygg0 interface left by an unclean previous shutdown.
ip link del ygg0 2>/dev/null || true

# Prepare the standard /dev/net/tun path for the TUN interface.
mkdir -p /dev/net && ln -sf /dev/tun /dev/net/tun || exit 1

# Start Yggdrasil with root privileges.
/data/data/com.termux/files/usr/bin/yggdrasil -useconffile /data/data/com.termux/files/usr/etc/yggdrasil.conf &
ygg_pid=$!
children+=("$ygg_pid")

# Wait up to 30 seconds for ygg0 to appear.
for ((attempt=0; attempt<30; attempt++)); do
    ip link show ygg0 >/dev/null 2>&1 &&
        ip -6 -o addr show dev ygg0 scope global 2>/dev/null | grep -q '/7 ' && break
    kill -0 "$ygg_pid" 2>/dev/null || exit 1
    sleep 1
done
# Once ygg0 exists, route the Yggdrasil network through it in table 200.
ip -6 route replace 200::/7 dev ygg0 metric 128 table 200 || exit 1

# Check existing interfaces once, then handle events without a timer.
(
    trap cleanup_ula EXIT
    trap 'exit 0' TERM INT HUP
    init_ula || { echo 'ERROR: Native Yggdrasil address is unavailable'; exit 1; }
    refresh_primary
    for path in /sys/class/net/tun[0-9]* /sys/class/net/rmnet_data[0-9]* /sys/class/net/wlan[0-9]*; do ensure_ula "${path##*/}"; done
    while IFS= read -r event <&3; do
        # Extract the interface name, including from address deletion events.
        read -r index dev rest <<< "${event#Deleted }"
        if [[ $index =~ ^[0-9]+:$ && $dev != from ]]; then
            dev=${dev%:}; dev=${dev%%@*}
            ensure_ula "$dev"
        else
            refresh_primary
        fi
    done
    exit 1
) &
worker_pid=$!
children+=("$worker_pid")
exec 3<&-

# Exit and clean up if Yggdrasil, the monitor or the worker stops.
# An enabled runit service can then restart the complete run script.
wait -n "$ygg_pid" "$monitor_pid" "$worker_pid"
YGG_ROOT
# Keep the run script alive for as long as the Yggdrasil process is running.
wait "$!"
```

Create `finish`:

```sh
nano "$PREFIX/var/service/yggdrasil/finish"
```

```sh
#!/data/data/com.termux/files/usr/bin/sh

# Stop Yggdrasil.
su -c "pkill -f '[y]ggdrasil -useconffile /data/data/com.termux/files/usr/etc/yggdrasil.conf' 2>/dev/null || true"

# Remove ygg0 if it still exists.
su -c 'ip link del ygg0 2>/dev/null || true'

# Remove the policy rule that sends the Yggdrasil network to routing table 200.
su -c 'ip -6 ru del to 200::/7 lookup 200 prio 1000 2>/dev/null || true'

exit 0
```

Make both scripts executable:

```sh
chmod +x "$PREFIX/var/service/yggdrasil/run" "$PREFIX/var/service/yggdrasil/finish"
```

### 6.1 IPv4-only VPN and physical Internet compatibility

One handler maintains `fd42::1/128` on eligible IPv4-only TUN interfaces and a node-derived ULA on the current IPv4-only physical Internet interface. Existing IPv6 is preserved; IMS and hotspot downstream interfaces are excluded. Link/address/route/rule events handle interface recreation and uplink changes, without a separate switching service or polling timer.

After connecting a VPN, find its interface:

```sh
su -c 'ip -br addr'
```

For a matching interface such as `tun0`, check:

```sh
su -c 'ip -6 -o addr show dev tun0'
```

For an IPv4-only VPN without another global-scope IPv6 address, expect `fd42::1/128`. Reconnect and check the current interface again. For an IPv4-only physical Internet network, use the marked route lookup below and inspect its returned `dev`; expect `fd42:` followed by the native Yggdrasil address's remaining seven groups, with `/128`.

```sh
su -c 'ip -4 route get 1.1.1.1 mark 0x20000'
```

The lookup sends no packet. A dual-stack network needs no added ULA. A hotspot's `wlanN` is not an Internet uplink merely because its name matches.

The ULA is a local compatibility address, not general IPv6 Internet access. Yggdrasil destinations continue to use rule `1000` and `ygg0`.

A new call with the final handler passed on an IPv4-only mobile APN with AmneziaWG: ICE connected in about 0.44 seconds and bidirectional media used native Yggdrasil addresses. Earlier VPN-switching and reboot tests used the previous handler. This script does not manage mid-call ICE recovery; verify your own network/VPN combination.

See [installation guide section 10.3](docs/INSTALL.md#103-android-vpn--webrtcvoip-compatibility) for the reproduced problem, implementation, test results and limits.

## 7. Configure the firewall

```sh
mkdir -p "$HOME/.termux/boot"
```

Create:

```sh
nano "$HOME/.termux/boot/05-ygg-firewall.sh"
```

```sh
#!/data/data/com.termux/files/usr/bin/sh

# Allow replies to connections initiated by the phone and related traffic.
su -c '/system/bin/ip6tables -C INPUT -i ygg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || /system/bin/ip6tables -A INPUT -i ygg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT'

# Drop packets that conntrack cannot classify as a valid connection state.
su -c '/system/bin/ip6tables -C INPUT -i ygg0 -m conntrack --ctstate INVALID -j DROP 2>/dev/null || /system/bin/ip6tables -A INPUT -i ygg0 -m conntrack --ctstate INVALID -j DROP'

# Drop all other inbound traffic arriving through the Yggdrasil interface.
su -c '/system/bin/ip6tables -C INPUT -i ygg0 -j DROP 2>/dev/null || /system/bin/ip6tables -A INPUT -i ygg0 -j DROP'
```

```sh
chmod +x "$HOME/.termux/boot/05-ygg-firewall.sh"
```

Apply it immediately:

```sh
"$HOME/.termux/boot/05-ygg-firewall.sh"
```

## 8. Configure Termux:Boot

Create:

```sh
nano "$HOME/.termux/boot/10-services.sh"
```

```sh
#!/data/data/com.termux/files/usr/bin/sh

termux-wake-lock
. /data/data/com.termux/files/usr/etc/profile.d/start-services.sh
```

```sh
chmod +x "$HOME/.termux/boot/10-services.sh"
```

The firewall script can also be executed manually from Termux to apply its rules to the current boot; see the [manual command and checks](docs/INSTALL.md#11-firewall). Opening Termux or starting the supervisor does not run that script; Termux:Boot supplies the automatic boot trigger. [Details](docs/INSTALL.md#123-manual-execution-and-shell-startup).

## 9. Start and enable Yggdrasil

Start `termux-services` in the current Android session:

```sh
. /data/data/com.termux/files/usr/etc/profile.d/start-services.sh
```

After creating or recreating the service directory, wait for its supervisor endpoint and enable Yggdrasil:

```sh
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
    sv status yggdrasil >/dev/null 2>&1 && break
    sleep 1
done
if sv status yggdrasil >/dev/null 2>&1; then
    sv-enable yggdrasil
else
    echo 'ERROR: runit did not create supervise/ok; check the service supervisor.' >&2
    false
fi
```

This waits at most fifteen seconds during installation and enables the service only after `runit` has discovered it. It adds no background polling loop.

Yggdrasil is now managed with:

```sh
sv status yggdrasil
```

```sh
sv up yggdrasil
```

```sh
sv down yggdrasil
```

```sh
sv restart yggdrasil
```

## 10. Yggdrasil control commands

Show this node:

```sh
su -c "$PREFIX/bin/yggdrasilctl -endpoint=unix://$PREFIX/tmp/yggdrasil.sock getSelf"
```

Show peers:

```sh
su -c "$PREFIX/bin/yggdrasilctl -endpoint=unix://$PREFIX/tmp/yggdrasil.sock getPeers"
```

After editing the peer list in:

```text
$PREFIX/etc/yggdrasil.conf
```

restart Yggdrasil:

```sh
sv restart yggdrasil
```

## 11. Reboot

Reboot Android normally.

Termux:Boot will restore the firewall and start `termux-services`; `runit` will then start Yggdrasil automatically.

After reboot, follow [installation guide section 16](docs/INSTALL.md#16-verify-everything-after-reboot), including the patched version, physical peer socket marks and ULA checks. A clean reinstall and Android reboot passed with the earlier published direct profile; they were not repeated with this new ULA handler. Verify the installed profile after reboot.

A separate QUIC-only reboot with `0.5.14-direct.3` passed on 2026-10-10: Termux:Boot started the daemon and both peers automatically, with direct physical traffic, restored firewall/routing and the same node identity. The temporary QUIC test config was then replaced with the original TCP peers and Wi-Fi multicast. See [QUIC checks and call-test limits](DIRECT-TRANSPORT.md#quic-handover-calls-and-reboot).

## 12. Updating Yggdrasil

Follow [installation guide section 19](docs/INSTALL.md#19-updating-yggdrasil): select a release, build both Android/cgo binaries in a fresh directory, back up the old binaries and config, validate the existing config and node address, then stop only Yggdrasil, install both binaries and restart it. Keep the private key, peers, multicast, service/boot scripts and firewall; do not regenerate the config. The section includes post-update checks and rollback commands.

This profile must preserve the outgoing TCP-based and QUIC/UDP socket patch. It is tested on v0.5.14; check and adapt it for a new release before building. A clean patch application or version suffix is not proof of VPN bypass: verify the physical peer sockets/traffic with the VPN active. An unpatched binary removes bypass.
