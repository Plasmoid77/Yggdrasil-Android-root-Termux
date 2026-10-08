# Yggdrasil on rooted Android via Termux - Full Guide

Native Yggdrasil node on rooted Android without the Android VPN API.

The goal of this guide is to run the regular Yggdrasil userspace router directly on Android, create a real `ygg0` TUN interface, route only the Yggdrasil address space through it, supervise the daemon with `runit`, restore the firewall and service supervisor after reboot with Termux:Boot, and keep Android's normal network stack untouched.

This branch integrates a small VPN compatibility handler into the existing runit `run`. It restores a fixed ULA address on Android VPN TUN interfaces when they change, allowing new Conversations/WebRTC calls in the tested IPv4-only VPN case. See [section 10.3](#103-android-vpn--webrtcvoip-compatibility) for the reason, implementation and verified limits.

This branch also builds Yggdrasil v0.5.14 with a small outgoing TCP socket patch. Peer transport stays outside the Android VPN, while Android chooses Wi-Fi or mobile data. Other applications keep their existing VPN policy. No extra switching service is needed. [Transport details and measured results](DIRECT-TRANSPORT.md).

> **Tested with Yggdrasil v0.5.14 on LineageOS 23 (Android 16).**
>
> **Guide by Plasmoid (Neuroslopped)**

This is a root-only setup. It does **not** use:

- the Android VPN API;
- the Yggdrasil Android GUI app;
- systemd;
- a userspace VPN wrapper.

The resulting setup behaves much closer to a normal Linux Yggdrasil installation, but integrates with Android and Termux.

---

## Contents

1. [What this setup provides](#1-what-this-setup-provides)
2. [Architecture](#2-architecture)
3. [Requirements](#3-requirements)
4. [Prepare Termux](#4-prepare-termux)
5. [Build Yggdrasil natively for Android](#5-build-yggdrasil-natively-for-android)
6. [Create the Yggdrasil configuration](#6-create-the-yggdrasil-configuration)
7. [Install binaries and configuration](#7-install-binaries-and-configuration)
8. [Final filesystem layout](#8-final-filesystem-layout)
9. [Create the runit service](#9-create-the-runit-service)
10. [Policy routing](#10-policy-routing)
    - [Android VPN + WebRTC/VoIP compatibility](#103-android-vpn--webrtcvoip-compatibility)
    - [Direct peer transport](#104-direct-peer-transport)
11. [Firewall](#11-firewall)
12. [Autostart with TermuxBoot](#12-autostart-with-termuxboot)
13. [First launch](#13-first-launch)
14. [Verify Yggdrasil and routing](#14-verify-yggdrasil-and-routing)
15. [Verify the firewall](#15-verify-the-firewall)
16. [Verify everything after reboot](#16-verify-everything-after-reboot)
17. [Service management](#17-service-management)
18. [Why the setup is designed this way](#18-why-the-setup-is-designed-this-way)
19. [Updating Yggdrasil](#19-updating-yggdrasil)
20. [Removing the setup](#20-removing-the-setup)
21. [Sources and acknowledgements](#21-sources-and-acknowledgements)

---

## 1. What this setup provides

After installation, Android gets a native Yggdrasil interface:

```text
ygg0
```

Yggdrasil's IPv6 range:

```text
200::/7
```

is routed through a dedicated policy-routing table:

```text
table 200
```

using one RPDB rule:

```text
priority 1000
to 200::/7 lookup 200
```

All normal Android traffic keeps using Android's normal routing tables.

Outgoing Yggdrasil TCP peer sockets carry Android's `protectedFromVpn` bit (`SO_MARK=0x20000`). Only those sockets bypass the VPN. Android selects the physical network; no Wi-Fi or mobile interface name is stored in the configuration.

The service also maintains `fd42::1/128` on UP TUN interfaces named `tunN`, using network events rather than a background polling timer. This addresses the tested WebRTC/VPN case described in section 10.3.

The Yggdrasil daemon is supervised by `runit`, so it can be controlled with:

```sh
sv status yggdrasil
sv up yggdrasil
sv down yggdrasil
```

and restarted automatically if the supervised service exits.

Incoming traffic from Yggdrasil is protected by a stateful IPv6 firewall:

```text
ESTABLISHED,RELATED -> ACCEPT
INVALID             -> DROP
everything else     -> DROP
```

The firewall rules are restored at Android boot with Termux:Boot.

---

## 2. Architecture

The final setup looks like this:

```text
Android boot
│
└── Termux:Boot
    │
    ├── 05-ygg-firewall.sh
    │   └── restores the IPv6 INPUT policy for ygg0
    │
    └── 10-services.sh
        ├── termux-wake-lock
        └── starts termux-services / runit
            │
            └── yggdrasil
                │
                ├── run
                │   ├── starts one persistent root Bash session
                │   ├── subscribes to link/address events
                │   ├── adds RPDB rule 1000
                │   ├── removes stale ygg0
                │   ├── prepares /dev/net/tun
                │   ├── starts Yggdrasil and waits for ygg0
                │   ├── installs 200::/7 in table 200
                │   ├── maintains ULA on matching VPN TUN interfaces
                │   └── supervises Yggdrasil, monitor and event worker
                │
                └── finish
                    ├── stops Yggdrasil
                    ├── removes ygg0
                    └── removes RPDB rule 1000
```

The important separation is:

```text
Termux:Boot = one-shot boot initialization
runit       = long-running service supervision
```

Termux:Boot does not replace `runit`. It only starts the supervisor after Android boots.

---

## 3. Requirements

You need:

- a rooted Android device with working non-interactive root through `su -c`;
- Termux, including its Bash shell;
- Termux:Boot, launched at least once from the Android launcher before the first reboot test.

Install Termux and Termux:Boot from the same signing source: F-Droid with F-Droid, or the official GitHub releases with GitHub. Mixing them can produce an "unknown error" because their shared Android UID requires matching APK signatures. See [Termux installation requirements](https://github.com/termux/termux-app#installation).

This guide assumes root is already configured and working.

---

## 4. Prepare Termux

Update package metadata:

```sh
pkg update
```

Enable the Termux root package repository, which provides `tcpdump` used by the verification steps later in this guide:

```sh
pkg install root-repo
```

Refresh package metadata after enabling the repository:

```sh
pkg update
```

Install the packages required for the setup itself:

```sh
pkg install bash coreutils termux-tools git golang termux-services iproute2 procps nano
```

They are used for:

- `bash` — the persistent root shell and event handler;
- `coreutils` — file installation and standard shell utilities;
- `termux-tools` — Termux commands, including `termux-wake-lock`;
- `git` — cloning the Yggdrasil source tree;
- `golang` — building Yggdrasil;
- `termux-services` — `runit` integration;
- `iproute2` — `ip` and policy routing;
- `procps` — `pgrep` and `pkill`;
- `nano` — editing the configuration and service files used in this guide.

There is no need to install `clang` separately: the Termux `golang` package already depends on it, and cgo uses it as the C compiler.

Some verification steps later in the guide use additional tools. They are not required for Yggdrasil itself. Install them if you want to reproduce those tests:

```sh
pkg install curl openssh tcpdump
```

They are used only for verification:

- `curl` — HTTP connectivity test over Yggdrasil;
- Android's system `ping` command — ICMP reachability test; no separate `iputils` package is required here;
- `openssh` — temporary inbound SSH target for the firewall test;
- `tcpdump` — observing packets on `ygg0` during the firewall test.

Run the commands above inside Termux as its normal user; the later `su -c` commands acquire root only for system networking operations. Android already supplies `su` (through your root solution) and `/system/bin/ip6tables`; `sudo` or `tsu` is not required by this guide.

Check the Go environment:

```sh
go env GOOS GOARCH CGO_ENABLED CC
```

On the tested arm64 device the important values were:

```text
android
arm64
1
```

The compiler name may vary with the Termux toolchain.

The important point is that this guide builds Yggdrasil as an **Android** binary with **cgo enabled**, not as a generic Linux/arm64 binary.

---

## 5. Build Yggdrasil natively for Android

This guide is pinned to the version that was fully tested:

```text
v0.5.14
```

Clone it:

First obtain this guide's patch:

```sh
cd ~
git clone --depth 1 --branch direct-vpn-bypass https://github.com/Plasmoid77/Yggdrasil-Android-root-Termux.git yggdrasil-android-guide
```

Then clone the pinned Yggdrasil release:

```sh
cd ~
```

```sh
git clone --depth 1 --branch v0.5.14 https://github.com/yggdrasil-network/yggdrasil-go.git
```

Enter the source tree:

```sh
cd ~/yggdrasil-go
```

Apply the patch and build:

```sh
git apply --check ~/yggdrasil-android-guide/patches/android-peer-vpn-bypass.patch
git apply ~/yggdrasil-android-guide/patches/android-peer-vpn-bypass.patch
PKGVER=0.5.14-direct.2 ./build -p -l "-checklinkname=0"
```

Use a fresh source checkout; do not apply the same patch twice. The resulting daemon version should be `0.5.14-direct.2`.

### Why `-checklinkname=0`?

With the tested Go toolchain, building Yggdrasil v0.5.14 without this linker option failed with an error similar to:

```text
invalid reference to net.zoneCache
```

The dependency involved uses `go:linkname`, whose checks were tightened in newer Go versions. The `-checklinkname=0` linker flag allows this version to build with the tested modern Go toolchain.

This is a version-specific build detail. When upgrading Yggdrasil later, re-check whether the flag is still required.

### 5.1 Verify the binaries

Check Yggdrasil:

```sh
./yggdrasil -version
```

Check build metadata:

```sh
go version -m ./yggdrasil | grep -E 'CGO_ENABLED|GOOS|GOARCH'
```

```sh
go version -m ./yggdrasilctl | grep -E 'CGO_ENABLED|GOOS|GOARCH'
```

For the tested build the relevant metadata was:

```text
CGO_ENABLED=1
GOOS=android
GOARCH=arm64
```

Do not continue if you accidentally built `GOOS=linux` when following this guide.

---

## 6. Create the Yggdrasil configuration

For a new node, generate a fresh configuration. To reinstall an existing node, first back up its binaries, configuration and service/boot scripts, then copy its existing configuration instead of generating a new identity:

```sh
cp -p "$PREFIX/etc/yggdrasil.conf" ~/yggdrasil.conf
chmod 600 ~/yggdrasil.conf
```

For a new node only:

```sh
cd ~/yggdrasil-go
```

```sh
./yggdrasil -genconf > ~/yggdrasil.conf
```

Edit it:

```sh
nano ~/yggdrasil.conf
```

Three parts matter for this setup.

### 6.1 Peers

Yggdrasil does not connect to arbitrary Internet peers automatically. Add public peers to:

```text
Peers: [
]
```

Current public peers are published here:

https://github.com/yggdrasil-network/public-peers

For normal usage, the official public-peers repository recommends **2 or 3 peers**. Prefer peers that are geographically close to you to keep latency down. Using a small set of stable peers also gives redundancy without creating unnecessary distant peerings.

For this branch's tested direct transport, use TCP IPv4 literals in ordinary `Peers`. The following addresses were used for the tests; check current availability before choosing them:

```text
Peers: [
  tcp://87.249.44.53:18226
  tcp://217.144.163.22:7991
]
InterfacePeers: {}
Listen: []
MulticastInterfaces: []
```

Peer availability changes over time. Choose current nearby TCP IPv4 peers from the public-peers repository. IPv4 literals avoid peer DNS lookups through the VPN. QUIC is outside this patch's scope; do not assume it bypasses the VPN. Interface names are not pinned, and Android selects the physical network.

### 6.2 Fix the interface name

Find:

```text
IfName:
```

and set:

```text
IfName: ygg0
```

A deterministic interface name is important because the routing and firewall rules in this guide explicitly match `ygg0`.

### 6.3 Use a UNIX admin socket

Set:

```text
AdminListen: unix:///data/data/com.termux/files/usr/tmp/yggdrasil.sock
```

`AdminListen` may be absent from the generated configuration. If you do not see it, add it manually as a **top-level field inside the outer `{ ... }` configuration object**, for example before the final closing brace:

```text
{
  ...
  AdminListen: unix:///data/data/com.termux/files/usr/tmp/yggdrasil.sock
}
```

This keeps the control API off a TCP listener.

Because Yggdrasil will run as root, the resulting UNIX socket will normally also be root-owned. `yggdrasilctl` therefore needs root in this setup.

### 6.4 Check the generated Yggdrasil address

Run:

```sh
~/yggdrasil-go/yggdrasil -address -useconffile ~/yggdrasil.conf
```

It should return an address from Yggdrasil's `200::/7` range.

The configuration contains the node's cryptographic identity. Keep this file if you want to keep the same Yggdrasil address.

### 6.5 Validate the configuration

Run:

```sh
~/yggdrasil-go/yggdrasil -useconffile ~/yggdrasil.conf -normaliseconf >/dev/null && echo CONFIG_OK
```

Expected:

```text
CONFIG_OK
```

This command is used here as a parser/compatibility check. It does not overwrite the configuration.

---

## 7. Install binaries and configuration

When reinstalling an existing service, stop it before replacing its files:

```sh
sv -w 25 down yggdrasil
```

Keep it stopped while creating the service scripts below. Apply the firewall before enabling the service in section 13.

Install the daemon:

```sh
install -m 755 ~/yggdrasil-go/yggdrasil "$PREFIX/bin/yggdrasil"
```

Install the control utility:

```sh
install -m 755 ~/yggdrasil-go/yggdrasilctl "$PREFIX/bin/yggdrasilctl"
```

Install the configuration:

```sh
install -m 600 ~/yggdrasil.conf "$PREFIX/etc/yggdrasil.conf"
```

The source tree is no longer required for normal operation. You may keep it for future builds or remove it later.

---

## 8. Final filesystem layout

The core Yggdrasil files will be:

```text
$PREFIX/bin/
├── yggdrasil
└── yggdrasilctl

$PREFIX/etc/
└── yggdrasil.conf

$PREFIX/var/service/yggdrasil/
├── run
└── finish
```

Boot integration will add:

```text
~/.termux/boot/
├── 05-ygg-firewall.sh
└── 10-services.sh
```


---

## 9. Create the runit service

Create the service directory:

```sh
mkdir -p "$PREFIX/var/service/yggdrasil"
```

Prevent an already-running `runsvdir` from starting the service before both scripts are ready:

```sh
touch "$PREFIX/var/service/yggdrasil/down"
```

### 9.1 `run`

Create:

```sh
nano "$PREFIX/var/service/yggdrasil/run"
```

Contents:

The following complete `run` includes the event-driven ULA handler described in section 10.3. The original startup comments are retained; new comments explain the root session and event handling. Copy the whole script, including the final `YGG_ROOT` line and `wait` command.

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

### 9.2 `finish`

Create:

```sh
nano "$PREFIX/var/service/yggdrasil/finish"
```

Contents:

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

The `[y]ggdrasil` expression is intentional. It prevents `pkill -f` from matching the shell command that is executing `pkill` itself.

Make both scripts executable:

```sh
chmod +x "$PREFIX/var/service/yggdrasil/run" "$PREFIX/var/service/yggdrasil/finish"
```

Do not enable the service yet. Configure the firewall first so the node is not briefly exposed when `ygg0` appears.

---

## 10. Policy routing

Yggdrasil uses:

```text
200::/7
```

for its IPv6 address space.

We do not want to replace Android's default IPv6 route. We only want traffic whose **destination** is inside Yggdrasil to use the Yggdrasil interface.

The service therefore creates:

```text
1000: from all to 200::/7 lookup 200
```

and table `200` contains:

```text
200::/7 dev ygg0 metric 128
```

Conceptually:

```text
destination is 200::/7?
│
├── no  -> continue through Android's normal policy routing
│
└── yes -> lookup table 200
           └── 200::/7 -> ygg0
```

### 10.1 Why priority 1000?

Android has its own policy-routing rules. A low numeric priority causes the Yggdrasil destination rule to be evaluated early without replacing Android's normal routing setup.

The guide does **not** flush or rewrite Android's RPDB.

### 10.2 Why there is no priority 999 source rule

Some Android/Yggdrasil guides use two rules:

```text
from YGG_IP lookup 200 priority 999
to 200::/7 lookup 200 priority 1000
```

This guide intentionally uses **only**:

```text
to 200::/7 lookup 200 priority 1000
```

On the tested setup, the source rule was proven unnecessary.

With only rule `1000`, a route lookup returned:

```text
dev ygg0
table 200
src <YGG_IP>
```

Outbound TCP worked normally.

A separate inbound SSH test also confirmed that reply traffic from the phone's Yggdrasil address used the correct route without rule `999`.

So the final tested configuration is:

```text
1000: from all to 200::/7 lookup 200
```

with no `999` rule.

### 10.3 Android VPN + WebRTC/VoIP compatibility

This branch includes an event-driven VPN compatibility workaround in the `run` script from section 9.1. The base Yggdrasil routing scheme remains the same.

The reproduced problem was:

- Yggdrasil and ordinary XMPP traffic worked while an Android `VpnService` VPN was active;
- Conversations calls worked without the VPN or when Conversations was excluded from it;
- inside an IPv4-only VPN, WebRTC produced only the VPN IPv4 ICE candidate and no usable IPv6 path to Yggdrasil.

The original packet-capture tests used:

```text
LineageOS 23 / Android 16
Conversations 2.20.3+free
AmneziaVPN
Yggdrasil v0.5.14
```

Adding a ULA to the VPN interface allowed calls to establish. Adding it to `ygg0` or a separate dummy interface did not fix this case. The current script uses the short, fixed address:

```text
fd42::1/128
```

#### Why the Yggdrasil route alone is not enough

Rule `1000` can route a packet only after the application creates it. In the failing capture, WebRTC emitted no IPv6 STUN traffic toward Yggdrasil, so the correct `200::/7 -> ygg0` route had nothing to route.

WebRTC's Android network monitor obtains network addresses through Android's network APIs and `LinkProperties`. The failing VPN had usable IPv4 but only link-local IPv6 (`fe80::`). Adding a non-link-local IPv6 address to that VPN interface was the successful workaround.

The working explanation is that the additional address enables an IPv6 ICE socket/path that was unavailable before. The observed candidate and packet changes support this explanation; they do not establish every internal Android/WebRTC step or guarantee identical behaviour on another ROM.

In the earlier successful capture, STUN and direct bidirectional UDP media appeared on `ygg0`. The media used the real Yggdrasil addresses, not the synthetic ULA.

#### What the ULA does

`fd42::1/128` is a local compatibility address on the VPN interface. It is not the node's Yggdrasil identity, a public Internet address or an IPv6 address supplied by the VPN server. `/128` assigns one address rather than a subnet.

The script adds no default IPv6 route and does not change VPN server settings. Destination routing still follows:

| Destination | Route |
| --- | --- |
| `200::/7` | Rule `1000`, table `200`, `ygg0` |
| Other destinations | Existing Android/VPN routing policy |

On the tested device, rule `1000` is evaluated before Android's secure-VPN rules. Check this on another ROM:

```sh
su -c 'ip -6 rule show'
```

The ULA does not provide general IPv6 Internet access through an IPv4-only VPN. A dual-stack VPN keeps its existing IPv4 and IPv6 addresses alongside this additional address.

#### Why the address is maintained automatically

A VPN reconnect can destroy its TUN interface and create a new one. The new interface loses manually added addresses even if its name is still `tun0`; the name can also change to `tun1`.

The service therefore maintains the ULA for the lifetime of `run`. It subscribes to:

```sh
ip -o monitor link address
```

This listens for kernel Netlink events. After confirming the subscription, the service checks existing interfaces once, then waits for link or address changes. Subscribing first queues events that occur during startup.

For each event, the handler checks the current interface state:

1. Its name must match `tunN`, such as `tun0` or `tun1`.
2. Its `tun_flags` must identify a TUN interface, and its link flags must include `UP`.
3. If `fd42::1/128` is already present, no address command is run.
4. Otherwise, the handler adds that address with `ip -6 addr replace`.

Adding the address generates another event. The next check finds it already present and makes no change. Deleting the address on a live interface triggers restoration; deleting the interface itself is ignored until a suitable interface appears again.

This is a deliberately small detector for the tested Android `VpnService` interface convention. It matches UP TUN interfaces named `tunN`; it does not ask Android whether each matching interface is a registered VPN. Other root-created TUN interfaces with those names also match. Interfaces with other names are outside this workaround's scope.

The script uses the same check for IPv4-only and dual-stack VPNs, keeping one fixed ULA on each matching interface. It does not need a separate address-family policy.

#### Why one root session and one runit service

The complete service block runs inside one persistent Termux Bash process started by `su`. Address events do not create new root sessions or repeated Magisk permission notifications. A service restart or a manually invoked root command can still show a notification.

There is no five-second background polling loop and no recurring `dumpsys` call. The two bounded startup waits serve different purposes: up to five seconds to confirm the Netlink subscription, and up to thirty seconds for `ygg0` to appear.

The root shell owns three children: Yggdrasil, `ip monitor` and the event worker. `wait -n` detects the first child exit, and the cleanup trap stops and reaps the others. An enabled runit service can restart the complete group if one component fails.

The outer shell remains waiting for `su` instead of being replaced with it. This preserves the stop path through the existing `finish`, which stops Yggdrasil; its exit releases the root shell's wait and cleans up the monitor and worker.

Everything remains in the existing `run` file. No separate watchdog service, boot-time address loop or permanent installer is needed. The quoted `YGG_ROOT` here-document keeps its contents for the root Bash to interpret. Bash supplies the arrays, regular expressions, coprocess and `wait -n` used by the handler; the outer shell is still `sh`.

#### Verify the installed service

After installing the updated `run`, restart an existing service with:

```sh
sv restart yggdrasil
```

Connect a VPN and identify its interface:

```sh
su -c 'ip -br addr'
```

For a matching interface such as `tun0`, verify the ULA:

```sh
su -c 'ip -6 -o addr show dev tun0'
```

Expected address:

```text
fd42::1/128
```

Reconnect the VPN and repeat the check on the current interface. A recreated interface should acquire the same ULA without restarting Yggdrasil. If you change the `ula` setting, reconnect the VPN once to discard the previous address.

For a known Yggdrasil destination, check route selection:

```sh
su -c 'ip -6 route get <YGGDRASIL_IPV6>'
```

Expected properties:

```text
dev ygg0
table 200
src <YOUR_YGG_IP>
```

To inspect the media path during a call:

```sh
su -c 'tcpdump -ni ygg0 -tttt -vv udp'
```

Repeat the normal firewall and reboot verification in sections 15 and 16. A running service alone does not prove successful routing, call establishment or boot recovery.

#### Tested behaviour and remaining limitation

The event-driven service was tested with Amnezia Premium's IPv4-only VPN and a self-hosted Amnezia dual-stack VPN:

| Test | Observed result |
| --- | --- |
| Start a new call after connecting or disconnecting either VPN | Calls worked |
| Incoming calls with the updated service | Calls could be received and answered |
| Disconnect the IPv4-only VPN during an active call | Call survived a brief audio interruption |
| Enable the IPv4-only VPN during an active call | Conversations stayed in reconnecting state |
| Enable or disable the tested dual-stack VPN during an active call | Call survived a brief audio interruption |

Restoring an address does not restart ICE or migrate the application's existing sockets. The cause of the IPv4-only mid-call failure has not been established. The two VPN profiles also differ in server and configuration, so the comparison does not isolate address family as the only cause.

#### Boundaries to preserve when changing this code

- Keep the Yggdrasil destination rule and table `200`; the ULA is not a replacement route or source identity.
- Keep the subscription before the initial snapshot, and check current state before adding an address.
- Keep interface type/name filtering and the address-presence check; unrelated events and our own address events must not cause repeated writes.
- Keep root privilege acquisition outside the event loop.
- Keep Yggdrasil, monitor and worker tied to the same runit lifecycle, including cleanup on child exit.
- Keep the complete `run` examples in this README and QUICKSTART identical when editing either guide.
- Treat call recovery during a network switch as a separate application/ICE problem until packet captures and application logs establish its cause.

Implementation references are listed in section 21. These constraints document the reason for the code so later edits can be reviewed without the original debugging conversation.

### 10.4 Direct peer transport

The patch in section 5 sets `SO_MARK=0x20000` on outgoing TCP peer sockets on Android. Socket setup errors are returned instead of allowing an unprotected connection. Android's physical-network selection handles Wi-Fi and mobile data without a new supervisor, timer or interface selector. The existing runit scripts need no transport changes.

Verify the actual peer sockets with the VPN connected:

```sh
su -c "$PREFIX/bin/ss -tnep"
```

Yggdrasil peer sockets should have `fwmark:0x20000` and a physical-network source address. Applications that require the VPN should still use its address. A route lookup alone does not prove this socket path.

The ULA remains necessary for the tested Conversations/WebRTC context inside an IPv4-only VPN. Its purpose is separate from transporting Yggdrasil TCP peer connections outside the VPN. Calls use the real Yggdrasil address on `ygg0`, not the ULA. Any relay inside Yggdrasil is separate from the phone's Amnezia tunnel.

Wi-Fi → mobile → Wi-Fi transitions passed without restarting Yggdrasil. Calls were verified separately with Amnezia Premium XRay and AmneziaWG: bidirectional media used `ygg0`, peer TCP transport used physical Wi-Fi, and the other application's VPN connection remained available. A clean reinstall from this branch and a full Android reboot also passed: an early Termux:Boot snapshot confirmed automatic service startup, both physical-source marked peer sockets and the restored firewall. Post-reboot checks confirmed routing, overlay HTTP and automatic ULA restoration after the VPN connected. See [transport verification and limits](DIRECT-TRANSPORT.md).

---

## 11. Firewall

The public Yggdrasil network should be treated as an untrusted network.

Yggdrasil makes the host directly routable from other Yggdrasil nodes, including when the underlying Internet connection is behind NAT or CGNAT.

The official Yggdrasil FAQ recommends an IPv6 firewall for the Yggdrasil TUN interface. This guide uses the same stateful policy:

```text
ESTABLISHED,RELATED -> ACCEPT
INVALID             -> DROP
everything else     -> DROP
```

No `OUTPUT` rules are required.

No `FORWARD` rules are required for this host-only setup.

Do **not** flush Android's firewall tables.

Never use:

```sh
ip6tables -F
```

or:

```sh
iptables -F
```

as part of this guide.

Android owns additional firewall chains used by the OS, bandwidth accounting, networking and tethering.

### 11.1 Create the Termux:Boot firewall script

Create the boot directory:

```sh
mkdir -p "$HOME/.termux/boot"
```

Create:

```sh
nano "$HOME/.termux/boot/05-ygg-firewall.sh"
```

Contents:

```sh
#!/data/data/com.termux/files/usr/bin/sh

# Allow replies to connections initiated by the phone and related traffic.
su -c '/system/bin/ip6tables -C INPUT -i ygg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || /system/bin/ip6tables -A INPUT -i ygg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT'

# Drop packets that conntrack cannot classify as a valid connection state.
su -c '/system/bin/ip6tables -C INPUT -i ygg0 -m conntrack --ctstate INVALID -j DROP 2>/dev/null || /system/bin/ip6tables -A INPUT -i ygg0 -m conntrack --ctstate INVALID -j DROP'

# Drop all other inbound traffic arriving through the Yggdrasil interface.
su -c '/system/bin/ip6tables -C INPUT -i ygg0 -j DROP 2>/dev/null || /system/bin/ip6tables -A INPUT -i ygg0 -j DROP'
```

Make it executable:

```sh
chmod +x "$HOME/.termux/boot/05-ygg-firewall.sh"
```

### 11.2 Why `-C || -A`?

`ip6tables -A` does not deduplicate identical rules.

Running the same `-A` command several times can create duplicate rules.

The script therefore does:

```text
-C -> check whether the exact rule already exists

if it exists:
    do nothing

if it does not exist:
    -A -> append it
```

This makes the script idempotent.

There is no need to delete and re-add the rules on every invocation.

### 11.3 Why there is no `netd` wait loop

Termux:Boot runs after Android has reached its boot-completed stage, when `netd` and the normal Android firewall setup should already be initialized. A separate wait loop therefore adds unnecessary complexity for this setup.

Still verify the final `INPUT` rule order after boot, especially on a different Android ROM.

### 11.4 Apply the firewall now

Before starting Yggdrasil for the first time:

```sh
"$HOME/.termux/boot/05-ygg-firewall.sh"
```

Check:

```sh
su -c '/system/bin/ip6tables -S INPUT'
```

The final three rules should be equivalent to:

```text
-A INPUT -i ygg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A INPUT -i ygg0 -m conntrack --ctstate INVALID -j DROP
-A INPUT -i ygg0 -j DROP
```

`RELATED,ESTABLISHED` and `ESTABLISHED,RELATED` are equivalent state sets.

Run the firewall script twice more:

```sh
"$HOME/.termux/boot/05-ygg-firewall.sh"
```

```sh
"$HOME/.termux/boot/05-ygg-firewall.sh"
```

Then check again:

```sh
su -c '/system/bin/ip6tables -S INPUT'
```

There should still be exactly three Yggdrasil rules.

---

## 12. Autostart with Termux:Boot

Termux:Boot executes files inside:

```text
~/.termux/boot/
```

in sorted filename order.

We use:

```text
05-ygg-firewall.sh
10-services.sh
```

so the firewall is restored before the Yggdrasil service supervisor is started.

### 12.1 Create `10-services.sh`

Create:

```sh
nano "$HOME/.termux/boot/10-services.sh"
```

Contents:

```sh
#!/data/data/com.termux/files/usr/bin/sh

termux-wake-lock
. /data/data/com.termux/files/usr/etc/profile.d/start-services.sh
```

Make it executable:

```sh
chmod +x "$HOME/.termux/boot/10-services.sh"
```

Check:

```sh
ls -l "$HOME/.termux/boot/"
```

Expected structure:

```text
05-ygg-firewall.sh
10-services.sh
```

### 12.2 Why `10-services.sh` exists

`runit` does not start itself merely because service directories exist.

The directory:

```text
$PREFIX/var/service/yggdrasil/
```

only describes a service.

A `runsvdir` process must supervise that directory.

`termux-services` provides:

```text
$PREFIX/etc/profile.d/start-services.sh
```

which starts the Termux service daemon and `runsvdir`.

The chain is therefore:

```text
Termux:Boot
    │
    └── 10-services.sh
        │
        └── start-services.sh
            │
            └── runsvdir
                │
                └── runsv yggdrasil
```

Termux:Boot could directly execute the Yggdrasil daemon, but then there would be no persistent supervisor, no normal `sv up/down/status` lifecycle and no automatic service restart behavior.

Using both components is intentional:

```text
Termux:Boot -> boot trigger
runit       -> service supervisor
```

---

## 13. First launch

Start the Termux service supervisor in the current Android session:

```sh
. /data/data/com.termux/files/usr/etc/profile.d/start-services.sh
```

Allow the supervisor to notice a newly created or recreated service directory before enabling Yggdrasil:

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

This checks readiness immediately, waits at most fifteen seconds, and enables the service only after `sv status` can communicate with its supervisor. Merely finding an old `supervise/ok` file would not prove that `runsv` is running. The check avoids `unable to open supervise/ok` when commands are executed immediately after recreating the directory. It adds no runtime polling.

`sv-enable` removes the service's `down` file and requests that `runit` start it.

Check:

```sh
sv status yggdrasil
```

Expected:

```text
run: yggdrasil: (pid ...)
```

If you want to see whether `runsvdir` exists:

```sh
pgrep -af '[r]unsvdir'
```

---

## 14. Verify Yggdrasil and routing

Do not consider the setup complete merely because `sv status` says `run`.

Verify each layer.

### 14.1 Process

```sh
sv status yggdrasil
```

```sh
su -c 'pgrep -af "[y]ggdrasil -useconffile"'
```

A root Yggdrasil process should exist.

### 14.2 Interface

```sh
su -c 'ip -6 addr show dev ygg0'
```

You should see a global Yggdrasil address from `200::/7`.

### 14.3 RPDB rule

```sh
su -c 'ip -6 rule show' | grep '^1000:'
```

Expected:

```text
1000: from all to 200::/7 lookup 200
```

### 14.4 Table 200

```sh
su -c 'ip -6 route show table 200'
```

Expected:

```text
200::/7 dev ygg0 metric 128
```

### 14.5 Route selection and an Acetone ping test

Use the Acetone Yggdrasil address as an example route lookup:

```sh
su -c 'ip -6 route get 324:71e:281a:9ed3::ace'
```

Expected properties:

```text
dev ygg0
table 200
src <YOUR_YGG_IP>
```

Then test basic reachability:

```sh
ping -6 324:71e:281a:9ed3::ace
```

Stop `ping` with `Ctrl+C` after a few replies.

### 14.6 UNIX control socket

```sh
ls -l "$PREFIX/tmp/yggdrasil.sock"
```

The tested setup produces a root-owned socket similar to:

```text
srw-rw---- root root ... yggdrasil.sock
```

Query peers:

```sh
su -c "$PREFIX/bin/yggdrasilctl -endpoint=unix://$PREFIX/tmp/yggdrasil.sock getPeers"
```

At least one peer should be `Up`.

A peer that is temporarily `Down` does not necessarily indicate a local configuration problem. Public peers can disappear or change.

### 14.7 Real traffic

Use any known reachable Yggdrasil service.

During testing, this HTTP endpoint was used:

```text
http://[324:71e:281a:9ed3::ace]/
```

Example:

```sh
curl -6 --noproxy '*' --connect-timeout 10 -I 'http://[324:71e:281a:9ed3::ace]/'
```

At the time of testing it returned:

```text
HTTP/1.1 200 OK
```

If that service is no longer online, use another current Yggdrasil service instead.

---

## 15. Verify the firewall

The firewall should be tested in both directions.

### 15.1 Check initial counters

Run:

```sh
su -c '/system/bin/ip6tables -L INPUT -n -v --line-numbers'
```

Locate the final three `ygg0` rules.

Immediately after installation their counters may be zero.

### 15.2 Verify replies to outbound traffic

Generate outbound Yggdrasil traffic, for example:

```sh
curl -6 --noproxy '*' --connect-timeout 10 -I 'http://[324:71e:281a:9ed3::ace]/'
```

Then:

```sh
su -c '/system/bin/ip6tables -L INPUT -n -v --line-numbers'
```

The packet counter for:

```text
ESTABLISHED,RELATED -> ACCEPT
```

should increase.

This proves that replies to connections initiated by the phone are allowed.

### 15.3 Verify that new inbound connections are dropped

For this test you need another machine connected to Yggdrasil.

Temporarily start Termux SSH:

```sh
sv up sshd
```

Verify the listener:

```sh
su -c "ss -lntp | grep ':8022'"
```

Termux OpenSSH normally listens on port `8022`.

On the phone, monitor both directions:

```sh
su -c "tcpdump -n -tttt -vv -i ygg0 'tcp port 8022'"
```

From the other Yggdrasil node, try to connect:

```sh
ssh -o ConnectTimeout=5 -p 8022 <TERMUX_USER>@<PHONE_YGG_IP>
```

The expected client-side result is a timeout.

On the phone, `tcpdump` should show repeated incoming SYN packets:

```text
remote -> phone:8022  Flags [S]
remote -> phone:8022  Flags [S]
remote -> phone:8022  Flags [S]
```

but no SYN-ACK from the phone:

```text
phone:8022 -> remote  Flags [S.]
```

Then inspect counters:

```sh
su -c '/system/bin/ip6tables -L INPUT -n -v --line-numbers'
```

The final generic `DROP` rule for `ygg0` should have increased.

This combination proves all three points:

```text
SYN visible on ygg0          -> packet reached the phone
DROP counter increased       -> ip6tables dropped it
no SYN-ACK left the phone    -> the TCP service was not reached
```

Stop the test SSH service:

```sh
sv down sshd
```

---

## 16. Verify everything after reboot

This is the final persistence test.

Reboot Android normally.

After Android has fully booted, open Termux and **do not manually start the firewall or Yggdrasil**.

The point is to verify automatic recovery.

### 16.1 runit

```sh
pgrep -af '[r]unsvdir'
```

### 16.2 Yggdrasil service

```sh
sv status yggdrasil
```

Expected:

```text
run: yggdrasil: (pid ...)
```

### 16.3 Root Yggdrasil process

```sh
su -c 'pgrep -af "[y]ggdrasil -useconffile"'
```

### 16.4 `ygg0`

```sh
su -c 'ip -6 addr show dev ygg0'
```

### 16.5 RPDB

```sh
su -c 'ip -6 rule show' | grep '^1000:'
```

Expected:

```text
1000: from all to 200::/7 lookup 200
```

### 16.6 Table 200

```sh
su -c 'ip -6 route show table 200'
```

Expected:

```text
200::/7 dev ygg0 metric 128
```

### 16.7 Route selection

```sh
su -c 'ip -6 route get 324:71e:281a:9ed3::ace'
```

Expected properties:

```text
dev ygg0
table 200
src <YOUR_YGG_IP>
```

### 16.8 Firewall

```sh
su -c '/system/bin/ip6tables -S INPUT'
```

The three rules should exist automatically:

```text
-A INPUT -i ygg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A INPUT -i ygg0 -m conntrack --ctstate INVALID -j DROP
-A INPUT -i ygg0 -j DROP
```

System-managed Android rules may appear before them and can differ between ROMs.

### 16.9 Admin socket

```sh
ls -l "$PREFIX/tmp/yggdrasil.sock"
```

### 16.10 Peers

```sh
su -c "$PREFIX/bin/yggdrasilctl -endpoint=unix://$PREFIX/tmp/yggdrasil.sock getPeers"
```

### 16.11 Real Yggdrasil traffic

```sh
curl -6 --noproxy '*' --connect-timeout 10 -I 'http://[324:71e:281a:9ed3::ace]/'
```

### 16.12 Firewall state counter

```sh
su -c '/system/bin/ip6tables -L INPUT -n -v --line-numbers'
```

After a successful outbound request, the `ESTABLISHED,RELATED` counter should increase.

### 16.13 Direct transport and VPN compatibility

With your VPN connected after reboot:

```sh
yggdrasil -version
su -c "$PREFIX/bin/ss -tnep"
su -c 'ip -6 -o addr show dev tun0'
```

Check `0.5.14-direct.2`, physical-source peer sockets with `fwmark:0x20000`, and `fd42::1/128` on the current VPN TUN interface (replace `tun0` if needed). Also verify an application that requires the VPN still connects through it.

If all of the above succeeds without manually launching anything, the installation has survived a full Android reboot correctly.

---

## 17. Service management

### Status

```sh
sv status yggdrasil
```

### Show this node

```sh
su -c "$PREFIX/bin/yggdrasilctl -endpoint=unix://$PREFIX/tmp/yggdrasil.sock getSelf"
```

### Show peers

```sh
su -c "$PREFIX/bin/yggdrasilctl -endpoint=unix://$PREFIX/tmp/yggdrasil.sock getPeers"
```

### Stop

```sh
sv down yggdrasil
```

Expected cleanup:

```text
Yggdrasil process  -> stopped
monitor and worker -> stopped
ygg0               -> removed
rule 1000           -> removed
table 200 route     -> removed with ygg0
```

The firewall rules remain installed. They simply do not match while `ygg0` does not exist.

Stopping Yggdrasil does not remove an existing ULA from a separate VPN interface. The address disappears when that VPN interface is destroyed; automatic restoration runs again when the Yggdrasil service starts.

### Start

```sh
sv up yggdrasil
```

The service recreates:

```text
rule 1000
ygg0
table 200 route
link/address event monitor
ULA handler for existing and future matching TUN interfaces
```

### Restart

```sh
sv restart yggdrasil
```

### Apply changes after editing the peer list

Edit the installed configuration:

```sh
nano "$PREFIX/etc/yggdrasil.conf"
```

After changing `Peers`, restart the service so the file is read again:

```sh
sv restart yggdrasil
```

Then verify the active peerings:

```sh
su -c "$PREFIX/bin/yggdrasilctl -endpoint=unix://$PREFIX/tmp/yggdrasil.sock getPeers"
```

Current Yggdrasil versions do not reload the configuration with `SIGHUP`; use a service restart for persistent configuration changes.

### Disable autostart under runit

```sh
sv-disable yggdrasil
```

### Re-enable

```sh
sv-enable yggdrasil
```

The `termux-services` helper uses the presence of:

```text
$PREFIX/var/service/yggdrasil/down
```

to represent a disabled service.

---

## 18. Why the setup is designed this way

### 18.1 Native Android/cgo build instead of a Linux binary

The Yggwiki Android guide historically demonstrated a Linux/arm64 build.

This guide instead builds directly inside Termux and verifies:

```text
GOOS=android
CGO_ENABLED=1
```

On the tested system, the native Android/cgo build integrated with Android's resolver correctly, so no separate Termux `dnsmasq` was required.

That matters because a custom DNS daemon can conflict with Android networking and tethering components.

The final design intentionally has no custom DNS service.

### 18.2 Why `ygg0` is fixed

Policy routing and firewall rules must refer to a deterministic interface.

Therefore:

```text
IfName: ygg0
```

is used instead of an automatically generated name.

### 18.3 Why a UNIX admin socket

The control API does not need to listen on TCP.

This guide uses:

```text
unix:///data/data/com.termux/files/usr/tmp/yggdrasil.sock
```

The trade-off is that the socket is root-owned because the daemon runs as root, so control commands are also executed through root.

### 18.4 Why `runit`

Yggdrasil needs root in this setup because it creates and manages a TUN interface and routing state.

`runit` provides a proper service lifecycle:

```text
run
finish
restart
status
```

This is cleaner than launching a root daemon directly in the background from a boot script.

### 18.5 Why Termux:Boot is still needed

Android does not automatically launch Termux's `runsvdir` after a device reboot.

Termux:Boot supplies the Android boot trigger.

The `10-services.sh` script starts `termux-services`, which starts `runsvdir`, which supervises Yggdrasil.

### 18.6 Why routing lives in `run`/`finish`

Some existing Android guides place Yggdrasil routing in a separate Termux:Boot script.

This guide instead ties routing to the lifecycle of the interface:

```text
service up
-> create route state

service down
-> remove route state
```

That makes `sv down yggdrasil` cleanly remove the Yggdrasil network interface and its policy rule without waiting for a reboot.

### 18.7 Why only rule 1000 is used

Existing examples commonly add both source- and destination-based RPDB rules.

The tested system was deliberately tested without rule `999`.

Outbound route selection still chose:

```text
table 200
dev ygg0
src <YGG_IP>
```

and real outbound TCP worked.

Inbound TCP was also tested while the firewall was temporarily absent: the phone produced the correct SYN-ACK through `ygg0` with only rule `1000`.

For this setup, rule `999` added no required behavior and was removed.

### 18.8 Why the firewall lives in Termux:Boot

Firewall state is one-shot kernel configuration.

It does not need a permanent supervised process.

Therefore:

```text
Termux:Boot -> apply firewall once
runit       -> supervise Yggdrasil continuously
```

The firewall remains installed when Yggdrasil is stopped and automatically begins matching again when `ygg0` reappears.

### 18.9 Why the firewall uses conntrack

Without state tracking, blocking all incoming Yggdrasil traffic would also block replies to connections initiated by the phone.

`conntrack` distinguishes:

```text
NEW
ESTABLISHED
RELATED
INVALID
```

So the policy can allow replies while blocking unsolicited inbound connections.

### 18.10 Why Android firewall chains are not flushed

Android manages its own Netfilter chains.

The Yggdrasil rules are appended to `INPUT` and match only:

```text
-i ygg0
```

The guide intentionally does not alter the rest of Android's firewall topology.

---

## 19. Updating Yggdrasil

An unpatched binary removes the direct peer socket behaviour. The supplied patch is pinned to v0.5.14: reapply it when rebuilding that release and verify its applicability and socket behaviour before upgrading to a different release. Follow section 5 for a rebuild of the tested version; the steps below describe the general update process, not a verified direct-transport build of another version.

Yggdrasil does not provide a built-in update notification mechanism, so check upstream releases periodically:

https://github.com/yggdrasil-network/yggdrasil-go/releases

Do **not** blindly replace a working root networking daemon.

The safe update model is:

```text
build the new version separately
              │
              ▼
verify new binaries and existing config
              │
              ▼
backup current binaries and config
              │
              ▼
      sv down yggdrasil
              │
              ▼
       install new binaries
              │
              ▼
       sv up yggdrasil
              │
              ▼
     post-update verification
          ┌───┴───┐
          │       │
      success   failure
          │       │
          ▼       ▼
    keep update  rollback
```

### 19.1 Do not regenerate the configuration during a normal update

Your Yggdrasil identity is derived from the cryptographic keypair stored in the configuration.

Regenerating the config creates a new identity and therefore a different Yggdrasil IPv6 address.

Keep:

```text
$PREFIX/etc/yggdrasil.conf
```

unless you intentionally want a new node identity.

### 19.2 Clone the new release separately

Replace:

```text
vX.Y.Z
```

with the release you intentionally selected.

```sh
cd ~
```

```sh
rm -rf ~/yggdrasil-go-update
```

```sh
git clone --depth 1 --branch vX.Y.Z https://github.com/yggdrasil-network/yggdrasil-go.git ~/yggdrasil-go-update
```

```sh
cd ~/yggdrasil-go-update
```

### 19.3 Build it

For a release that still requires the same linker workaround:

```sh
./build -p -l "-checklinkname=0"
```

Do not assume forever that every future version needs exactly the same build flags. Check the release notes first.

### 19.4 Verify the new binaries before touching the running service

```sh
./yggdrasil -version
```

```sh
go version -m ./yggdrasil | grep -E 'CGO_ENABLED|GOOS|GOARCH'
```

```sh
go version -m ./yggdrasilctl | grep -E 'CGO_ENABLED|GOOS|GOARCH'
```

### 19.5 Check the existing configuration with the new binary

```sh
./yggdrasil -useconffile "$PREFIX/etc/yggdrasil.conf" -normaliseconf >/dev/null && echo CONFIG_OK
```

Expected:

```text
CONFIG_OK
```

Do not automatically write normalized output back into the config during an update.

If a release changes configuration semantics, read its release notes and make deliberate changes.

### 19.6 Create a rollback backup

```sh
rm -rf "$HOME/yggdrasil-update-backup"
```

```sh
mkdir -p "$HOME/yggdrasil-update-backup"
```

```sh
cp "$PREFIX/bin/yggdrasil" "$HOME/yggdrasil-update-backup/yggdrasil"
```

```sh
cp "$PREFIX/bin/yggdrasilctl" "$HOME/yggdrasil-update-backup/yggdrasilctl"
```

```sh
cp "$PREFIX/etc/yggdrasil.conf" "$HOME/yggdrasil-update-backup/yggdrasil.conf"
```

The config backup is especially important because it contains the node identity.

### 19.7 Stop the current daemon

```sh
sv down yggdrasil
```

Confirm:

```sh
sv status yggdrasil
```

### 19.8 Install the new binaries

```sh
install -m 755 ~/yggdrasil-go-update/yggdrasil "$PREFIX/bin/yggdrasil"
```

```sh
install -m 755 ~/yggdrasil-go-update/yggdrasilctl "$PREFIX/bin/yggdrasilctl"
```

The runit scripts, firewall and Termux:Boot files do not need to change for a normal binary-only update.

### 19.9 Start the updated version

```sh
sv up yggdrasil
```

Check:

```sh
sv status yggdrasil
```

```sh
"$PREFIX/bin/yggdrasil" -version
```

### 19.10 Post-update verification

Check the interface:

```sh
su -c 'ip -6 addr show dev ygg0'
```

Check rule `1000`:

```sh
su -c 'ip -6 rule show' | grep '^1000:'
```

Check table `200`:

```sh
su -c 'ip -6 route show table 200'
```

Check peers:

```sh
su -c "$PREFIX/bin/yggdrasilctl -endpoint=unix://$PREFIX/tmp/yggdrasil.sock getPeers"
```

Check actual traffic:

```sh
curl -6 --noproxy '*' --connect-timeout 10 -I 'http://[324:71e:281a:9ed3::ace]/'
```

Check that the firewall is still present:

```sh
su -c '/system/bin/ip6tables -S INPUT'
```

### 19.11 Rollback

If the new version fails:

```sh
sv down yggdrasil
```

Restore the old daemon:

```sh
install -m 755 "$HOME/yggdrasil-update-backup/yggdrasil" "$PREFIX/bin/yggdrasil"
```

Restore the old control utility:

```sh
install -m 755 "$HOME/yggdrasil-update-backup/yggdrasilctl" "$PREFIX/bin/yggdrasilctl"
```

Restore the configuration if it was changed:

```sh
install -m 600 "$HOME/yggdrasil-update-backup/yggdrasil.conf" "$PREFIX/etc/yggdrasil.conf"
```

Start the old version:

```sh
sv up yggdrasil
```

Verify:

```sh
sv status yggdrasil
```

### 19.12 Cleanup after a successful update

After the updated version has been stable long enough that you no longer need immediate rollback:

```sh
rm -rf "$HOME/yggdrasil-go-update"
```

Then, when you are satisfied that the rollback copy is no longer needed:

```sh
rm -rf "$HOME/yggdrasil-update-backup"
```

---

## 20. Removing the setup

If you want to remove Yggdrasil while keeping Termux and `termux-services`:

### 20.1 Stop and disable the service

```sh
sv down yggdrasil
```

```sh
sv-disable yggdrasil
```

### 20.2 Remove the service directory

```sh
rm -rf "$PREFIX/var/service/yggdrasil"
```

### 20.3 Remove the firewall boot script

```sh
rm -f "$HOME/.termux/boot/05-ygg-firewall.sh"
```

Keep `10-services.sh` if you use other Termux services.

### 20.4 Remove the currently loaded Yggdrasil firewall rules

```sh
su -c '/system/bin/ip6tables -D INPUT -i ygg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true'
```

```sh
su -c '/system/bin/ip6tables -D INPUT -i ygg0 -m conntrack --ctstate INVALID -j DROP 2>/dev/null || true'
```

```sh
su -c '/system/bin/ip6tables -D INPUT -i ygg0 -j DROP 2>/dev/null || true'
```

### 20.5 Remove binaries

```sh
rm -f "$PREFIX/bin/yggdrasil"
```

```sh
rm -f "$PREFIX/bin/yggdrasilctl"
```

### 20.6 Configuration and identity

Only delete the config if you are sure you do not want to keep the same Yggdrasil identity:

```sh
rm -f "$PREFIX/etc/yggdrasil.conf"
```

If you may reinstall later and want the same Yggdrasil address, back this file up instead.

---

## 21. Sources and acknowledgements

This guide is based on upstream documentation, existing Android/Termux approaches and direct testing of the final configuration.

### Yggdrasil

Official website:

https://yggdrasil-network.github.io/

Installation:

https://yggdrasil-network.github.io/installation.html

Configuration:

https://yggdrasil-network.github.io/configuration.html

Configuration reference:

https://yggdrasil-network.github.io/configurationref.html

FAQ and firewall recommendation:

https://yggdrasil-network.github.io/faq.html

Public peers:

https://github.com/yggdrasil-network/public-peers

Yggdrasil source:

https://github.com/yggdrasil-network/yggdrasil-go

Network identity / privacy:

https://yggdrasil-network.github.io/privacy.html

### Termux

Termux:

https://termux.dev/

Termux:Boot:

https://github.com/termux/termux-boot

Termux services / runit integration:

https://github.com/termux/termux-services

### VPN compatibility and service lifecycle

WebRTC Android network discovery:

https://webrtc.googlesource.com/src/+/refs/heads/main/sdk/android/api/org/webrtc/NetworkMonitorAutoDetect.java

Android netd policy routing:

https://android.googlesource.com/platform/system/netd/+/master/server/RouteController.cpp

Kernel link/address events through `ip monitor`:

https://man7.org/linux/man-pages/man8/ip-monitor.8.html

Local IPv6 addresses (ULA):

https://www.rfc-editor.org/rfc/rfc4193.html

Bash coprocesses and `wait`:

https://www.gnu.org/software/bash/manual/html_node/Coprocesses.html

https://www.gnu.org/software/bash/manual/html_node/Job-Control-Builtins.html

runit service supervision and `finish`:

https://smarden.org/runit/runsv.8.html

### Existing Android guides used as reference

Yggwiki — Android installation:

https://yggwiki.cc/yggdrasil:install:android

Zenfyr — Yggdrasil on Android:

https://zenfyr.dev/notes/0004-yggdrasil-android/

The final configuration in this README is **not** a verbatim copy of either guide.

Important differences include:

- native Android/cgo build;
- fixed `ygg0`;
- UNIX admin socket;
- routing tied to `runit` lifecycle;
- event-driven VPN ULA restoration inside the same service;
- only destination rule `1000`, without source rule `999`;
- stateful `ip6tables` protection on `ygg0`;
- firewall persistence through Termux:Boot;
- no custom `dnsmasq`;
- full reboot verification;
- tested inbound and outbound packet-flow behavior.

---

## Final state

A successful installation ends with:

```text
Android
│
├── normal Android networking
│
├── Termux:Boot
│   ├── 05-ygg-firewall.sh
│   └── 10-services.sh
│
├── runit
│   └── yggdrasil service
│       ├── Yggdrasil daemon
│       └── VPN link/address handler
│
├── ygg0
│   └── Yggdrasil IPv6
│
├── RPDB
│   └── 1000: to 200::/7 lookup 200
│
├── table 200
│   └── 200::/7 -> ygg0
│
└── IPv6 INPUT firewall
    ├── ESTABLISHED,RELATED -> ACCEPT
    ├── INVALID             -> DROP
    └── everything else     -> DROP
```

No Android VPN API. No custom DNS daemon. No additional overlay-routing wrapper.

Just native Yggdrasil, Android TUN, policy routing, `runit`, an event-driven VPN compatibility handler and a small stateful firewall.

## License

GPL-3.0-or-later — see [LICENSE](LICENSE).
