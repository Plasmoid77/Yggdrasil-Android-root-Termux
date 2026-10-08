# Yggdrasil on rooted Android via Termux — Quick Setup

> **Tested with Yggdrasil v0.5.14 on LineageOS 23 (Android 16).**
>
> **Guide by Plasmoid (Neuroslopped)**

Minimal installation procedure without explanations or verification steps.

This branch includes direct TCP peer transport outside an Android VPN, the event-driven ULA handler and the existing firewall. Android chooses Wi-Fi or mobile data without an extra switching service. [Transport details and verification](DIRECT-TRANSPORT.md).

## 1. Requirements

- Rooted Android with working `su -c`.
- `Termux` and `Termux:Boot`; launch `Termux:Boot` at least once from the Android launcher.

Use the same signing source for both APKs (F-Droid or official GitHub releases); mixed signatures prevent installation. [Termux installation requirements](https://github.com/termux/termux-app#installation).

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
git clone --depth 1 --branch direct-vpn-bypass https://github.com/Plasmoid77/Yggdrasil-Android-root-Termux.git yggdrasil-android-guide
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
PKGVER=0.5.14-direct.2 ./build -p -l "-checklinkname=0"
```

## 4. Create the configuration

The generation command below is for a new node. When reinstalling, back up the installed binaries, configuration and service/boot scripts, then copy `$PREFIX/etc/yggdrasil.conf` to `~/yggdrasil.conf` with mode600 instead of generating a new identity. Use fresh clone directories for a rebuild.

```sh
./yggdrasil -genconf > ~/yggdrasil.conf
```

```sh
nano ~/yggdrasil.conf
```

Add **2–3 current TCP IPv4 peers** from:

https://github.com/yggdrasil-network/public-peers

Tested example (check current peer availability):

```text
Peers: [
  tcp://87.249.44.53:18226
  tcp://217.144.163.22:7991
]
InterfacePeers: {}
Listen: []
MulticastInterfaces: []
```

Use ordinary `Peers` without pinned interface names. IPv4 literals avoid peer DNS through the VPN. QUIC is not covered by this patch.

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
coproc NET_EVENTS { exec ip -o monitor link address; }
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
ula=fd42::1/128
ensure_ula() {
    local dev=$1 tun_flags link_flags addresses
    [[ $dev =~ ^tun[0-9]+$ ]] || return 0
    { read -r tun_flags < "/sys/class/net/$dev/tun_flags" &&
      read -r link_flags < "/sys/class/net/$dev/flags"; } 2>/dev/null || return 0
    # Require TUN and UP; skip TAP and interfaces that are down.
    (( (tun_flags & 1) && (link_flags & 1) )) || return 0
    addresses=$(ip -6 -o addr show dev "$dev" 2>/dev/null) || return 0
    # Leave the address unchanged when it is already present.
    [[ $addresses == *"inet6 $ula "* ]] && return 0
    ip -6 addr replace "$ula" dev "$dev" && echo "[VPN-ULA] Added $ula to $dev"
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
    ip link show ygg0 >/dev/null 2>&1 && break
    kill -0 "$ygg_pid" 2>/dev/null || exit 1
    sleep 1
done
# Once ygg0 exists, route the Yggdrasil network through it in table 200.
ip -6 route replace 200::/7 dev ygg0 metric 128 table 200 || exit 1

# Check existing interfaces once, then handle events without a timer.
(
    trap - EXIT TERM INT HUP
    for path in /sys/class/net/tun[0-9]*; do ensure_ula "${path##*/}"; done
    while IFS= read -r event <&3; do
        # Extract the interface name, including from address deletion events.
        read -r index dev rest <<< "${event#Deleted }"
        [[ $index =~ ^[0-9]+:$ ]] || continue
        dev=${dev%:}; dev=${dev%%@*}
        ensure_ula "$dev"
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

### 6.1 VPN compatibility

The `run` above automatically maintains `fd42::1/128` on UP TUN interfaces named `tunN`. It listens for kernel link/address events and restores the address when a VPN recreates its interface. No separate installer or polling service is required.

After connecting a VPN, find its interface:

```sh
su -c 'ip -br addr'
```

For a matching interface such as `tun0`, check:

```sh
su -c 'ip -6 -o addr show dev tun0'
```

The output should contain `fd42::1/128`. Reconnect the VPN and check its current interface again; the address should return automatically. When changing the `ula` setting, reconnect once to remove the old address.

The ULA is a local compatibility address, not general IPv6 Internet access. Yggdrasil destinations continue to use rule `1000` and `ygg0`.

New calls worked after switching both tested Amnezia VPNs. Enabling the tested IPv4-only VPN during an active call still left Conversations reconnecting; the script does not manage ICE recovery.

See [README section 10.3](README.md#103-android-vpn--webrtcvoip-compatibility) for the reproduced problem, implementation, test results and limits.

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

After reboot, follow [README section 16](README.md#16-verify-everything-after-reboot), including the patched version, physical peer socket marks and ULA checks. Reboot verification of this patched build is still pending.
