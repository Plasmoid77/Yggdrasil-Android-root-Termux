# Yggdrasil on rooted Android via Termux - Full Guide

[Project overview](../README.md) · [Quick setup](../QUICKSTART.md)

Native Yggdrasil node on rooted Android without the Android VPN API.

This guide runs the regular Yggdrasil userspace router directly on Android. It creates a real `ygg0` TUN interface and routes only Yggdrasil addresses through it. `runit` supervises the daemon. Termux:Boot starts the supervisor after reboot. `run` applies the firewall before starting Yggdrasil. Android keeps its existing Internet/VPN routing policy.

The `ultimate` branch combines direct peer transport with one event-driven ULA handler. The handler supports IPv4-only VPNs and the current physical Internet interface. v3 derives two different ULAs from the node identity: `fd43:` for the VPN and `fd42:` for the primary physical uplink.

The same runit service sets up the firewall, takes over a previous session, batches Netlink events and limits log storage. See [section 10.3](#103-android-vpn--webrtcvoip-compatibility) for details, interface selection and tested limits.

This branch builds Yggdrasil v0.5.14 with a small socket patch for outgoing TCP-based and QUIC peers. Peer traffic stays outside the Android VPN. Android chooses Wi-Fi or mobile data. Other applications keep their VPN policy. No extra switching service is needed. [Transport details and measured results](../DIRECT-TRANSPORT.md).

> **Tested with Yggdrasil v0.5.14 on LineageOS 23 (Android 16).**
>
> **Guide by Plasmoid (Neuroslopped)**

This is a root-only setup. It does **not** use:

- the Android VPN API;
- the Yggdrasil Android GUI app;
- systemd;
- a userspace VPN wrapper.

The setup works like a normal Linux Yggdrasil installation, with Android and Termux integration.

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

Normal Android traffic keeps using Android's routing tables.

Outgoing TCP-based and QUIC/UDP peer sockets carry Android's `protectedFromVpn` bit (`SO_MARK=0x20000`). Only those sockets bypass the VPN. Android selects the physical network for public peers. No fixed Wi-Fi or mobile interface names are used. Local multicast discovery is limited separately to Wi-Fi interfaces named `wlanN`.

The service adds /128 helpers derived from the node address to eligible IPv4-only interfaces: `fd43:` for VPNs and `fd42:` for the primary physical uplink. It preserves existing global-scope IPv6. It groups Netlink events into batches and uses no polling timer. Primary selection excluded IMS and hotspot downstream on the tested phone. See section 10.3.

`runit` supervises the Yggdrasil daemon. Control it with:

```sh
sv status yggdrasil
sv up yggdrasil
sv down yggdrasil
```

It restarts the service automatically if the supervised service exits.

A stateful IPv6 firewall protects incoming traffic from Yggdrasil:

```text
ESTABLISHED,RELATED -> ACCEPT
INVALID             -> DROP
everything else     -> DROP
```

The service applies the firewall before each daemon start, including starts from a login shell. Automatic restart needs a live supervisor. See [previous-session takeover](#94-previous-session-takeover).

---

## 2. Architecture

The final setup looks like this:

```text
Android boot
│
└── Termux:Boot
    │
    └── 10-services.sh
        ├── termux-wake-lock
        └── starts termux-services / runit
            │
            └── yggdrasil
                │
                ├── run
                │   ├── starts one persistent root Bash session
                │   ├── waits for previous root-session cleanup
                │   ├── deduplicates RPDB rule 1000 and applies firewall
                │   ├── removes stale ygg0
                │   ├── prepares /dev/net/tun
                │   ├── starts Yggdrasil and waits for ygg0
                │   ├── installs 200::/7 in table 200
                │   ├── subscribes to batched link/address/route/rule events
                │   ├── maintains distinct key-derived VPN/physical ULAs
                │   └── supervises Yggdrasil, monitor and event worker
                │
                ├── finish
                │   ├── stops Yggdrasil
                │   ├── removes ygg0
                │   └── removes RPDB rule 1000
                │
                └── log/run → svlogd (bounded logs)
```

The two components have separate roles:

```text
Termux:Boot = one-shot boot initialization
runit       = long-running service supervision
```

Termux:Boot starts the supervisor after Android boots. It does not replace `runit`.

---

## 3. Requirements

You need:

- a rooted Android device with working non-interactive root through `su -c`;
- Termux, including its Bash shell;
- the separate **Termux:Boot Android app**, installed and activated as described below.

> **For automatic startup after reboot:** install Termux:Boot as an Android app and **open its launcher icon once**. Opening Termux does not activate Termux:Boot. You cannot install the Android app with `pkg`. [Official instructions](https://github.com/termux/termux-boot#how-to-use).

The following sections create one `10-services.sh` boot script and enable the service. Complete [firewall setup](#11-firewall), [Termux:Boot setup](#12-autostart-with-termuxboot) and [first launch](#13-first-launch) before checking reboot. You then do not need to open Termux after every reboot.

Install Termux and Termux:Boot from the same signing source: both from F-Droid or both from official GitHub releases. Mixed signatures can cause an "unknown error". The apps share an Android UID and need matching APK signatures. See [Termux installation requirements](https://github.com/termux/termux-app#installation).

Root must already be configured and working.

### 3.1 Optional Android child process restrictions

Android 12+ can kill Termux child processes through the phantom process killer. Low memory and ROM-specific background restrictions can also kill the supervisor.

In the observed Android 16 incident, both `runsvdir` and `runsv yggdrasil` were killed. The root Yggdrasil session survived. The next login restored supervision. v3 handles a surviving session before changing its network state. It cannot restart a dead supervisor itself. [Takeover details](#94-previous-session-takeover).

Disabling phantom process monitoring is **optional** and affects **all apps**. It allows more child processes, which may use more resources. It does not prevent every type of process killing. You can keep the default, with the temporary loss of restart protection described above.

On Android 14+, Developer options may offer **Disable child process restrictions**. Turn it on to disable this monitor. The following root command has equivalent monitoring behavior:

```sh
su -c 'settings get global settings_enable_monitor_phantom_procs'
su -c 'settings put global settings_enable_monitor_phantom_procs false'
```

Record the previous value before changing it. If it was `null`, remove the override to restore it:

```sh
su -c 'settings delete global settings_enable_monitor_phantom_procs'
```

If the previous value was explicit, restore that value instead. Restore it through the method you used.

The UI and command may store the setting differently. AOSP's [Settings controller](https://android.googlesource.com/platform/packages/apps/Settings/+/refs/heads/main/src/com/android/settings/development/PhantomProcessPreferenceController.java) toggles a feature property. [FeatureFlagUtils](https://android.googlesource.com/platform/frameworks/base/+/e4fadcbaec4197204e1f89ef7c9cb989b6afaa89/core/java/android/util/FeatureFlagUtils.java) gives the Global override priority. Availability varies by ROM.

On Android 12–13, the older alternative raises the phantom-process limit. It does not disable all monitoring:

```sh
su -c 'device_config get activity_manager max_phantom_processes'
su -c 'device_config put activity_manager max_phantom_processes 2147483647'
```

Record the previous value here too. Restore it with `device_config put`. If it was `null`, remove the override:

```sh
su -c 'device_config delete activity_manager max_phantom_processes'
```

System configuration updates can overwrite DeviceConfig values. This guide does not require disabling DeviceConfig synchronization globally. Some 12L/13 ROMs also support the monitoring flag. See the [AOSP Android 12 phantom process implementation](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/android12-release/services/core/java/com/android/server/am/PhantomProcessList.java).

---

## 4. Prepare Termux

Update package metadata:

```sh
pkg update
```

Enable the Termux root package repository. It provides `tcpdump` for the later verification steps:

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

You do not need to install `clang` separately. The Termux `golang` package already depends on it. Cgo uses it as the C compiler.

The later verification steps use extra tools. Yggdrasil itself does not need them. Install them to repeat those tests:

```sh
pkg install curl openssh tcpdump
```

They are used only for verification:

- `curl` — HTTP connectivity test over Yggdrasil;
- Android's system `ping` command — ICMP reachability test; no separate `iputils` package is required here;
- `openssh` — temporary inbound SSH target for the firewall test;
- `tcpdump` — observing packets on `ygg0` during the firewall test.

Run the commands above as the normal Termux user. The later `su -c` commands use root for system networking. Your Android root solution supplies `su`. Android supplies `/system/bin/ip6tables`. You do not need `sudo` or `tsu`.

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

The compiler name may vary with the Termux toolchain. If `LD_PRELOAD` interferes with Go, use `env -u LD_PRELOAD go ...` for the affected command. For the build wrapper, use `env -u LD_PRELOAD PKGVER=0.5.14-direct.3 ./build -p -l "-checklinkname=0"`. Use this workaround only when needed. You do not need to change the shell environment globally.

Build an **Android** binary with **cgo enabled**. A generic Linux/arm64 binary is not suitable for this guide.

---

## 5. Build Yggdrasil natively for Android

This guide uses a fixed, tested upstream release. The [verification matrix](#evidence-and-limits) lists the service revisions and scenarios:

```text
v0.5.14
```

First obtain this guide's patch:

```sh
cd ~
git clone --depth 1 --branch ultimate https://github.com/Plasmoid77/Yggdrasil-Android-root-Termux.git yggdrasil-android-guide
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
PKGVER=0.5.14-direct.3 ./build -p -l "-checklinkname=0"
```

Use fresh source and apply the patch only once. The daemon version should be `0.5.14-direct.3`.

These commands perform three separate steps:

1. `git apply --check` checks whether the patch fits the source. It changes no files. It does not prove that the patch works correctly on a future release.
2. `git apply` changes the source files listed in the patch. It does not rebuild or change the installed daemon.
3. `./build` builds `yggdrasil` and `yggdrasilctl` in the current directory. You install them later.

`PKGVER=0.5.14-direct.3` sets the displayed build version. The suffix does not enable VPN bypass. `-p` selects `-buildmode=pie` for Android. `-l` passes the next string to the Go linker. See the upstream [v0.5.14 build script](https://github.com/yggdrasil-network/yggdrasil-go/blob/v0.5.14/build). The source changes provide bypass.

Patch and build as the normal Termux user. The service runs the installed daemon as root so it can set the socket mark. For an existing installation or a future release, follow [section 19](#19-updating-yggdrasil). Do not repeat new-install commands or generate a new private key.

### Why `-checklinkname=0`?

With the tested Go toolchain, building Yggdrasil v0.5.14 without this linker option failed. The error was similar to:

```text
invalid reference to net.zoneCache
```

The dependency uses `go:linkname`. Newer Go versions apply stricter checks to it. The `-checklinkname=0` linker flag lets this version build with the tested Go toolchain.

This build detail is specific to the version. When upgrading, check whether the flag is still needed.

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

### 5.2 What the patch changes

The [patch](../patches/android-peer-vpn-bypass.patch) is a unified diff against v0.5.14. Read it as follows:

- `diff --git` names each changed file.
- `@@` marks a changed region.
- Lines starting with `-` are removed.
- Lines starting with `+` are added.
- Unchanged context helps Git find the location.

The patch changes three source files: 56 added lines and 7 removed lines.

**`src/core/link_tcp.go` — run socket control on Android.** Upstream selected `getControl` only for peers bound to a named interface. The patch also selects it for Android with ordinary `Peers`. No interface needs to be specified:

```go
if sintf != "" || runtime.GOOS == "android" {
    dialer.Control = l.getControl(sintf)
}
```

The separate interface-selection code still runs only when `sintf` is nonempty. The default configuration does not fix `wlan0` or a mobile interface. Android chooses the physical network for each new connection. TCP, TLS, WS, WSS, SOCKS and SOCKS+TLS share this TCP dialer.

**`src/core/link_tcp_linux.go` — mark the socket before connection.** The callback gets the socket descriptor through `syscall.RawConn.Control`. On Android, it runs:

```go
unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_MARK, 1<<17)
```

`1<<17` equals `0x20000`, the `protectedFromVpn` bit in Android's [Fwmark.h](https://android.googlesource.com/platform/system/netd/+/refs/heads/main/include/Fwmark.h). This is local socket-routing metadata. It is not a packet field sent to the peer.

On the tested rooted phone, Android routes these sockets outside the VPN. If you request a named interface, `BindToDevice` still runs after marking. The dialer receives any descriptor, marking or binding error. Failed setup stops the connection instead of silently using the VPN.

The filename ends in `_linux.go` because Android also uses Go's Linux platform files. `runtime.GOOS == "android"` limits the new mark to Android. A generic Linux binary would skip that branch.

**`src/core/link_quic.go` — give QUIC a marked UDP socket.** Upstream's `quic.DialAddr` creates its own UDP socket. On Android, the patch creates one through `net.ListenConfig` with the same socket-control callback:

```go
lc := net.ListenConfig{Control: l.tcp.getControl(info.sintf)}
```

The patch chooses UDP/IPv4 or UDP/IPv6 for the resolved destination. It calls `ListenPacket`, then passes the socket to `quic.Dial`. The mark is set before the first QUIC handshake packet.

The outgoing stream wrapper stores the owned `packetConn`. Failed connections, failed stream creation and stream closure close that socket. Non-Android QUIC dialing keeps the original `DialAddr` path.

These changes protect only outgoing peer transport sockets. They add no service, polling loop, routing rule or firewall rule. `unix://` is local IPC and needs no IP-routing change. DNS may still use the VPN. For SOCKS, the marked connection reaches the proxy. The proxy controls the route from there. The patch does not change incoming QUIC listeners.

See [section 10.4](#104-direct-peer-transport) for coverage and [DIRECT-TRANSPORT](../DIRECT-TRANSPORT.md#all-outgoing-peer-transports-in-direct3) for tests and limits.

---

## 6. Create the Yggdrasil configuration

Generate a configuration for a new node only. To reinstall an existing node, first back up its binaries, configuration and service/boot scripts. Then copy its existing configuration to keep the identity:

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

Configure public peers, Wi-Fi multicast discovery, the interface name and the admin socket.

### 6.1 Peers

Yggdrasil does not connect to arbitrary Internet peers automatically. Add public peers to:

```text
Peers: [
]
```

Current public peers are published here:

https://github.com/yggdrasil-network/public-peers

The official public-peers repository recommends **2 or 3 peers** for normal use. Choose nearby peers to reduce latency. A small set of stable peers gives redundancy without unnecessary distant connections.

The default example uses TCP IPv4 addresses in ordinary `Peers`. The socket patch supports TCP, TLS, WS, WSS, SOCKS, SOCKS+TLS and QUIC. See section 10.4. The tests used the addresses below. Check their current availability before choosing them:

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

Choose current nearby peers from the public-peers repository. IPv4 addresses avoid peer DNS lookups through the VPN. Public peers have no fixed interface. Android selects the physical network.

#### Wi-Fi multicast discovery

`MulticastInterfaces` enables built-in discovery on Wi-Fi interfaces named `wlanN`.

- `Beacon: true` advertises this node.
- `Listen: true` discovers other nodes on the LAN and connects to them.
- Discovery uses IPv6 link-local multicast (`ff02::114`, UDP port 9001).
- Peer connections use TLS over TCP.
- `Port: 0` chooses the local TCP port automatically.

Keep the regular `Listen: []`. Multicast creates its own link-local listener without a general incoming listener.

The Wi-Fi regex limits local discovery only. Public peers still use Android's default physical network, including mobile data. No helper service or extra firewall rules are needed. The existing firewall still protects traffic arriving through `ygg0`.

If a router runs Yggdrasil with compatible LAN multicast, the phone can become its direct LAN peer. The [OpenWrt status module](https://github.com/Plasmoid77/Yggdrasil-OpenWRT/blob/main/source/yggdrasil-status/README.md#behavior) then reads the phone's native `node` address from the router's peer table and maps it to the phone's MAC. A local peer connection is required for this field. Connecting to Wi-Fi alone is not enough.

Wi-Fi client isolation or blocked multicast can prevent discovery. To disable local discovery but keep public peers, set `MulticastInterfaces: []` and restart Yggdrasil.

### 6.2 Fix the interface name

Find:

```text
IfName:
```

and set:

```text
IfName: ygg0
```

The routing and firewall rules match `ygg0`, so the interface name must stay fixed.

### 6.3 Use a UNIX admin socket

Set:

```text
AdminListen: unix:///data/data/com.termux/files/usr/tmp/yggdrasil.sock
```

The generated configuration may lack `AdminListen`. If so, add it as a **top-level field inside the outer `{ ... }` configuration object**. For example, place it before the final closing brace:

```text
{
  ...
  AdminListen: unix:///data/data/com.termux/files/usr/tmp/yggdrasil.sock
}
```

This keeps the control API off a TCP listener.

Yggdrasil runs as root, so its UNIX socket is normally root-owned. Use root for `yggdrasilctl` too.

### 6.4 Check the generated Yggdrasil address

Run:

```sh
~/yggdrasil-go/yggdrasil -address -useconffile ~/yggdrasil.conf
```

It should return an address from Yggdrasil's `200::/7` range.

The configuration contains the node's cryptographic identity. Keep it to retain the same Yggdrasil address.

### 6.5 Validate the configuration

Run:

```sh
~/yggdrasil-go/yggdrasil -useconffile ~/yggdrasil.conf -normaliseconf >/dev/null && echo CONFIG_OK
```

Expected:

```text
CONFIG_OK
```

This command checks parsing and compatibility. It does not overwrite the configuration.

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
├── finish
└── log/
    └── run
```

Boot integration will add:

```text
~/.termux/boot/
└── 10-services.sh

$PREFIX/var/run/
└── yggdrasil-root        # root PID + start time

$PREFIX/var/log/sv/yggdrasil/
├── config               # svlogd rotation settings
├── current
└── @...                  # rotated logs
```


---

## 9. Create the runit service

Create the service directory:

```sh
mkdir -p "$PREFIX/var/service/yggdrasil"
```

Prevent an existing `runsvdir` from starting the service before both scripts are ready:

```sh
touch "$PREFIX/var/service/yggdrasil/down"
```

### 9.1 `run`

Create:

```sh
nano "$PREFIX/var/service/yggdrasil/run"
```

Contents:

The v3 `run` has 276 lines in five sections: previous session, routing/firewall, Yggdrasil, helper ULAs and network events. Copy the whole script, including the final `YGG_ROOT` line and `wait` command. [Compatibility details](#103-android-vpn--webrtcvoip-compatibility).

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

The `[y]ggdrasil` pattern prevents `pkill -f` from matching the shell command that runs `pkill` itself.

Make both scripts executable:

```sh
chmod +x "$PREFIX/var/service/yggdrasil/run" "$PREFIX/var/service/yggdrasil/finish"
```

Create the logger and boot script before enabling the service. `run` already applies the firewall before starting Yggdrasil.

### 9.3 Service logs

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

`run` creates `/dev/net/tun` as a symlink to `/dev/tun` only if the path is missing. It keeps an existing path.

### 9.4 Previous-session takeover

The root Bash session writes its PID and Linux process start time to `$PREFIX/var/run/yggdrasil-root`. A later run checks both values before sending TERM to the old session. This avoids treating a reused PID as the previous owner.

The new session waits up to ten seconds for cleanup **before** changing routing, firewall or `ygg0`. If the old session is still alive, startup exits with an error. The enabled runit service then retries.

The root session stops and reaps its Yggdrasil, monitor and worker children. The worker removes ULAs it owns. This handles a session that survived the loss of its Termux supervisor.

`finish` still stops the daemon by configuration path and removes the interface/rule. Use runit for service control. Do not launch concurrent copies of `run` manually. The state file records takeover data; it is not an atomic lock for simultaneous launches.

Killing only `runsvdir` leaves existing `runsv` processes supervising their services. Killing `runsv` too removes that protection. SIGKILL cannot run `finish` or shell traps.

On the tested phone, the root session started by Magisk kept running. A later Termux login or reboot restores the supervisor. v3 then takes over in the order above. Until then, an orphaned Yggdrasil can keep working, but runit cannot restart it if it fails. See [background restrictions](#31-optional-android-child-process-restrictions), [runsv](https://smarden.org/runit/runsv.8) and [runsvdir](https://smarden.org/runit/runsvdir.8).

### 9.5 Upgrading an existing service profile

A binary-only update in [section 19](#19-updating-yggdrasil) keeps the service scripts. It does not install v3. To migrate an older profile:

- Back up `run`, `finish`, boot scripts and any logger/config before replacing them.
- Keep the private Yggdrasil configuration/key and both patched binaries.
- If the old profile is unpatched upstream, also build and install the patch and both binaries as described in sections 5 and 19.
- Check root access and a working supervisor before stopping anything.

Stop the old service through its live supervisor. Confirm that the daemon and root worker have exited **before** replacing the script. Sessions from before v2 have no PID/start-time takeover record.

Install the complete `run`/`finish` blocks above and the logger/config. Make the scripts executable. Keep `10-services.sh`. You may remove the obsolete firewall boot script.

Check the outer shell with `sh -n`. Check the embedded `YGG_ROOT` Bash body separately with `bash -n`. Checking the outer heredoc alone does not validate the Bash body.

Resume the service only if it was meant to run. Otherwise, keep its prior disabled/down state. This is a manual migration with saved rollback files. It does not roll back automatically.

Use the [compatibility checks](#verify-the-installed-service), [logs](#93-service-logs) and [verification matrix](#evidence-and-limits). Successful installation alone does not prove calls or boot startup.

---

## 10. Policy routing

Yggdrasil uses:

```text
200::/7
```

for its IPv6 address space.

Keep Android's default IPv6 route. Only traffic with a **destination** inside Yggdrasil should use the Yggdrasil interface.

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

Android has its own policy-routing rules. A low number gives the Yggdrasil destination rule an early check. It does not replace Android's routing setup.

Before adding rule `1000`, `run` removes duplicates of the exact `to 200::/7 lookup 200 prio 1000` rule. If adding it fails, startup stops. Android's other RPDB rules stay unchanged.

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

The tested setup did not need the source rule.

With only rule `1000`, a route lookup returned:

```text
dev ygg0
table 200
src <YGG_IP>
```

Outbound TCP worked normally.

A separate inbound SSH test confirmed correct reply routing from the phone's Yggdrasil address without rule `999`.

So the final tested configuration is:

```text
1000: from all to 200::/7 lookup 200
```

with no `999` rule.

### 10.3 Android VPN + WebRTC/VoIP compatibility

This branch uses one event-driven handler for two tested IPv4-only cases: an Android VPN and the phone's physical Internet network. The peer socket patch handles transport. The ULA handler handles IPv6 compatibility for applications. Yggdrasil itself can carry its IPv6 overlay over IPv4 peers.

In a failed call, XMPP and Yggdrasil were still reachable. WebRTC sent only an IPv4 host candidate. It sent no IPv6 STUN traffic toward the Yggdrasil server. Rule `1000` cannot route packets that the application has not created.

In successful tests, adding a non-link-local IPv6 address to the relevant Internet/VPN interface enabled IPv6 ICE candidates. Adding it only to `ygg0` or an unrelated dummy interface did not fix the earlier VPN case. This workaround enables Android/WebRTC compatibility. It does not provide general IPv6 Internet access.

#### Addresses and interface selection

| Interface | Address and conditions |
| --- | --- |
| Real UP TUN named `tunN` (TUN bit in `tun_flags`; TAP skipped) | `fd43:<node low 112 bits>/128`, with global-scope IPv4 and no other global-scope IPv6 |
| Primary physical uplink named `rmnet_dataN` or `wlanN` | `fd42:<node low 112 bits>/128`, with the same UP/IPv4/IPv6 conditions |
| Non-primary physical interfaces | Left unchanged; this excluded IMS and hotspot downstream on the tested phone |
| An interface with another global-scope IPv6 address | Existing IPv6 preserved; the handler's own ULA removed if it owns one |

Linux `scope global` includes ULA. It does not mean public Internet access. Link-local `fe80::` alone does not satisfy the IPv6 condition.

Both helpers keep the native node address's low 112 bits. Their first groups differ, so VPN and physical helpers have different addresses. The key determines the remaining bits for each phone. Do not copy one private key onto multiple phones. A synthetic example:

```text
Yggdrasil: 202:1234:5678:9abc:def0:1234:5678:9abc
Physical:  fd42:1234:5678:9abc:def0:1234:5678:9abc/128
VPN:       fd43:1234:5678:9abc:def0:1234:5678:9abc/128
```

The VPN helper replaces the old fixed `fd42::1/128`. Do not share one constant address on a physical Wi-Fi LAN. Duplicate unicast addresses can fail [IPv6 duplicate-address detection](https://www.rfc-editor.org/rfc/rfc4862.html#section-5.4).

A controlled A/B test on 2026-10-14 kept the IPv4-only APN and Amnezia VPN unchanged. The messengers were restarted before the decisive test with identical addresses.

- With one node-derived ULA on both VPN and physical interfaces, WebRTC gathered **zero IPv6 candidates**. ICE reached FAILED.
- With different addresses, ICE reached CONNECTED and audio worked. This control used the earlier fixed VPN helper.
- v3 then passed with the node-derived `fd43:` helper.

Keep the two-address policy. Ambiguous IP-to-network mapping inside Android/WebRTC is a proposed explanation. It remains a **hypothesis**, not a proven mechanism or a result for all ROMs.

#### What the handler changes

The worker records the interface index and original `disable_ipv6` value. It enables IPv6 only when needed and adds its own /128 with `nodad`. These addresses come from the key and skip duplicate-address detection.

The handler adds no Internet default route and does not change the native Yggdrasil identity. Calls still use the overlay address through rule `1000`, table `200` and `ygg0`.

The primary physical uplink is the `dev` returned by:

```sh
ip -4 route get 1.1.1.1 mark 0x20000
```

This kernel lookup sends no packet and makes no DNS query. It uses the protected-from-VPN mark of peer sockets. The handler considers only the eligible physical interface returned by the lookup. It does not classify IMS/hotspot networks. Other interface names or ROM routing policies need separate checks.

#### Events and cleanup

The root session subscribes before the initial snapshot:

```sh
ip -o monitor label link address route rule
```

The session confirms the subscription through the monitor's socket inode. It matches the inode in `/proc/PID/fd` to a subscribed entry in `/proc/net/netlink`. It does not assume the Netlink port ID equals the process PID.

After a blocking read, `read -t 0` checks for queued lines. Each batch checks each named link/address interface once. Route/rule events trigger at most one primary-uplink refresh per batch. If the primary changes, the handler checks both old and new uplinks. It adds no periodic timer or extra switching daemon.

Replaying about 15 minutes of recorded events reduced primary route lookups from **860 to 52**. This was an offline replay. It did not count live syscalls or measure battery savings.

The handler still forks `ip` for address checks and route lookups. Repeated netd policy-rule changes can cause work even when the uplink stays the same.

Deleting an owned ULA triggers restoration. The handler releases owned addresses on:

- Link down or loss of IPv4.
- A primary-uplink change.
- Arrival of another global-scope IPv6 address.
- Orderly shutdown.

It restores the saved IPv6 switch only on the same interface index. It also checks that restoration would not disable another global-scope IPv6 address. It neither claims nor deletes a pre-existing address.

The handler attempts at most **four additions per interface in ten seconds**. Failed additions count too. There is no separate permanent failure flag. Link down clears the limit. Interface recreation starts a new window.

After reaching the limit, the handler waits for a later network event. Ten seconds passing does not wake it. It logs `[ULA] Too many changes` once per exhausted window.

One persistent root Bash session owns the daemon, monitor and worker. `wait -n` detects a child exit. Cleanup stops and reaps the other children. A live runit supervisor restarts the enabled service.

Startup waits have time limits. Normal event handling uses no polling loop or recurring `dumpsys`. The handler takes no wake lock. The **boot script's persistent Termux wake lock** is a separate power policy. [Logging](#93-service-logs) · [Supervisor loss and takeover](#94-previous-session-takeover).

#### Verify the installed service

Restart an existing installation after replacing `run`:

```sh
sv restart yggdrasil
su -c 'ip -br addr'
su -c 'ip -4 route get 1.1.1.1 mark 0x20000'
```

With an IPv4-only VPN connected, inspect its actual `tunN`:

```sh
su -c 'ip -6 -o addr show dev tun0 scope global'
```

Expect `fd43:<node low 112 bits>/128` unless the VPN already has another global-scope IPv6 address. For IPv4-only physical Internet, inspect the `dev` from the marked route lookup. Expect the node-derived ULA there. A native dual-stack interface needs no added ULA.

For the actual Yggdrasil server, verify `dev ygg0`, table `200` and the native source address:

```sh
su -c 'ip -6 route get <YGGDRASIL_SERVER_IPV6>'
```

Make a new call. A running service, an address in `ip addr` or connected peers alone do not prove WebRTC gathered IPv6 candidates. During the call, check overlay UDP:

```sh
su -c 'tcpdump -ni ygg0 -tttt -vv udp'
```

Repeat after a VPN reconnect and a Wi-Fi/mobile transition without restarting Yggdrasil. Test reboot separately with sections 15 and 16. Keep the configuration/key when upgrading from an earlier branch.

#### Evidence and limits

These results come from one rooted LineageOS 23 / Android 16 phone running Yggdrasil 0.5.14-direct.3. v3 is the 276-line service script above. It changes service management, not the peer transport patch.

| Scenario | Revision/date | Recorded result and limit |
| --- | --- | --- |
| IPv4-only mobile APN + Amnezia VPN call | v3, 2026-10-14 | CONNECTED with audio; IPv6 candidates and direct bidirectional Yggdrasil media observed |
| Wi-Fi with its own global-scope IPv6 | v3, 2026-10-14 | Owned physical ULA removed; Wi-Fi call worked |
| Mobile → Wi-Fi, then a call | v3, 2026-10-14 | Passed; primary changed and recreated VPN received its `fd43:` helper |
| Wi-Fi → mobile, then a call | v3, 2026-10-14 | Passed; eligible mobile uplink received `fd42:`; call worked; the other application's VPN path remained intact |
| Orphan takeover after `kill -9 runsv` | v2, 2026-10-13; same PID/start-time takeover in v3 | Passed in less than one second; v3-specific repetition not recorded |
| `sv restart` | v2, 2026-10-13; same lifecycle design in v3 | Passed; v3-specific repetition not recorded |
| Full Android reboot | v2, 2026-10-13; same boot trigger and firewall-before-daemon logic | Supervisor and Yggdrasil started at uptime ~23 s; first login at ~104 s. **v3 itself has not passed a reboot test** |
| Uniform ULA on physical + VPN | Controlled A/B, 2026-10-14 | Negative: zero local IPv6 candidates and ICE FAILED after fresh messenger starts; different-address control CONNECTED |
| Offline state models and event replay | v3, 2026-10-14 | 33/33 models passed; 860 → 52 route lookups on the recorded trace |

The previous 207-line handler passed a roughly 95-second mobile/AmneziaWG call on 2026-10-13. ICE connected in 0.443 s. Sustained native Yggdrasil media was observed.

The earlier Wi-Fi, QUIC, long-call and reboot tests in [DIRECT-TRANSPORT.md](../DIRECT-TRANSPORT.md) used older service profiles. They do not prove that every combination was retested on v3.

The handover checks used calls **after** each transition. Continuous mid-call handover was not established. The handler does not restart ICE or move an active call's sockets.

Kernel addresses alone do not prove Android `LinkProperties` or ICE candidates. Check other ROMs, network names, VPNs and application versions separately. See the [WebRTC Android network monitor](https://webrtc.googlesource.com/src/+/refs/heads/main/sdk/android/api/org/webrtc/NetworkMonitorAutoDetect.java). The A/B mechanism and its limits are described under Addresses and interface selection above.

### 10.4 Direct peer transport

The patch in section 5 sets `SO_MARK=0x20000` on outgoing TCP-based and QUIC/UDP peer sockets on Android. Socket setup errors stop the connection instead of allowing an unprotected connection. Android selects Wi-Fi or mobile data. No new supervisor, timer or interface selector is needed. The runit scripts need no transport changes.

Verify the actual peer sockets with the VPN connected:

```sh
su -c "$PREFIX/bin/ss -tnep"
su -c "$PREFIX/bin/ss -ulnep"
```

Public outgoing Yggdrasil peer socket marks should include `0x20000`. TCP shows its physical source address. An unconnected QUIC UDP socket may show a wildcard source. Use a bounded capture to that peer to confirm its interface.

Applications that need the VPN should still use its address. A route lookup alone does not prove the peer socket path.

The tested Conversations/WebRTC setup still needs the ULA inside an IPv4-only VPN. This is separate from sending peer traffic outside the VPN. Calls use the real Yggdrasil address on `ygg0`, not the ULA. Any relay inside Yggdrasil is separate from the phone's Amnezia tunnel.

The earlier `direct.2` build passed Wi-Fi → mobile → Wi-Fi transitions without a Yggdrasil restart. Calls passed separately with Amnezia Premium XRay and AmneziaWG. Bidirectional media used `ygg0`. Peer TCP traffic used physical Wi-Fi. The other application kept its VPN connection.

A clean reinstall of the previous `direct-vpn-bypass` profile and a full Android reboot also passed. An early Termux:Boot snapshot showed automatic startup, both marked peer sockets with physical source addresses, and the restored firewall. Later checks confirmed routing, overlay HTTP and automatic ULA restoration after VPN connection. See [transport verification and limits](../DIRECT-TRANSPORT.md).

The `direct.3` build later passed QUIC-only Wi-Fi/mobile handover and a full reboot. The user reported successful VLESS/Xray calls, including a Wi-Fi call lasting more than an hour. AmneziaWG passed XMPP connectivity checks on mobile data.

The captures did not record call media. A QUIC-only call with AmneziaWG was not separately confirmed. See [QUIC verification and its limits](../DIRECT-TRANSPORT.md#quic-handover-calls-and-reboot). These temporary tests disabled TCP peers and multicast. Normal settings were restored afterward.


The patch covers every outgoing peer scheme supported by Yggdrasil v0.5.14:

| Peer scheme | Local socket / VPN handling |
| --- | --- |
| `tcp://` | Marked outgoing TCP socket |
| `tls://` | TLS over the same marked TCP dialer |
| `ws://` | WebSocket over the same marked TCP dialer |
| `wss://` | WebSocket/TLS over the same marked TCP dialer |
| `socks://` | Marked TCP connection to the SOCKS proxy |
| `sockstls://` | Marked TCP connection to the SOCKS proxy, then TLS |
| `quic://` | Marked UDP socket created before the QUIC handshake |
| `unix://` | Local IPC; no IP socket or VPN route |

Only the daemon's outgoing transport sockets get this mark. The patch does not mark application UDP, all root/Termux traffic or future upstream transports. UDP calls to Yggdrasil already enter `ygg0` through rule `1000`. Peer transport carries these packets over TCP or QUIC.

For QUIC, the daemon creates a UDP socket with the same Android socket control. It then passes the socket to quic-go. Socket-control failures stop the dial. Failed handshakes and closed outgoing streams release the owned UDP socket. Non-Android QUIC dialing keeps upstream behavior.

Hostnames can still resolve through the VPN. SOCKS and environment HTTP proxies are intermediate services. The marked local connection does not control the proxy's onward route. `unix://` is local and needs no bypass.

The guide keeps regular `Listen: []` and exposes no public incoming listeners. Preserve the private key and admin socket.

The current `direct.3` build passed separate transport/socket tests and connected to a real public QUIC peer with the VPN active. UDP traffic appeared only on physical Wi-Fi. The installed daemon kept its identity, configuration, multicast, routing, firewall and Codex's VPN path.

Later `direct.3` QUIC handover and reboot tests are described above. The [v3 matrix](#evidence-and-limits) records checks of the current service script. [Detailed evidence and limits](../DIRECT-TRANSPORT.md).

---

## 11. Firewall

Treat the public Yggdrasil network as untrusted.

Other Yggdrasil nodes can route directly to the host, even if its Internet connection is behind NAT or CGNAT.

The official Yggdrasil FAQ recommends an IPv6 firewall for the TUN interface. This guide uses that stateful policy:

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

Android uses other firewall chains for the OS, bandwidth accounting, networking and tethering.

### 11.1 Applied by the service

Section 2 of `run` applies the three INPUT rules **before** Yggdrasil starts. This covers boot, starts from a login and service restarts.

- `-w` waits for the xtables lock.
- `-C || -A` avoids duplicate rules.
- If applying a required rule fails, startup stops.

No separate firewall daemon or netd wait loop is added.

When upgrading an older installation, you may delete `~/.termux/boot/05-ygg-firewall.sh`. v3 needs only `10-services.sh` for Termux:Boot. Leaving the old firewall script is harmless: its identical rules do not create duplicates.

After the first service start, check the effective INPUT order:

```sh
su -c '/system/bin/ip6tables -S INPUT'
```

Expect one copy of each rule, in this order:

```text
-A INPUT -i ygg0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
-A INPUT -i ygg0 -m conntrack --ctstate INVALID -j DROP
-A INPUT -i ygg0 -j DROP
```

`RELATED,ESTABLISHED` and `ESTABLISHED,RELATED` are equivalent sets. Android or another firewall may insert earlier rules that change the effective policy. Inspect the full chain and use the [packet/counter tests](#15-verify-the-firewall). The service installs rules at startup. It does not keep restoring them after another application rewrites the firewall.

### 11.2 AFWall+

AFWall+'s main UI controls each application's network access. A **custom startup script that supports shell commands** can reapply inbound protection for `ygg0`. Use the same commands as `run`. The script already runs as root:

```sh
# Allow replies to connections initiated by the phone and related traffic.
ip6tables -w -C INPUT -i ygg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT 2>/dev/null ||
    ip6tables -w -A INPUT -i ygg0 -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT || exit 1
# Drop packets that conntrack cannot classify as a valid connection state.
ip6tables -w -C INPUT -i ygg0 -m conntrack --ctstate INVALID -j DROP 2>/dev/null ||
    ip6tables -w -A INPUT -i ygg0 -m conntrack --ctstate INVALID -j DROP || exit 1
# Drop all other inbound traffic arriving through the Yggdrasil interface.
ip6tables -w -C INPUT -i ygg0 -j DROP 2>/dev/null ||
    ip6tables -w -A INPUT -i ygg0 -j DROP || exit 1
```

The checks prevent duplicate rules on reapplication. **Compatibility with AFWall+ was not tested on this phone.** Check rule order after AFWall+ applies its policy.

Custom-script support depends on the AFWall+ version. Some versions accept only individual iptables commands. They reject shell operators such as `||` and redirection. Do not paste this shell block into that parser. Check the [custom-script documentation](https://github.com/ukanth/afwall/wiki/CustomScripts) for your installed version.

---

## 12. Autostart with Termux:Boot

Termux:Boot executes files inside:

```text
~/.termux/boot/
```

in sorted filename order.

This profile needs only `10-services.sh`. It takes the Termux wake lock and starts the supervisor. `run` applies the firewall before each Yggdrasil start.

### 12.1 Create `10-services.sh`

```sh
mkdir -p "$HOME/.termux/boot"
```

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
10-services.sh
```

### 12.2 Why `10-services.sh` exists

Creating service directories does not start `runit`.

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

Termux:Boot could start Yggdrasil directly. That would provide no persistent supervisor, normal `sv up/down/status` control or automatic service restart.

Each component has its own role:

```text
Termux:Boot -> boot trigger
runit       -> service supervisor
```

### 12.3 Manual execution and shell startup

Opening a Termux login shell can start the supervisor through `start-services.sh`. It does not scan `~/.termux/boot/`. v3 still applies the firewall because it is in `run`. A successful start from login does not prove Termux:Boot worked. [Reboot proof](#161-prove-startup-before-the-first-login).

You can run `10-services.sh` manually. This starts the supervisor and takes the wake lock for the current boot. It does not register a boot trigger.

Automatic startup needs the activated Termux:Boot app, an executable script and an enabled service.

### 12.4 Wake lock and battery cost

`termux-wake-lock` holds a persistent partial wake lock for Termux. It keeps the CPU available with the screen off and can prevent normal suspend. This costs battery power even though the handler uses no polling timer.

The extra battery drain was not measured separately. Reliable calls and background availability without the lock have not been established.

Starting only `start-services.sh` during installation does not take the boot script's lock. Section 13 runs the full `10-services.sh` to use the same policy as boot.

`sv down yggdrasil` does not release the shared Termux lock. Other services may need it. If none do, release it with `termux-wake-unlock`. Do not add that command unconditionally to `finish`. See [Android wake lock guidance](https://developer.android.com/topic/performance/issues/excessive-wakelock).

---

## 13. First launch

Start the supervisor with the same wake lock as boot:

```sh
"$HOME/.termux/boot/10-services.sh"
```

Wait for the supervisor to find a new or recreated service directory before enabling Yggdrasil:

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

The check runs immediately and waits at most fifteen seconds. It enables the service only when `sv status` can reach its supervisor. An old `supervise/ok` file alone does not prove `runsv` is running.

This avoids `unable to open supervise/ok` if you run commands immediately after recreating the directory. It adds no polling during normal operation.

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

A `run` result from `sv status` is not enough to confirm the setup.

Check each layer below.

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

A temporarily `Down` peer may not mean a local configuration problem. Public peers can disappear or change.

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

Test the firewall in both directions.

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

This is an **active test** that needs a second Yggdrasil node. Use an existing SSH listener if available. Otherwise, confirm that SSH was down and start it temporarily with `sv up sshd`. Stop it afterward **only if this test started it**. Keep the service's existing enable/disable state.

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

If this test started SSH from a confirmed down state, restore that state with `sv down sshd`. Leave an already-running service alone.

---

## 16. Verify everything after reboot

Reboot Android normally after setup. Follow the checks below to verify your installation. Do not manually start services before collecting startup times.

### 16.1 Prove startup before the first login

A Termux login profile can itself start `runsvdir`. After reboot, open the **first** Termux login. Run this read-only comparison immediately, before any manual service commands.

It reads Linux `/proc/PID/stat` field 22: the process start time in ticks since boot. It reports the supervisor, daemon and surviving Termux login shells:

```sh
su -c "exec /data/data/com.termux/files/usr/bin/bash -s -- $(id -u)" <<'BOOT_CHECK'
P=/data/data/com.termux/files/usr
export PATH=$P/bin:/system/bin:/system/xbin
printf 'CLK_TCK=%s; lower start_ticks means earlier in this boot\n' "$(getconf CLK_TCK)"
show_start() {
    local role=$1 pid=$2 stat
    read -r stat 2>/dev/null < "/proc/$pid/stat" || return
    stat=(${stat##*) })
    printf '%-12s pid=%-7s start_ticks=%s\n' "$role" "$pid" "${stat[19]}"
}
for pid in $(pgrep -f '^/data/data/com[.]termux/files/usr/bin/runsvdir( |$)'); do show_start runsvdir "$pid"; done
for pid in $(pgrep -f '^/data/data/com[.]termux/files/usr/bin/yggdrasil -useconffile /data/data/com[.]termux/files/usr/etc/yggdrasil[.]conf( |$)'); do show_start yggdrasil "$pid"; done
for pid in $(pgrep -u "$1" -f '(bash|sh) (-l|--login)( |$)'); do
    show_start login-shell "$pid"
done
BOOT_CHECK
```

Both `runsvdir` and Yggdrasil must start **earlier than the first login shell**. Divide ticks by `CLK_TCK` to get seconds since boot.

In the recorded v2 reboot, they started at ~23 s. The first login started at ~104 s. With this guide's only boot trigger, those times prove Termux:Boot started the service. v3 uses the same startup/firewall logic but has not itself been reboot-tested.

The command matches executable paths in command lines because Android can truncate process names. Inspect names and arguments with `ps -eo pid,ppid,args`. If your shell uses another login convention, find the first login PID there. Read its stat with the same method.

The snapshot cannot prove Termux:Boot started the service if:

- The first login has exited or no login matches.
- The service has restarted.
- Another boot trigger exists.

Repeat the controlled check or use an independent early-boot observer. A running service after login is not boot proof.

### 16.2 State and connectivity after boot

Repeat the process, interface, routing, admin and application checks in [section 14](#14-verify-yggdrasil-and-routing). Repeat the [firewall checks](#15-verify-the-firewall) and compatibility checks below.

Confirm that the enabled service has a live supervisor and fresh logs. The HTTP example is optional. Test your actual application endpoint too. A public endpoint may be unavailable even when Yggdrasil works.

### 16.3 Direct transport and VPN compatibility

With the VPN connected, inspect TCP and UDP sockets. Find the actual VPN TUN and the physical uplink selected with the mark:

```sh
yggdrasil -version
su -c "$PREFIX/bin/ss -tnep"
su -c "$PREFIX/bin/ss -ulnep"
su -c 'ip -br addr'
su -c 'ip -4 route get 1.1.1.1 mark 0x20000'
```

Check version `0.5.14-direct.3` and the public outgoing peer mark `0x20000`. TCP shows its physical source address. For wildcard QUIC UDP sockets, use a bounded capture to the selected peer to prove the physical path. An `up` peer alone does not prove application readiness.

For the actual interface names found above (these are examples):

```sh
su -c 'ip -6 -o addr show dev tun0 scope global'
su -c 'ip -6 -o addr show dev rmnet_data0 scope global'
```

Eligible IPv4-only VPN TUNs should have `fd43:<node low 112 bits>/128`. The primary physical interface should have `fd42:<same bits>/128`. A network with another global-scope IPv6 address needs no owned ULA.

Confirm that an application requiring the VPN still uses it. Make a fresh call to check ICE and audio. These checks confirm state and connectivity. The start-time comparison above proves pre-login startup.

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

The firewall rules remain installed. They do not match while `ygg0` is absent. The shared Termux wake lock also remains. Release it only if no other service needs it. [Power policy](#124-wake-lock-and-battery-cost).

Stopping Yggdrasil removes ULAs added by this handler. It restores the saved IPv6 flag where safe. It leaves pre-existing addresses alone. Restarting adds eligible ULAs again and preserves existing native IPv6.

### Start

```sh
sv up yggdrasil
```

The service takes over a recorded previous session, checks the firewall and recreates:

```text
rule 1000
ygg0
table 200 route
link/address/route/rule event monitor
ULA handler for eligible VPN TUN and current Internet interfaces
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

Current Yggdrasil versions do not reload configuration with `SIGHUP`. Restart the service to apply saved configuration changes.

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

On the tested system, the native Android/cgo build worked correctly with Android's resolver. No separate Termux `dnsmasq` was needed.

A custom DNS daemon can conflict with Android networking and tethering.

This setup uses no custom DNS service.

### 18.2 Why `ygg0` is fixed

Routing and firewall rules need a fixed interface name.

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

The daemon runs as root, so the socket is root-owned. Control commands must also use root.

### 18.4 Why `runit`

Yggdrasil needs root here to create and manage a TUN interface and routing state.

`runit` provides service control:

```text
run
finish
restart
status
```

This provides supervision when a root daemon started directly from a boot script would run without it.

### 18.5 Why Termux:Boot is still needed

Android does not automatically launch Termux's `runsvdir` after a device reboot.

Termux:Boot supplies the Android boot trigger.

`10-services.sh` starts `termux-services`. That starts `runsvdir`, which supervises Yggdrasil.

### 18.6 Why routing lives in `run`/`finish`

Some existing Android guides place Yggdrasil routing in a separate Termux:Boot script.

This guide ties routing to the interface lifecycle:

```text
service up
-> create route state

service down
-> remove route state
```

`sv down yggdrasil` removes the interface and its policy rule without a reboot.

### 18.7 Why only rule 1000 is used

Existing examples commonly add both source- and destination-based RPDB rules.

This setup was tested without rule `999`.

Outbound route selection still chose:

```text
table 200
dev ygg0
src <YGG_IP>
```

and real outbound TCP worked.

Inbound TCP was tested with the firewall temporarily absent. The phone sent the correct SYN-ACK through `ygg0` with only rule `1000`.

This setup did not need rule `999`, so it was removed.

### 18.8 Why the firewall lives in run

Applying rules without duplicates before each daemon start covers boot, starts from a login and runit restarts. Earlier, login could start Yggdrasil without running the separate boot firewall script.

The service now applies the kernel rules once at startup. It needs no extra supervised firewall process. Rules remain after the daemon stops. [Firewall and AFWall+](#11-firewall).

### 18.9 Why the firewall uses conntrack

Blocking all incoming Yggdrasil traffic without state tracking would also block replies to the phone's connections.

`conntrack` distinguishes:

```text
NEW
ESTABLISHED
RELATED
INVALID
```

This allows replies while blocking unsolicited inbound connections.

### 18.10 Why Android firewall chains are not flushed

Android manages its own Netfilter chains.

The Yggdrasil rules are appended to `INPUT` and match only:

```text
-i ygg0
```

The guide leaves the rest of Android's firewall layout unchanged.

---

## 19. Updating Yggdrasil

The VPN/physical ULA handler is Bash code in `run`. It needs no extra Yggdrasil source patch or build flag. Keep it when updating binaries. Review the separate peer socket patch for each new upstream release.

Check [upstream releases and release notes](https://github.com/yggdrasil-network/yggdrasil-go/releases) for the required Go version, configuration changes and peer/protocol compatibility. Choose a stable release tag. The examples use the placeholder `vX.Y.Z`. They do not claim that an unreleased or untested version is compatible.

Use instructions for your installed profile:

- `main` builds upstream Yggdrasil.
- `webrtc-vpn-compat` adds the runit ULA handler.
- `direct-vpn-bypass` also patches outgoing TCP-based and QUIC/UDP peer sockets.
- `ultimate` keeps that patch and extends the ULA handler to IPv4-only physical Internet.

Installing an upstream binary over a direct build removes the socket patch. [Transport contract](../DIRECT-TRANSPORT.md).

A normal update builds in a separate directory, validates the existing configuration and saves a rollback copy. It then replaces **both** `yggdrasil` and `yggdrasilctl`.

Keep the configuration, private key, `Peers`, `MulticastInterfaces`, `IfName`, `AdminListen`, service/boot scripts and firewall. Do not run `-genconf`. Keeping the key keeps the node address. A normal binary-only update needs no full reinstall or reboot.

Run all stages in the same Termux shell as the normal user. Save the printed source and backup paths. If you open a new shell, set `ygg_update_dir` and `ygg_backup_dir` to those paths again. Stop if any command fails. Do not continue to installation.

### 19.1 Clone the selected release into a fresh directory

Replace `vX.Y.Z` before running this block. A fresh directory keeps earlier source trees and backups intact.

```sh
ygg_release='vX.Y.Z'
ygg_update_dir=$(mktemp -d "$HOME/yggdrasil-source.XXXXXX")
printf 'Source: %s\n' "$ygg_update_dir"
git clone --depth 1 --branch "$ygg_release" https://github.com/yggdrasil-network/yggdrasil-go.git "$ygg_update_dir"
```

### 19.2 Build and check the Android binaries

Check the selected release's build instructions and Go requirement. The commands below use this guide's Android PIE build and the linker workaround for v0.5.14. A future release may need different flags.

Build in Termux with `GOOS=android`, the phone's `GOARCH` and `CGO_ENABLED=1`. A generic Linux/arm64 release binary is not equivalent.

Review the patch against the selected release before building. It was tested on **v0.5.14**. A successful `git apply --check` means the patch fits the text. It does not prove correct routing behavior.

If the check fails, adapt and review the patch or keep the working version. Do not force a failed patch. An unpatched binary cannot preserve this VPN bypass. If upstream adds equivalent behavior, review it before removing the local patch.

This example uses the patch from the guide's `ultimate` checkout. It labels the build with the actual upstream version plus `-direct.local`:

```sh
ygg_patch="$HOME/yggdrasil-android-guide/patches/android-peer-vpn-bypass.patch"
git -C "$ygg_update_dir" apply --check "$ygg_patch" &&
git -C "$ygg_update_dir" apply "$ygg_patch" &&
(cd "$ygg_update_dir" && PKGVER="${ygg_release#v}-direct.local" ./build -p -l "-checklinkname=0")
```

The suffix labels a local build. It does not prove VPN bypass.

Check both binaries before stopping the running daemon:

```sh
"$ygg_update_dir/yggdrasil" -version
go version -m "$ygg_update_dir/yggdrasil"
go version -m "$ygg_update_dir/yggdrasilctl"
```

Confirm the intended version, `GOOS=android`, the phone's architecture and `CGO_ENABLED=1`. The tested device used arm64. Build or metadata failures leave the current installation running.

### 19.3 Save a private rollback copy and validate the existing configuration

```sh
ygg_backup_dir=$(mktemp -d "$HOME/yggdrasil-backup.XXXXXX")
printf 'Backup: %s\n' "$ygg_backup_dir"
cp -p "$PREFIX/bin/yggdrasil" "$ygg_backup_dir/yggdrasil" &&
cp -p "$PREFIX/bin/yggdrasilctl" "$ygg_backup_dir/yggdrasilctl" &&
cp -p "$PREFIX/etc/yggdrasil.conf" "$ygg_backup_dir/yggdrasil.conf" &&
chmod 600 "$ygg_backup_dir/yggdrasil.conf"
```

`mktemp -d` creates a private directory. Never publish its configuration or key. Keep the backup until the new version is known to work.

Parse the installed configuration with the candidate binary. Compare its derived node address with the installed binary's result:

```sh
"$ygg_update_dir/yggdrasil" -useconffile "$PREFIX/etc/yggdrasil.conf" -normaliseconf >/dev/null &&
"$PREFIX/bin/yggdrasil" -useconffile "$PREFIX/etc/yggdrasil.conf" -address > "$ygg_backup_dir/address.before" &&
"$ygg_update_dir/yggdrasil" -useconffile "$PREFIX/etc/yggdrasil.conf" -address > "$ygg_backup_dir/address.candidate" &&
cmp "$ygg_backup_dir/address.before" "$ygg_backup_dir/address.candidate" &&
echo CONFIG_OK
```

Continue only after `CONFIG_OK`. The command discards normalized output and keeps the installed config unchanged. If release notes require a config change, back it up first. Make the change and validate again. Address comparison checks identity, not every future config behavior.

### 19.4 Replace only the two binaries

This interrupts Yggdrasil briefly. Other Termux services remain running.

```sh
sv -w 25 down yggdrasil &&
install -m 755 "$ygg_update_dir/yggdrasil" "$PREFIX/bin/yggdrasil" &&
install -m 755 "$ygg_update_dir/yggdrasilctl" "$PREFIX/bin/yggdrasilctl" &&
sv -w 25 up yggdrasil
```

The chained commands stop on failure. If installation fails after the service stops, restore **both** old binaries with section 19.6. This manual update does not roll back automatically.

### 19.5 Verify before keeping the update

```sh
sv status yggdrasil
"$PREFIX/bin/yggdrasil" -version
su -c "$PREFIX/bin/yggdrasilctl -endpoint=unix://$PREFIX/tmp/yggdrasil.sock getSelf"
su -c "$PREFIX/bin/yggdrasilctl -endpoint=unix://$PREFIX/tmp/yggdrasil.sock getPeers"
su -c "$PREFIX/bin/ip -6 addr show dev ygg0"
su -c "$PREFIX/bin/ip -6 rule show"
su -c "$PREFIX/bin/ip -6 route show table 200"
su -c '/system/bin/ip6tables -S INPUT'
curl -6 --noproxy '*' --max-time 15 -I 'http://[324:71e:281a:9ed3::ace]/'
```

Allow time for peers to reconnect. Check:

- The original native node address and working peers.
- `ygg0`, rule `1000` and the `200::/7` route in table `200`.
- The three firewall rules and real overlay connectivity.

The public HTTP endpoint may become unavailable. If multicast is enabled and a compatible router is on Wi-Fi, check that the local TLS peer returns too.

For v3, check `fd43:<node low 112 bits>/128` on an eligible IPv4-only VPN TUN. Check `fd42:<same bits>/128` on the current IPv4-only physical Internet interface. A native dual-stack interface needs no extra ULA. For the usual `tun0`:

```sh
su -c "$PREFIX/bin/ip -6 addr show dev tun0"
```

If the VPN uses another `tunN` name, inspect it instead. Find the primary physical interface with `ip -4 route get 1.1.1.1 mark 0x20000`. Inspect its addresses too. The handler stays in the existing runit script.

With the VPN active, inspect the **public outgoing peer** sockets (TCP and UDP):

```sh
su -c "$PREFIX/bin/ss -tnep"
su -c "$PREFIX/bin/ss -ulnep"
```

The socket marks must include Android's `protectedFromVpn` bit (`0x20000`). Tested public sockets show `fwmark:0x20000`. TCP source addresses must belong to the physical network.

QUIC UDP sockets may appear as unconnected/wildcard sockets in `ss`. Use a bounded packet capture to prove their physical path. A version suffix or route lookup alone does not prove bypass. Check that applications requiring the VPN still use its address.

After changing versions, verify public-peer traffic outside the VPN, Wi-Fi/mobile reconnection and a call with the VPN active. Keep the backup until those checks pass.

### 19.6 Roll back if the new version fails

In a new shell, set `ygg_backup_dir` to the saved path first. Then restore both binaries:

```sh
sv -w 25 down yggdrasil &&
install -m 755 "$ygg_backup_dir/yggdrasil" "$PREFIX/bin/yggdrasil" &&
install -m 755 "$ygg_backup_dir/yggdrasilctl" "$PREFIX/bin/yggdrasilctl" &&
sv -w 25 up yggdrasil
```

A normal update leaves the configuration unchanged. If you edited it for the new release, restore the saved config too:

```sh
sv -w 25 down yggdrasil &&
install -m 600 "$ygg_backup_dir/yggdrasil.conf" "$PREFIX/etc/yggdrasil.conf" &&
sv -w 25 up yggdrasil
```

Repeat section 19.5 checks with the restored version. Keep source and backup directories until you no longer need rollback. Remove only the directories you recorded. Do not delete an older backup while preparing the next update.

---

## 20. Removing the setup

Follow these steps to remove Yggdrasil but keep Termux and `termux-services`.

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

### 20.3 Remove obsolete boot/state files

```sh
rm -f "$HOME/.termux/boot/05-ygg-firewall.sh"
```

The firewall boot script exists only on older installations. Keep `10-services.sh` if you use other Termux services. Otherwise, remove it too.

After the root session has fully stopped, you may remove the stale `$PREFIX/var/run/yggdrasil-root` record. Logs stay under `$PREFIX/var/log/sv/yggdrasil/` for diagnosis. Remove them only if no longer needed.

The shared wake lock remains. Release it with `termux-wake-unlock` only if no other Termux service needs it.

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

Delete the config only if you no longer want the same Yggdrasil identity:

```sh
rm -f "$PREFIX/etc/yggdrasil.conf"
```

Back up this file if you may reinstall and want to keep the same address.

---

## 21. Sources and acknowledgements

This guide draws on upstream documentation, existing Android/Termux approaches and tests of the final configuration.

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

The final configuration does **not** copy either guide word for word.

The main differences are:

- native Android/cgo build;
- fixed `ygg0`;
- UNIX admin socket;
- routing tied to `runit` lifecycle;
- event-driven VPN and physical Internet ULA restoration inside the same service;
- only destination rule `1000`, without source rule `999`;
- stateful `ip6tables` protection on `ygg0`;
- firewall applied in `run` before every daemon start;
- no custom `dnsmasq`;
- reboot checks compare boot startup with login startup (v2 passed; v3 pending);
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
│   └── 10-services.sh
│
├── runit
│   └── yggdrasil service
│       ├── root-session takeover + routing/firewall setup
│       ├── Yggdrasil daemon
│       ├── VPN/physical link/address/route/rule handler
│       └── svlogd (bounded service logs)
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

The setup uses no Android VPN API, custom DNS daemon or extra overlay-routing wrapper.

It uses native Yggdrasil, Android TUN, policy routing, `runit`, an event-driven VPN/physical compatibility handler and a small stateful firewall.

## License

GPL-3.0-or-later — see [LICENSE](../LICENSE).
