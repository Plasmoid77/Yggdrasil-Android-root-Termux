# Yggdrasil on rooted Android via Termux — Quick Setup

> **Tested with Yggdrasil v0.5.14 on LineageOS 23 (Android 16).**
>
> **Guide by Plasmoid (Neuroslopped)**

Follow these installation steps. The [full installation guide](docs/INSTALL.md) explains the setup and checks.

This branch sends TCP-based and QUIC/UDP peer traffic outside the Android VPN. It includes an event-driven ULA handler and the existing firewall. Android chooses Wi-Fi or mobile data. No extra switching service is needed. [Transport details and verification](DIRECT-TRANSPORT.md).

## 1. Requirements

- Rooted Android with working `su -c`.
- Termux and the separate **Termux:Boot Android app**.

Install both APKs from the same signing source: F-Droid or official GitHub releases. Mixed signatures prevent installation. [Termux installation requirements](https://github.com/termux/termux-app#installation).

### Install and activate Termux:Boot first

1. **Install Termux:Boot as an Android app** from the same signing source as Termux. You cannot install it with `pkg`.
2. **Open Termux:Boot once through its launcher icon** to enable startup at boot. Opening Termux does not activate Termux:Boot.

The steps below create one `10-services.sh` boot script and enable the service. `run` applies the firewall before each daemon start. Once setup is complete, you do not need to open Termux after every reboot. [Official Termux:Boot instructions](https://github.com/termux/termux-boot#how-to-use).

Android 12+ can kill the Termux supervisor while root Yggdrasil keeps running. When login or boot restores supervision, v3 safely takes over the surviving session. Optional phantom-process settings affect all apps. With the default settings, a failed daemon cannot restart while its supervisor is absent. Read [background restrictions](docs/INSTALL.md#31-optional-android-child-process-restrictions).

The boot script holds a wake lock, which costs battery power. [Power policy](docs/INSTALL.md#124-wake-lock-and-battery-cost).

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

Run package and build commands as the normal Termux user. The packages provide:

- `bash`, `coreutils` and `termux-tools`: the shell, file utilities and wake lock.
- `git`/`golang`: tools to build the binaries.
- `termux-services`/`iproute2`/`procps`: supervision and networking tools.
- `nano`: the editor.
- `curl`, `openssh` and `tcpdump`: tools for the full guide's verification steps.

Root comes from `su`. You do not need `sudo` or `tsu`.

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

Use fresh source and apply the patch once:

- `git apply --check` checks whether the patch fits.
- `git apply` changes the source.
- `./build` builds both binaries for installation below.

`PKGVER` labels the build. `-p` enables PIE. `-l` passes a linker option. The source changes mark TCP and QUIC/UDP sockets to bypass the VPN. [Command explanations and patch internals](docs/INSTALL.md#5-build-yggdrasil-natively-for-android).

For an existing node, keep its key and configuration. Follow [the update procedure](docs/INSTALL.md#19-updating-yggdrasil).

## 4. Create the configuration

Generate a configuration only for a new node. When reinstalling, first back up the installed binaries, configuration and service/boot scripts. Copy `$PREFIX/etc/yggdrasil.conf` to `~/yggdrasil.conf` with mode 600 (`install -m 600 "$PREFIX/etc/yggdrasil.conf" "$HOME/yggdrasil.conf"`). This keeps the existing identity. Use fresh clone directories for a rebuild.

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

Use ordinary `Peers` without fixed interface names. IPv4 addresses avoid peer DNS lookups through the VPN. The patch covers all outgoing peer schemes in v0.5.14: TCP, TLS, WS, WSS, SOCKS, SOCKS+TLS and QUIC. UNIX sockets are local. For SOCKS, the marked socket connects to the proxy. The proxy controls the route from there. [Coverage](docs/INSTALL.md#104-direct-peer-transport).

Multicast advertises and discovers local Yggdrasil nodes on Wi-Fi (`wlanN`). It uses IPv6 link-local UDP port 9001, then creates TLS/TCP peer connections. `Port: 0` chooses the local TCP port automatically. Keep the regular `Listen: []`. A direct local peer connection lets a compatible OpenWrt status module show the phone's `node` address.

The Wi-Fi regex limits discovery only. Public peers still work over Wi-Fi or mobile data. No extra service or firewall rule is needed. To disable discovery, use `MulticastInterfaces: []`. [Details](docs/INSTALL.md#wi-fi-multicast-discovery).

Set:

```text
IfName: ygg0
```

If `AdminListen` is missing, add it as a top-level field inside the outer `{ ... }` configuration object:

```text
AdminListen: unix:///data/data/com.termux/files/usr/tmp/yggdrasil.sock
```

## 5. Install binaries and configuration

For an existing installation, first read [the service-profile migration procedure](docs/INSTALL.md#95-upgrading-an-existing-service-profile). Stop the service before replacing its files:

```sh
sv -w 25 down yggdrasil
```

If the stop command fails, do not replace files. Keep the service stopped until you have installed its scripts and logger. Enable it at the step below. `run` applies the firewall before starting the daemon.

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

The v3 `run` has 276 lines in five sections: previous session, routing/firewall, daemon, helper ULAs and network events. Copy the whole block below.

Create `run`:

```sh
nano "$PREFIX/var/service/yggdrasil/run"
```

```sh
#!/data/data/com.termux/files/usr/bin/sh
# Yggdrasil uses ygg0; Android VpnService uses tunN.
# One persistent root Bash session does everything, in this order:
#   1. take over from a previous session left without its supervisor;
#   2. route 200::/7 through table 200 and firewall inbound ygg0 traffic;
#   3. run Yggdrasil and wait for its node address;
#   4. keep helper ULAs so Android WebRTC gathers IPv6 call candidates
#      on IPv4-only networks, driven by Netlink events without timers.
# Merge stderr into stdout for runit service output.
exec 2>&1

# Run the following Bash block in one persistent root session.
# Keep the outer shell waitable by runit; finish stops Yggdrasil.
su -c 'exec /data/data/com.termux/files/usr/bin/bash -s' <<'YGG_ROOT' &
P=/data/data/com.termux/files/usr
children=()

# Stop and reap all owned child processes when the root session exits.
cleanup() {
    trap - EXIT
    ((${#children[@]})) && kill "${children[@]}" 2>/dev/null
    wait 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 0' TERM INT HUP

### 1. Previous session ##################################################

# A process start time tells a live session apart from a reused PID.
start_time() {
    local stat
    read -r stat 2>/dev/null < "/proc/$1/stat" || return 1
    stat=(${stat##*) })
    printf '%s\n' "${stat[19]}"
}

# Stop a root session left without its supervisor and wait for its cleanup.
state=$P/var/run/yggdrasil-root
if read -r old_pid old_start 2>/dev/null < "$state" &&
   [[ $old_pid != "$$" && $(start_time "$old_pid") == "$old_start" ]]; then
    kill "$old_pid" 2>/dev/null
    for ((attempt=0; attempt<100; attempt++)); do
        kill -0 "$old_pid" 2>/dev/null || break
        sleep 0.1
    done
    # Never touch networking while the previous session is still alive.
    [[ $(start_time "$old_pid") != "$old_start" ]] ||
        { echo 'ERROR: Previous root session is still running'; exit 1; }
fi
printf '%s %s\n' "$$" "$(start_time "$$")" > "$state" || exit 1

### 2. Routing and firewall ##############################################

# Send all traffic destined for the Yggdrasil 200::/7 network to routing table 200.
# Remove duplicate copies first so exactly one rule remains.
while ip -6 rule del to 200::/7 lookup 200 prio 1000 2>/dev/null; do :; done
ip -6 rule add to 200::/7 lookup 200 prio 1000 || exit 1

# Allow replies to connections initiated by the phone and related traffic.
ip6tables -w -C INPUT -i ygg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null ||
    ip6tables -w -A INPUT -i ygg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || exit 1
# Drop packets that conntrack cannot classify as a valid connection state.
ip6tables -w -C INPUT -i ygg0 -m conntrack --ctstate INVALID -j DROP 2>/dev/null ||
    ip6tables -w -A INPUT -i ygg0 -m conntrack --ctstate INVALID -j DROP || exit 1
# Drop all other inbound traffic arriving through the Yggdrasil interface.
ip6tables -w -C INPUT -i ygg0 -j DROP 2>/dev/null ||
    ip6tables -w -A INPUT -i ygg0 -j DROP || exit 1

### 3. Yggdrasil #########################################################

# Remove a stale ygg0 interface left by an unclean previous shutdown.
ip link del ygg0 2>/dev/null || true

# Prepare the standard /dev/net/tun path for the TUN interface.
mkdir -p /dev/net && { [[ -e /dev/net/tun ]] || ln -s /dev/tun /dev/net/tun; } || exit 1

# Start Yggdrasil with root privileges.
$P/bin/yggdrasil -useconffile $P/etc/yggdrasil.conf &
ygg_pid=$!
children+=("$ygg_pid")

# Wait up to 30 seconds for ygg0 and the node address on it.
node=
for ((attempt=0; attempt<30; attempt++)); do
    while read -r index dev family address rest; do
        [[ $family == inet6 && $address == [23]??:*/7 ]] || continue
        node=${address%/7}
        break
    done < <(ip -6 -o addr show dev ygg0 scope global 2>/dev/null)
    [[ -n $node ]] && break
    kill -0 "$ygg_pid" 2>/dev/null || exit 1
    sleep 1
done
[[ -n $node ]] || { echo 'ERROR: ygg0 did not get its node address'; exit 1; }

# Once ygg0 exists, route the Yggdrasil network through it in table 200.
ip -6 route replace 200::/7 dev ygg0 metric 128 table 200 || exit 1

### 4. Helper ULAs for WebRTC ############################################

# These addresses are not public IPv6 connectivity or Yggdrasil identities.
# Both keep the node's low 112 bits, so they never collide between phones.
# The VPN and the physical uplink need different addresses: Android WebRTC
# gathers no IPv6 candidates at all when one address is on two networks.
ula_physical=fd42:${node#*:}/128
ula_vpn=fd43:${node#*:}/128
primary_dev=
# owned[dev]="ifindex original_disable_ipv6" for each address we added.
# changes[dev]="ifindex window_start count" limits additions per interface.
declare -A owned=() changes=()

# Succeed when the address list holds a global IPv6 address other than ours.
has_foreign_ipv6() {
    local index dev family address rest
    while read -r index dev family address rest; do
        [[ $family == inet6 && $address != "$2" ]] && return 0
    done <<< "$1"
    return 1
}

# Remove our address and restore the interface's original IPv6 switch.
release_ula() {
    local dev=$1 ula=$ula_physical index original current addresses
    [[ $dev == tun* ]] && ula=$ula_vpn
    [[ -n ${owned[$dev]:-} ]] || return 0
    read -r index original <<< "${owned[$dev]}"
    unset 'owned[$dev]'
    # A recreated interface no longer carries anything of ours.
    read -r current 2>/dev/null < "/sys/class/net/$dev/ifindex" || return 0
    [[ $current == "$index" ]] || return 0
    ip -6 addr del "$ula" dev "$dev" 2>/dev/null && echo "[ULA] Removed $ula from $dev"
    # Never disable IPv6 after the network acquires its own global address.
    if [[ $original == 1 ]] &&
       addresses=$(ip -6 -o addr show dev "$dev" scope global 2>/dev/null) &&
       ! has_foreign_ipv6 "$addresses" "$ula"; then
        printf '1\n' > "/proc/sys/net/ipv6/conf/$dev/disable_ipv6"
    fi
}

release_all() {
    local dev
    for dev in "${!owned[@]}"; do release_ula "$dev"; done
}

# Bring one interface in line with the policy: it carries our address only
# while it is a real TUN VPN or the primary physical uplink, is UP, has a
# global IPv4 address and has no global IPv6 address of its own.
sync_ula() {
    local dev=$1 ula=$ula_physical index flags tun_flags ipv4 addresses
    local disabled window_index window count
    [[ $dev =~ ^(tun|rmnet_data|wlan)[0-9]+$ ]] || return 0
    if [[ $dev == tun* ]]; then
        ula=$ula_vpn
        # Skip TAP devices: a real TUN has bit 0 set in tun_flags.
        read -r tun_flags 2>/dev/null < "/sys/class/net/$dev/tun_flags" || return 0
        ((tun_flags & 1)) || return 0
    elif [[ $dev != "$primary_dev" ]]; then
        release_ula "$dev"; return 0
    fi
    { read -r index < "/sys/class/net/$dev/ifindex" &&
      read -r flags < "/sys/class/net/$dev/flags"; } 2>/dev/null || { release_ula "$dev"; return 0; }
    # The kernel removed our address together with a recreated interface.
    [[ ${owned[$dev]%% *} == "$index" ]] || unset 'owned[$dev]'
    # A link going down releases the address and allows fresh attempts later.
    if ((!(flags & 1))); then unset 'changes[$dev]'; release_ula "$dev"; return 0; fi
    ipv4=$(ip -4 -o addr show dev "$dev" scope global 2>/dev/null) || ipv4=
    [[ -n $ipv4 ]] || { release_ula "$dev"; return 0; }
    addresses=$(ip -6 -o addr show dev "$dev" scope global 2>/dev/null) || return 0
    if has_foreign_ipv6 "$addresses" "$ula"; then release_ula "$dev"; return 0; fi
    # Leave the address unchanged when it is already present.
    [[ $addresses == *"inet6 $ula "* ]] && return 0

    read -r disabled < "/proc/sys/net/ipv6/conf/$dev/disable_ipv6" || return 0

    # Allow four additions per interface in ten seconds, then wait for a later
    # network event. This stops reset loops and repeated failures without a timer.
    read -r window_index window count <<< "${changes[$dev]:-}"
    if [[ $window_index != "$index" ]] || ((SECONDS - window >= 10)); then
        window=$SECONDS count=0
    fi
    ((count < 4)) || {
        ((count == 4)) && echo "[ULA] Too many changes on $dev; waiting for a later network event"
        changes[$dev]="$index $window 5"; return 0
    }
    changes[$dev]="$index $window $((count + 1))"

    # Remember the original IPv6 switch the first time we touch the interface.
    [[ -n ${owned[$dev]:-} ]] || owned[$dev]="$index $disabled"
    # The address is unique to this node and network type, so skip duplicate detection.
    if { [[ $disabled == 0 ]] || printf '0\n' > "/proc/sys/net/ipv6/conf/$dev/disable_ipv6"; } &&
       ip -6 addr replace "$ula" dev "$dev" nodad; then
        echo "[ULA] Added $ula to $dev"
    else
        echo "[ULA] Setup failed on $dev"
        release_ula "$dev"
    fi
}

# Find the primary physical uplink with the kernel route lookup used by
# protected peer sockets (fwmark 0x20000). No packet is sent and no DNS is used.
refresh_primary() {
    local route previous=$primary_dev
    route=$(ip -4 route get 1.1.1.1 mark 0x20000 2>/dev/null) || route=
    primary_dev=
    [[ $route =~ [[:space:]]dev[[:space:]]([^[:space:]]+) ]] && primary_dev=${BASH_REMATCH[1]}
    [[ $primary_dev != "$previous" ]] || return 0
    echo "[ULA] Primary uplink: ${primary_dev:-none}"
    [[ -z $previous ]] || sync_ula "$previous"
    [[ -z $primary_dev ]] || sync_ula "$primary_dev"
}

### 5. Network events ####################################################

# Subscribe before taking the initial snapshot so no change is missed.
coproc NET_EVENTS { exec ip -o monitor label link address route rule; }
monitor_pid=$NET_EVENTS_PID
children+=("$monitor_pid")
# Duplicate the event stream so the background worker can read it.
exec 3<&"${NET_EVENTS[0]}"

# Wait up to five seconds until the monitor's own Netlink socket has subscribed.
subscribed=0
for ((attempt=0; attempt<100; attempt++)); do
    sockets=$(ls -l "/proc/$monitor_pid/fd" 2>/dev/null)
    while read -r socket protocol port groups rmem wmem dump locks drops inode rest; do
        if [[ $protocol == 0 && $groups != 00000000 && $sockets == *"socket:[$inode]"* ]]; then
            subscribed=1; break
        fi
    done < /proc/net/netlink
    ((subscribed)) && break
    kill -0 "$monitor_pid" 2>/dev/null || break
    sleep 0.05
done
((subscribed)) || { echo 'ERROR: Netlink subscription failed'; exit 1; }

# Check existing interfaces once, then handle events without a timer.
(
    trap release_all EXIT
    trap 'exit 0' TERM INT HUP
    refresh_primary
    for path in /sys/class/net/{tun,rmnet_data,wlan}[0-9]*; do sync_ula "${path##*/}"; done
    declare -A pending=()
    while IFS= read -r event <&3; do
        # Collect events that are already queued and handle the batch once:
        # link and address events name an interface, route and rule events
        # may change the primary uplink.
        refresh=0
        while :; do
            case $event in
                '[LINK]'*|'[ADDR]'*)
                    event=${event#\[*\]}
                    read -r index dev rest <<< "${event#Deleted }"
                    dev=${dev%:}; dev=${dev%%@*}
                    [[ $index =~ ^[0-9]+:$ && -n $dev ]] && pending[$dev]=1
                    ;;
                *) refresh=1 ;;
            esac
            read -t 0 -u 3 || break
            IFS= read -r event <&3 || break
        done
        ((refresh)) && refresh_primary
        for dev in "${!pending[@]}"; do sync_ula "$dev"; done
        pending=()
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

The VPN helper is `fd43:<node low 112 bits>/128`. The primary physical helper is `fd42:<same bits>/128`. Both come from the key and must differ. In controlled A/B calls, one identical address on both networks produced zero IPv6 candidates and ICE FAILED. Calls with different addresses connected. The internal mechanism remains a hypothesis.

The handler uses only:

- UP real TUNs named `tunN`.
- The primary physical `rmnet_dataN`/`wlanN` selected with the socket mark.

Each interface must have global-scope IPv4 and no other global-scope IPv6. The handler preserves existing IPv6. It removes its own helper when the network gains global IPv6. Primary-uplink selection excludes IMS/hotspot interfaces; the handler does not detect their role.

After starting the service and connecting the VPN, identify the actual interfaces:

```sh
su -c 'ip -br addr'
su -c 'ip -4 route get 1.1.1.1 mark 0x20000'
su -c 'ip -6 -o addr show dev tun0 scope global'
```

The route lookup sends no packet. Replace `tun0` with the actual VPN name. Also inspect the physical `dev` returned by the lookup. The helper enables local compatibility, not general IPv6 Internet access. Yggdrasil destinations still use rule `1000` and `ygg0`.

The handler groups Netlink events into batches. It checks each named interface once and refreshes the primary uplink at most once per route/rule batch. It allows four additions per interface in ten seconds, including failures, to limit reset loops. There is no periodic timer.

The root session records its PID/start time. It waits up to ten seconds for the previous session to clean up before changing networking. Use runit. Do not launch simultaneous copies of `run`.

v3 passed mobile/Amnezia calls, Wi-Fi with native IPv6, and calls after mobile ↔ Wi-Fi transitions. Reboot, `sv restart` and orphan takeover passed on v2 with the same boot/firewall/takeover logic. See the [full matrix and limits](docs/INSTALL.md#evidence-and-limits). Continuous mid-call handover is not established. The reboot test status is in section 11.

### 6.2 Service logs

Create the logger and its output directory before enabling the service:

```sh
mkdir -p "$PREFIX/var/service/yggdrasil/log" "$PREFIX/var/log/sv/yggdrasil" "$PREFIX/var/run"
chmod 700 "$PREFIX/var/log/sv/yggdrasil"
nano "$PREFIX/var/service/yggdrasil/log/run"
```

Contents of `log/run`, the standard Termux services logger. `termux-services` supplies `LOGDIR`:

```sh
#!/data/data/com.termux/files/usr/bin/sh
# Get the name of the service from the PWD, this assumes the name of the
# service is one level above the log directory.
pwd=${PWD%/*} # $SVDIR/service/foo/log
service=${pwd##*/} # foo

mkdir -p "$LOGDIR/sv/$service"

exec svlogd -tt "$LOGDIR/sv/$service"
```

Create `$PREFIX/var/log/sv/yggdrasil/config`:

```sh
nano "$PREFIX/var/log/sv/yggdrasil/config"
```

Contents:

```text
s262144
n4
```

Make the logger executable:

```sh
chmod +x "$PREFIX/var/service/yggdrasil/log/run"
```

`s262144` rotates logs at 262,144 bytes (256 KiB). `n4` keeps four rotated files **plus** `current`. Normal log data totals about 1.25 MiB. These settings control rotation, not a strict disk quota. See the [svlogd manual](https://smarden.org/runit/svlogd.8).

One timestamped log receives Yggdrasil stdout/stderr and these helper messages: `[ULA] Primary uplink`, `Added`, `Removed`, `Setup failed` and `Too many changes`:

```sh
tail -n 100 "$PREFIX/var/log/sv/yggdrasil/current"
tail -F "$PREFIX/var/log/sv/yggdrasil/current"
```

Stop following with Ctrl-C. Logs contain network/node addresses. Redact them before sharing. An old `current` file does not prove the logger is running. Check `sv status "$PREFIX/var/service/yggdrasil/log"` and fresh timestamps.

## 7. Configure the firewall

The complete `run` above applies three stateful INPUT rules before starting Yggdrasil. It uses `-w -C || -w -A` to allow ESTABLISHED/RELATED, drop INVALID and drop other inbound `ygg0` traffic. No separate firewall boot script is needed. On upgrade, you may remove `~/.termux/boot/05-ygg-firewall.sh`. Leaving the old script is harmless because it does not duplicate these rules.

After service startup, inspect `su -c '/system/bin/ip6tables -S INPUT'`. Check the full rule order. Never flush Android's tables. [Firewall checks and untested AFWall+ custom-script integration](docs/INSTALL.md#11-firewall).

## 8. Configure Termux:Boot

```sh
mkdir -p "$HOME/.termux/boot"
```

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

This is the only required boot script. It holds a Termux wake lock and starts runit. Opening Termux can also start the supervisor. v3 applies the firewall on that path too. [Login and boot behavior](docs/INSTALL.md#123-manual-execution-and-shell-startup).

## 9. Start and enable Yggdrasil

Start the supervisor with the same wake-lock policy as boot:

```sh
"$HOME/.termux/boot/10-services.sh"
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

This waits at most fifteen seconds during installation. It enables the service only after `runit` has found it. It adds no background polling loop.

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

Termux:Boot runs `10-services.sh`. Runit starts Yggdrasil, and `run` applies the firewall first.

To prove boot startup, compare supervisor/daemon start times with the **first login shell**. Do this immediately after reboot, before manually starting services. Login can start runit, so finding a running service after opening Termux is not enough. Use the [read-only comparison command and checklist](docs/INSTALL.md#16-verify-everything-after-reboot).

In the recorded v2 reboot, the supervisor and daemon started at uptime ~23 s. The first login started at ~104 s. v3 uses the same boot/firewall logic, but **v3 itself has not passed a reboot test**. Earlier `direct.3` QUIC reboot results used an older service profile. [Current matrix](docs/INSTALL.md#evidence-and-limits).

## 12. Updating Yggdrasil

Follow [installation guide section 19](docs/INSTALL.md#19-updating-yggdrasil):

1. Select a release and build both Android/cgo binaries in a fresh directory.
2. Back up the old binaries and config.
3. Validate the existing config and node address.
4. Stop only Yggdrasil, install both binaries and restart it.

Keep the private key, peers, multicast, service/boot scripts and firewall. Do not regenerate the config. The section includes checks and rollback commands.

Keep the outgoing TCP-based and QUIC/UDP socket patch. It was tested on v0.5.14. Check and adapt it for a new release before building. A patch that applies cleanly or a version suffix does not prove VPN bypass. Verify physical peer sockets and traffic with the VPN active. An unpatched binary removes bypass.
