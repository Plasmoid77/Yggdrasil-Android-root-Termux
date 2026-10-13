# Yggdrasil on rooted Android via Termux - Full Guide

[Project overview](../README.md) · [Quick setup](../QUICKSTART.md)

Native Yggdrasil node on rooted Android without the Android VPN API.

The goal of this guide is to run the regular Yggdrasil userspace router directly on Android, create a real `ygg0` TUN interface, route only the Yggdrasil address space through it, supervise the daemon with `runit`, start the service supervisor after reboot with Termux:Boot and apply the firewall in `run` before starting Yggdrasil, and preserve Android's existing Internet/VPN routing policy.

The `ultimate` branch combines direct peer transport with one event-driven ULA handler for IPv4-only VPNs and the current physical Internet interface. v3 derives two different ULAs from the node identity: `fd43:` for the VPN and `fd42:` for the primary physical uplink. Firewall setup, previous-session takeover, batched Netlink handling and bounded logs are part of the same runit service. See [section 10.3](#103-android-vpn--webrtcvoip-compatibility) for the implementation, interface selection and tested limits.

This branch also builds Yggdrasil v0.5.14 with a small socket patch for outgoing TCP-based and QUIC peers. Peer transport stays outside the Android VPN, while Android chooses Wi-Fi or mobile data. Other applications keep their existing VPN policy. No extra switching service is needed. [Transport details and measured results](../DIRECT-TRANSPORT.md).

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

Outgoing TCP-based and QUIC/UDP peer sockets carry Android's `protectedFromVpn` bit (`SO_MARK=0x20000`). Only those sockets bypass the VPN. Android selects the physical network for public peers; they are not bound to fixed Wi-Fi or mobile interface names. Local multicast discovery is limited separately to Wi-Fi interfaces named `wlanN`.

The service maintains node-derived `fd43:` VPN and `fd42:` primary physical /128 helpers on eligible IPv4-only interfaces. It preserves existing global-scope IPv6 and uses batched Netlink events without a polling timer. Primary selection excluded IMS and hotspot downstream on the tested phone. See section 10.3.

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

The service applies the firewall before each daemon start, including starts triggered by a login shell. Automatic restart requires a live supervisor; see [previous-session takeover](#94-previous-session-takeover).

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
- the separate **Termux:Boot Android app**, installed and activated as described below.

> **Required for automatic startup after reboot:** install Termux:Boot as an Android app and **open its launcher icon once**. Opening Termux does not activate Termux:Boot, and `pkg` does not install the Android app. [Official instructions](https://github.com/termux/termux-boot#how-to-use).

The following sections create the single `10-services.sh` boot script and enable the service. Complete [firewall setup](#11-firewall), [Termux:Boot setup](#12-autostart-with-termuxboot) and [first launch](#13-first-launch) before the reboot check. With those steps complete, you do not need to open Termux after every reboot.

Install Termux and Termux:Boot from the same signing source: F-Droid with F-Droid, or the official GitHub releases with GitHub. Mixing them can produce an "unknown error" because their shared Android UID requires matching APK signatures. See [Termux installation requirements](https://github.com/termux/termux-app#installation).

This guide assumes root is already configured and working.

### 3.1 Optional Android child process restrictions

Android 12+ can kill Termux child processes through the phantom process killer; low-memory killing and ROM-specific background restrictions can also remove the supervisor. In the observed Android 16 incident, both `runsvdir` and `runsv yggdrasil` were killed while the root Yggdrasil session survived. The next login restored supervision. v3 handles that surviving session before touching its network state; it cannot restart a dead supervisor by itself. [Takeover details](#94-previous-session-takeover).

Disabling phantom process monitoring is **optional**. It changes a system-wide restriction for **all apps**, allowing more child processes and potentially more resource use; it does not prevent every type of process killing. Keeping the default is supported, with the temporary loss of restart protection described above.

On Android 14+, Developer options may offer **Disable child process restrictions**. Turning it on disables this monitor. A root command with equivalent monitoring behavior is:

```sh
su -c 'settings get global settings_enable_monitor_phantom_procs'
su -c 'settings put global settings_enable_monitor_phantom_procs false'
```

Record the previous value before changing it. If it was `null`, remove the override to restore it:

```sh
su -c 'settings delete global settings_enable_monitor_phantom_procs'
```

If it was an explicit value, restore that value instead. The UI and command need not write the same storage: AOSP's [Settings controller](https://android.googlesource.com/platform/packages/apps/Settings/+/refs/heads/main/src/com/android/settings/development/PhantomProcessPreferenceController.java) toggles a feature property; [FeatureFlagUtils](https://android.googlesource.com/platform/frameworks/base/+/e4fadcbaec4197204e1f89ef7c9cb989b6afaa89/core/java/android/util/FeatureFlagUtils.java) gives the Global override priority. Restore through the method you used; ROM availability varies.

On Android 12–13, the older alternative raises the phantom-process limit instead of disabling all monitoring:

```sh
su -c 'device_config get activity_manager max_phantom_processes'
su -c 'device_config put activity_manager max_phantom_processes 2147483647'
```

Again record the previous value. Restore it with `device_config put`, or if it was `null`, remove the override:

```sh
su -c 'device_config delete activity_manager max_phantom_processes'
```

System configuration updates can overwrite DeviceConfig values. No global disabling of DeviceConfig synchronization is required by this guide. Some 12L/13 ROMs also support the monitoring flag. See the [AOSP Android 12 phantom process implementation](https://android.googlesource.com/platform/frameworks/base/+/refs/heads/android12-release/services/core/java/com/android/server/am/PhantomProcessList.java).

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

The compiler name may vary with the Termux toolchain. If `LD_PRELOAD` interferes with Go, run the affected command as `env -u LD_PRELOAD go ...`; for the build wrapper use `env -u LD_PRELOAD PKGVER=0.5.14-direct.3 ./build -p -l "-checklinkname=0"`. This is a conditional workaround, not a requirement to change the shell environment globally.

The important point is that this guide builds Yggdrasil as an **Android** binary with **cgo enabled**, not as a generic Linux/arm64 binary.

---

## 5. Build Yggdrasil natively for Android

This guide is pinned to the tested upstream release; the [verification matrix](#evidence-and-limits) distinguishes service revisions and scenarios:

```text
v0.5.14
```

Clone it:

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

Use a fresh source checkout; do not apply the same patch twice. The resulting daemon version should be `0.5.14-direct.3`.

These commands perform three separate steps:

1. `git apply --check` verifies that the patch fits the checked-out source. It changes no files and does not prove that a future release behaves correctly with the patch.
2. `git apply` changes the source files described by the patch. It does not rebuild or change the installed daemon.
3. `./build` compiles the modified source into `yggdrasil` and `yggdrasilctl` in the current directory. Installation happens later in this guide.

In the build command, `PKGVER=0.5.14-direct.3` sets the displayed build version; the suffix does not enable VPN bypass. `-p` selects `-buildmode=pie` for Android, and `-l` passes the following string to the Go linker. See the upstream [v0.5.14 build script](https://github.com/yggdrasil-network/yggdrasil-go/blob/v0.5.14/build). The bypass comes from the source changes, not these build arguments.

Run patching and building as the ordinary Termux user. The installed daemon runs as root through the service so it can set the socket mark. For an existing installation or a future release, use [section 19](#19-updating-yggdrasil) rather than repeating fresh-install commands or generating a new private key.

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

### 5.2 What the patch changes

The [patch](../patches/android-peer-vpn-bypass.patch) is a unified diff against v0.5.14. `diff --git` names each changed file; `@@` marks a changed region. Lines starting with `-` are removed, lines starting with `+` are added, and unchanged context lets Git find the right location. It modifies three source files, with 56 added lines and 7 removed lines.

**`src/core/link_tcp.go` — run socket control on Android.** Upstream selected `getControl` when a peer was bound to a named interface. The patch also selects it for Android with ordinary `Peers`, even when no interface is specified:

```go
if sintf != "" || runtime.GOOS == "android" {
    dialer.Control = l.getControl(sintf)
}
```

The separate interface-selection code still runs only when `sintf` is nonempty. The default configuration does not pin `wlan0` or a mobile interface: Android chooses the physical network for a new connection. TCP, TLS, WS, WSS, SOCKS and SOCKS+TLS share this TCP dialer.

**`src/core/link_tcp_linux.go` — mark the socket before connection.** The callback obtains the socket descriptor through `syscall.RawConn.Control` and, on Android, executes:

```go
unix.SetsockoptInt(int(fd), unix.SOL_SOCKET, unix.SO_MARK, 1<<17)
```

`1<<17` equals `0x20000`, the `protectedFromVpn` bit in Android's [Fwmark.h](https://android.googlesource.com/platform/system/netd/+/refs/heads/main/include/Fwmark.h). This is local socket-routing metadata; it is not sent to the peer as a packet field. On the tested rooted phone, Android routes these sockets outside the VPN. If a named interface is explicitly requested, `BindToDevice` is still applied after marking. Errors from descriptor access, marking or interface binding are returned to the dialer, so a failed setup does not silently continue through the VPN.

The filename ends in `_linux.go` because Android also uses Go's Linux platform files; `runtime.GOOS == "android"` restricts the new mark to Android. Building a generic Linux binary would skip that Android branch.

**`src/core/link_quic.go` — give QUIC a marked UDP socket.** Upstream's `quic.DialAddr` creates its own UDP socket. On Android the patch instead creates one through `net.ListenConfig`, with the same socket-control callback:

```go
lc := net.ListenConfig{Control: l.tcp.getControl(info.sintf)}
```

It chooses UDP/IPv4 or UDP/IPv6 for the resolved destination, calls `ListenPacket`, then passes the resulting socket to `quic.Dial`. The mark is therefore set before the first QUIC handshake packet. The outgoing stream wrapper stores the owned `packetConn`; failed connection attempts, failed stream creation and stream closure close it. Non-Android QUIC dialing keeps the original `DialAddr` path.

These changes protect outgoing peer transport sockets only. They add no service, polling loop, routing rule or firewall rule. `unix://` is local IPC and needs no IP-routing change. DNS resolution may still use the VPN; for SOCKS the marked connection reaches the proxy, whose onward route is controlled by that proxy. This patch does not change QUIC incoming listeners. See [section 10.4](#104-direct-peer-transport) for coverage and [DIRECT-TRANSPORT](../DIRECT-TRANSPORT.md#all-outgoing-peer-transports-in-direct3) for the actual tests and their limits.

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

Configure public peers, Wi-Fi multicast discovery, the interface name and the admin socket.

### 6.1 Peers

Yggdrasil does not connect to arbitrary Internet peers automatically. Add public peers to:

```text
Peers: [
]
```

Current public peers are published here:

https://github.com/yggdrasil-network/public-peers

For normal usage, the official public-peers repository recommends **2 or 3 peers**. Prefer peers that are geographically close to you to keep latency down. Using a small set of stable peers also gives redundancy without creating unnecessary distant peerings.

The default example uses TCP IPv4 literals in ordinary `Peers`. TCP, TLS, WS, WSS, SOCKS, SOCKS+TLS and QUIC are all supported by the socket patch; see section 10.4. The following addresses were used for the tests; check current availability before choosing them:

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

Peer availability changes over time. Choose current nearby peers using a supported transport from the public-peers repository. IPv4 literals avoid peer DNS lookups through the VPN. Public peers are not bound to a fixed interface, and Android selects the physical network.

#### Wi-Fi multicast discovery

`MulticastInterfaces` enables Yggdrasil's built-in discovery on Wi-Fi interfaces named `wlanN`. `Beacon: true` advertises this node; `Listen: true` discovers other nodes on the same LAN and connects to them. Discovery uses IPv6 link-local multicast (`ff02::114`, UDP port 9001); the resulting peer connection uses TLS over TCP. `Port: 0` chooses the local TCP port automatically. Keep the regular `Listen: []`: multicast creates its own link-local listener without a general incoming listener.

The Wi-Fi regex limits local discovery; it does not pin the public peers to Wi-Fi. They still use Android's default physical network and remain available over mobile data. No helper service or additional firewall rules are needed. The existing firewall continues to protect traffic arriving through `ygg0`.

On a router running Yggdrasil with compatible LAN multicast enabled, the phone can become a direct LAN peer. The [OpenWrt status module](https://github.com/Plasmoid77/Yggdrasil-OpenWRT/blob/main/source/yggdrasil-status/README.md#behavior) then learns its native `node` address from the router's peer table and maps it to the phone's MAC. Merely connecting to the router's Wi-Fi is insufficient for that field: a local peer connection is required. Wi-Fi client isolation or blocked multicast can prevent discovery. To disable local discovery while retaining public peers, set `MulticastInterfaces: []` and restart Yggdrasil.

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

The complete 276-line v3 `run` is organized into five sections: previous session, routing/firewall, Yggdrasil, helper ULAs and network events. Copy the whole script, including the final `YGG_ROOT` line and `wait` command. [Compatibility details](#103-android-vpn--webrtcvoip-compatibility).

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

The `[y]ggdrasil` expression is intentional. It prevents `pkill -f` from matching the shell command that is executing `pkill` itself.

Make both scripts executable:

```sh
chmod +x "$PREFIX/var/service/yggdrasil/run" "$PREFIX/var/service/yggdrasil/finish"
```

Create the logger and boot integration before enabling the service. The firewall is already in `run` and is applied before Yggdrasil starts.

### 9.3 Service logs

Create the logger and its output directory before enabling the service:

```sh
mkdir -p "$PREFIX/var/service/yggdrasil/log" "$PREFIX/var/log/sv/yggdrasil" "$PREFIX/var/run"
chmod 700 "$PREFIX/var/log/sv/yggdrasil"
nano "$PREFIX/var/service/yggdrasil/log/run"
```

Contents of `log/run` (the standard Termux services logger; `LOGDIR` is supplied by `termux-services`):

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

`s262144` rotates at 262,144 bytes (256 KiB); `n4` retains four rotated files **plus** `current`, approximately 1.25 MiB of log data in normal operation. These are rotation thresholds, not a strict disk quota. See the [svlogd manual](https://smarden.org/runit/svlogd.8).

Yggdrasil stdout/stderr and the helper's `[ULA] Primary uplink`, `Added`, `Removed`, `Setup failed` and `Too many changes` messages go to the same timestamped log:

```sh
tail -n 100 "$PREFIX/var/log/sv/yggdrasil/current"
tail -F "$PREFIX/var/log/sv/yggdrasil/current"
```

Stop following with Ctrl-C. Logs contain network/node addresses; redact them before sharing. An old `current` file alone does not prove the logger is running: check `sv status "$PREFIX/var/service/yggdrasil/log"` and fresh timestamps.

`run` creates `/dev/net/tun` as a symlink to `/dev/tun` only when the path is absent; it preserves an existing path.

### 9.4 Previous-session takeover

The persistent root Bash session writes its PID and Linux process start time to `$PREFIX/var/run/yggdrasil-root`. A later run checks both values before sending TERM to that previous session; a reused PID is not treated as its owner. It waits for cleanup for up to ten seconds **before** changing routing, firewall or `ygg0`. If the old session is still alive, startup exits with an error and the enabled runit service retries.

The root session stops and reaps its Yggdrasil, monitor and worker children; the worker releases owned ULAs. This covers a previous session surviving the loss of its Termux supervisor. `finish` is unchanged: it stops the daemon by configuration path and removes the interface/rule. Use runit for lifecycle operations; do not launch concurrent copies of `run` manually. The state file is a takeover record, not an atomic lock for arbitrary simultaneous launches.

Killing only `runsvdir` leaves existing `runsv` processes able to supervise their services. Killing `runsv` as well removes that protection; SIGKILL cannot run `finish` or shell traps. On the tested rooted phone, the Magisk-spawned root session continued running. A subsequent Termux login or reboot restores the supervisor, and v3 then takes over in the ordered sequence above. Until that trigger, an orphaned Yggdrasil can keep working, but if it fails there is no runit restart. See [background restrictions](#31-optional-android-child-process-restrictions), [runsv](https://smarden.org/runit/runsv.8) and [runsvdir](https://smarden.org/runit/runsvdir.8).

### 9.5 Upgrading an existing service profile

A binary-only update in [section 19](#19-updating-yggdrasil) preserves the service scripts; it does not install v3. To migrate from an older profile, back up `run`, `finish`, boot scripts and any logger/config before replacement. Keep the private Yggdrasil configuration/key and both patched binaries. When coming from an unpatched upstream profile, also build/install the patch and both binaries as described in sections 5 and 19. Check root access and a working supervisor before stopping anything.

Stop the older service through its live supervisor and confirm the daemon/root worker have exited **before** replacing its script: pre-v2 sessions have no PID/start-time takeover record. Install the complete `run`/`finish` blocks above and the logger/config, make the scripts executable, retain `10-services.sh`, and optionally remove the obsolete firewall boot script. Check the outer shell with `sh -n` and the embedded `YGG_ROOT` Bash body separately with `bash -n`; checking only the outer heredoc does not validate its Bash contents.

Resume only if the service was meant to run; preserve its prior disabled/down state otherwise. This is a manual migration with saved rollback files, not an automatic transactional installer. Use the [compatibility checks](#verify-the-installed-service), [logs](#93-service-logs) and [verification matrix](#evidence-and-limits); structural installation success alone does not prove calls or boot autostart.

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

Before adding rule `1000`, `run` removes duplicate copies of that exact `to 200::/7 lookup 200 prio 1000` rule. Failure to add the required rule aborts startup rather than being hidden. Android's other RPDB rules are preserved.

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

This branch uses one event-driven handler for two tested IPv4-only cases: an Android VPN and the phone's physical Internet network. The peer socket patch and the application's IPv6 compatibility are separate layers. Yggdrasil itself can transport its IPv6 overlay over IPv4 peers.

In a failed call, XMPP and Yggdrasil remained reachable, but WebRTC sent only an IPv4 host candidate. It emitted no IPv6 STUN traffic toward the Yggdrasil server. Rule `1000` cannot route packets that the application has not created.

An additional non-link-local IPv6 address on the relevant Internet/VPN interface enabled IPv6 ICE candidates in the successful tests. Putting that address only on `ygg0` or an unrelated dummy interface did not resolve the earlier VPN case. This is an Android/WebRTC compatibility workaround, not general IPv6 Internet service.

#### Addresses and interface selection

| Interface | Address and conditions |
| --- | --- |
| Real UP TUN named `tunN` (TUN bit in `tun_flags`; TAP skipped) | `fd43:<node low 112 bits>/128`, with global-scope IPv4 and no other global-scope IPv6 |
| Primary physical uplink named `rmnet_dataN` or `wlanN` | `fd42:<node low 112 bits>/128`, with the same UP/IPv4/IPv6 conditions |
| Non-primary physical interfaces | Left unchanged; this excluded IMS and hotspot downstream on the tested phone |
| An interface with another global-scope IPv6 address | Existing IPv6 preserved; the handler's own ULA removed if it owns one |

Linux `scope global` includes ULA and does not imply public Internet reachability. Link-local `fe80::` alone does not satisfy the IPv6 condition. Both helpers retain the native node address's low 112 bits and use different first groups, so they are distinct between network types and derived from the key between phones. Do not clone one private key onto multiple phones. A synthetic example:

```text
Yggdrasil: 202:1234:5678:9abc:def0:1234:5678:9abc
Physical:  fd42:1234:5678:9abc:def0:1234:5678:9abc/128
VPN:       fd43:1234:5678:9abc:def0:1234:5678:9abc/128
```

The VPN helper replaces the earlier fixed `fd42::1/128`. Do not use one shared constant on a physical Wi-Fi LAN: duplicate unicast addresses can fail [IPv6 duplicate-address detection](https://www.rfc-editor.org/rfc/rfc4862.html#section-5.4).

A controlled A/B on 2026-10-14 kept the IPv4-only APN and Amnezia VPN unchanged and restarted the messengers before the decisive uniform-address trial. With one node-derived ULA on VPN and physical interfaces, WebRTC gathered **zero IPv6 candidates** and ICE reached FAILED. With different addresses it reached CONNECTED with working audio. The control used the earlier fixed VPN helper; v3 subsequently passed with the node-derived `fd43:` helper. Keep the two-address policy. The proposed ambiguous IP-to-network mapping inside Android/WebRTC is a **hypothesis**, not a proven mechanism or a universal result for all ROMs.

#### What the handler changes

The worker records interface index and original `disable_ipv6`, enables IPv6 only when required, and adds its own /128 with `nodad`. These key-derived addresses skip duplicate-address detection. It adds no Internet default route and does not change the native Yggdrasil identity. Calls still use the overlay address through rule `1000`, table `200`, `ygg0`.

The primary physical uplink is the `dev` returned by:

```sh
ip -4 route get 1.1.1.1 mark 0x20000
```

This kernel lookup sends no packet and performs no DNS query. It uses the protected-from-VPN mark of peer sockets. Only the returned eligible physical interface is considered; there is no semantic IMS/hotspot blacklist. Other naming conventions or ROM routing policies need their own checks.

#### Events and cleanup

The root session subscribes before the initial snapshot:

```sh
ip -o monitor label link address route rule
```

It confirms subscription by matching the monitor's socket inode in `/proc/PID/fd` to a subscribed entry in `/proc/net/netlink`, rather than assuming the Netlink port ID equals the process PID. After a blocking read, `read -t 0` checks for already queued lines. Each batch deduplicates named link/address interfaces and performs at most one primary-uplink refresh for route/rule events. A changed primary also checks the old and new uplinks. There is no periodic timer or extra network-switching daemon.

Replaying a roughly 15-minute event recording reduced primary route lookups from **860 to 52**. This is an offline replay result, not a live syscall count or a measured battery saving. Event handling still forks `ip` for address checks and route lookups; netd policy-rule churn can cause work even when the uplink does not change.

Deletion of an owned ULA triggers restoration. Link down, loss of IPv4, uplink change, another global-scope IPv6 address and orderly shutdown release owned addresses. The saved IPv6 switch is restored only on the same interface index and only if that would not disable another global-scope IPv6 address. A pre-existing address is not claimed or deleted.

At most **four additions per interface in ten seconds** are attempted. Failed additions also consume this limit; there is no separate permanent failure flag. Link down clears the limit, and interface recreation starts a new window. After exhaustion the handler waits for a later network event; expiry of ten seconds alone does not wake it. `[ULA] Too many changes` is logged once per exhausted window.

One persistent root Bash session owns the daemon, monitor and worker. `wait -n` notices child exit, cleanup stops/reaps the rest, and a live runit supervisor restarts the enabled service. Startup waits are bounded; steady-state handling has no polling loop or recurring `dumpsys`. The handler acquires no wake lock; the **boot script's persistent Termux wake lock** is a separate power policy. [Logging](#93-service-logs) · [Supervisor loss and takeover](#94-previous-session-takeover).

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

Expect `fd43:<node low 112 bits>/128`, unless another global-scope IPv6 address is already present. For an IPv4-only physical Internet interface, inspect the `dev` returned by the marked route lookup and expect the node-derived ULA. A native dual-stack interface needs no added ULA.

For the actual Yggdrasil server, verify `dev ygg0`, table `200` and the native source address:

```sh
su -c 'ip -6 route get <YGGDRASIL_SERVER_IPV6>'
```

Then make a new call. A running service, an address in `ip addr` or connected peers alone do not prove that WebRTC gathered IPv6 candidates. During the call, check overlay UDP:

```sh
su -c 'tcpdump -ni ygg0 -tttt -vv udp'
```

Repeat after a VPN reconnect and a Wi-Fi/mobile transition without restarting Yggdrasil. Test reboot separately using sections 15 and 16. Preserve the configuration/key when upgrading from an earlier branch.

#### Evidence and limits

These are recorded results from one rooted LineageOS 23 / Android 16 phone with Yggdrasil 0.5.14-direct.3. v3 is the 276-line service script above; it changes service management, not the peer transport patch.

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

The previous 207-line handler also passed a roughly 95-second mobile/AmneziaWG call on 2026-10-13 with ICE connected in 0.443 s and sustained native Yggdrasil media. Earlier Wi-Fi, QUIC, long-call and reboot results in [DIRECT-TRANSPORT.md](../DIRECT-TRANSPORT.md) used older service profiles; they do not prove every combination was repeated on v3.

Handover checks above used calls **after** each transition; continuous mid-call handover was not established. The handler does not restart ICE or migrate an active call's sockets. Kernel addresses alone do not prove Android `LinkProperties` or ICE candidates. Other ROMs, network names, VPNs and application versions require their own checks. The internal reason for uniform-address candidate suppression remains unproven; see the [WebRTC Android network monitor](https://webrtc.googlesource.com/src/+/refs/heads/main/sdk/android/api/org/webrtc/NetworkMonitorAutoDetect.java).

### 10.4 Direct peer transport

The patch in section 5 sets `SO_MARK=0x20000` on outgoing TCP-based and QUIC/UDP peer sockets on Android. Socket setup errors are returned instead of allowing an unprotected connection. Android's physical-network selection handles Wi-Fi and mobile data without a new supervisor, timer or interface selector. The existing runit scripts need no transport changes.

Verify the actual peer sockets with the VPN connected:

```sh
su -c "$PREFIX/bin/ss -tnep"
su -c "$PREFIX/bin/ss -ulnep"
```

Public outgoing Yggdrasil peer socket marks should include `0x20000`. TCP shows the physical source address; an unconnected QUIC UDP socket may show a wildcard source, so a bounded capture to that peer is needed to establish its actual interface. Applications that require the VPN should still use its address. A route lookup alone does not prove this socket path.

The ULA remains necessary for the tested Conversations/WebRTC context inside an IPv4-only VPN. Its purpose is separate from transporting Yggdrasil peer connections outside the VPN. Calls use the real Yggdrasil address on `ygg0`, not the ULA. Any relay inside Yggdrasil is separate from the phone's Amnezia tunnel.

With the earlier `direct.2` build, Wi-Fi → mobile → Wi-Fi transitions passed without restarting Yggdrasil. Calls were verified separately with Amnezia Premium XRay and AmneziaWG: bidirectional media used `ygg0`, peer TCP transport used physical Wi-Fi, and the other application's VPN connection remained available. A clean reinstall from the previous `direct-vpn-bypass` profile and a full Android reboot also passed: an early Termux:Boot snapshot confirmed automatic service startup, both physical-source marked peer sockets and the restored firewall. Post-reboot checks confirmed routing, overlay HTTP and automatic ULA restoration after the VPN connected. See [transport verification and limits](../DIRECT-TRANSPORT.md).

The `direct.3` build subsequently passed QUIC-only Wi-Fi/mobile handover and a full reboot. Calls with VLESS/Xray, including a Wi-Fi call lasting more than an hour, were reported successful; AmneziaWG was checked for XMPP connectivity on mobile data. The captures did not record call media, and a QUIC-only call with AmneziaWG was not separately confirmed. See [QUIC verification and its limits](../DIRECT-TRANSPORT.md#quic-handover-calls-and-reboot). The temporary tests disabled TCP peers and multicast; normal peer and multicast settings were restored afterward.


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

Only the daemon's outgoing transport sockets get this handling. It does not mark application UDP, all root/Termux traffic or future transports added upstream. UDP calls addressed to Yggdrasil already enter `ygg0` through rule `1000`; the peer transport carries those packets whether the peer uses TCP or QUIC.

For QUIC, the daemon creates the UDP socket with the same Android socket control before passing it to quic-go. Socket-control failures abort the dial; failed handshakes and closed outgoing streams release the owned UDP socket. Non-Android QUIC dialing keeps upstream behavior.

Hostnames can still resolve through the VPN. SOCKS and environment HTTP proxies are intermediary services: the marked local connection does not control how the proxy itself reaches its destination. `unix://` is local and needs no bypass. The default guide keeps regular `Listen: []`; it does not expose public incoming listeners. Preserve the private key and admin socket.

The current `direct.3` build was checked separately with transport/socket tests and a real public QUIC peer with the VPN active. UDP traffic was observed only on physical Wi-Fi; the installed daemon kept its identity, configuration, multicast, routing, firewall and Codex's VPN path. QUIC handover and reboot were subsequently checked on `direct.3` as described above; coverage of the current service script is recorded in the [v3 matrix](#evidence-and-limits). [Detailed evidence and limits](../DIRECT-TRANSPORT.md).

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

### 11.1 Applied by the service

Section 2 of `run` applies the three INPUT rules **before** starting Yggdrasil, on boot, login-triggered startup and service restart. `-w` waits for the xtables lock; `-C || -A` avoids duplicates. If a required rule cannot be applied, startup exits. No separate firewall daemon or netd wait loop is added.

Users upgrading an older installation may delete `~/.termux/boot/05-ygg-firewall.sh`; v3 no longer needs it. Leaving the old script is harmless with these identical, idempotent rules. Only `10-services.sh` is needed for Termux:Boot.

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

`RELATED,ESTABLISHED` and `ESTABLISHED,RELATED` are equivalent sets. Android or another firewall can place earlier rules that change the effective policy; inspect the complete chain and use the [packet/counter tests](#15-verify-the-firewall). The service installs these rules on startup, not continuously after another application rewrites the firewall.

### 11.2 AFWall+

AFWall+'s main UI controls network access per application. Inbound protection for the `ygg0` interface can be repeated in a **shell-capable custom startup script** using the same commands as `run` (already executed as root):

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

The checks make reapplication idempotent. **Compatibility with AFWall+ was not tested on this phone.** Check the rule order after AFWall+ applies its policy. Custom-script handling depends on the AFWall+ version: versions that accept only individual iptables commands reject shell operators such as `||` and redirection, so this shell block cannot be pasted into that parser. Consult its [custom-script documentation](https://github.com/ukanth/afwall/wiki/CustomScripts) for the installed version.

---

## 12. Autostart with Termux:Boot

Termux:Boot executes files inside:

```text
~/.termux/boot/
```

in sorted filename order.

This profile uses only `10-services.sh`, which acquires the Termux wake lock and starts the supervisor. Each service start applies its firewall in `run` before launching Yggdrasil.

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

### 12.3 Manual execution and shell startup

Opening a Termux login shell can start the supervisor through `start-services.sh`; it does not scan `~/.termux/boot/`. In v3 the resulting service start still applies the firewall, because it lives in `run`. Login-triggered success does not prove Termux:Boot worked. [Reboot proof](#161-prove-startup-before-the-first-login).

`10-services.sh` can also be executed manually. This starts the supervisor and acquires the wake lock for the current boot; it does not register a boot trigger. Automatic boot requires the activated Termux:Boot app, the executable script and an enabled service.

### 12.4 Wake lock and battery cost

`termux-wake-lock` is a persistent partial wake lock for the Termux app. It keeps the CPU available with the screen off and can prevent normal suspend, at a battery cost. The event-driven handler's lack of a polling timer does not remove this cost. The extra battery drain was not isolated quantitatively, and reliable calls/background availability without the lock have not been established.

Starting only `start-services.sh` at first installation does not acquire this boot script's lock. Section 13 runs the complete `10-services.sh` so the initial session uses the same policy as boot. `sv down yggdrasil` does not release the shared Termux lock; other Termux services may rely on it. If none do, `termux-wake-unlock` releases it. Do not add that command to `finish` unconditionally. See [Android wake lock guidance](https://developer.android.com/topic/performance/issues/excessive-wakelock).

---

## 13. First launch

Start the supervisor and acquire the same wake lock as the boot path in the current Android session:

```sh
"$HOME/.termux/boot/10-services.sh"
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

This is an **active test** requiring a second Yggdrasil node. Use an already-running SSH listener if available. Otherwise record that the SSH service was down, start it temporarily with `sv up sshd`, and stop it afterwards **only if this test started it**. Do not change an existing service's enable/disable state.

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

If this test started SSH from a confirmed down state, restore that state with `sv down sshd`. Leave a service that was already running alone.

---

## 16. Verify everything after reboot

Reboot Android normally after completing setup. The following is a verification procedure, not a claim that v3 already passed reboot. Do not manually start services before collecting the startup times.

### 16.1 Prove startup before the first login

You cannot inspect the system from a Termux session before opening that session: the login profile can itself start `runsvdir`. After reboot, open the **first** Termux login and run the following read-only comparison immediately, before manual service commands. It reports Linux `/proc/PID/stat` field 22 (start time in ticks since boot) for the supervisor, daemon and currently surviving Termux login shells:

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

Both `runsvdir` and Yggdrasil must have start times **earlier than the first login shell**. Divide ticks by `CLK_TCK` for seconds since boot. In the recorded v2 reboot they started at ~23 s, while the first login started at ~104 s: under this guide's sole boot trigger, that proves Termux:Boot started the service. v3 shares that startup/firewall logic but has not itself been reboot-tested.

The command matches executable paths in the command line because Android process names can be truncated. You can inspect process names/arguments with `ps -eo pid,ppid,args`. If your shell uses another login convention, identify the first login PID there and read its stat with the same method. If the first login already exited, no login matches, the service was restarted, or another boot trigger exists, the snapshot cannot establish Termux:Boot attribution. Repeat the controlled check or use an independent early-boot observer. Merely finding a running service after login is not boot proof.

### 16.2 State and connectivity after boot

Then repeat the process, interface, routing, admin and application checks in [section 14](#14-verify-yggdrasil-and-routing), the [firewall checks](#15-verify-the-firewall), and the compatibility checks below. Confirm the enabled service has a live supervisor and fresh service logs. The HTTP example is optional; also test your actual application endpoint, since a public endpoint may be unavailable independently of Yggdrasil.

### 16.3 Direct transport and VPN compatibility

With the VPN connected, inspect both TCP and UDP sockets and discover the actual VPN TUN and marked physical uplink:

```sh
yggdrasil -version
su -c "$PREFIX/bin/ss -tnep"
su -c "$PREFIX/bin/ss -ulnep"
su -c 'ip -br addr'
su -c 'ip -4 route get 1.1.1.1 mark 0x20000'
```

Check `0.5.14-direct.3` and the public outgoing peer mark `0x20000`. TCP shows its physical source; wildcard QUIC UDP sockets require a bounded capture to the selected peer to prove their actual physical path. An `up` peer alone is not application readiness.

For the actual interface names found above (these are examples):

```sh
su -c 'ip -6 -o addr show dev tun0 scope global'
su -c 'ip -6 -o addr show dev rmnet_data0 scope global'
```

Eligible IPv4-only VPN TUNs should carry `fd43:<node low 112 bits>/128`; the primary physical interface should carry `fd42:<same bits>/128`. Networks with another global-scope IPv6 address need no owned ULA. Confirm an application requiring the VPN still uses it, and make a fresh call for ICE/audio verification. Keep the proof of pre-login startup separate from these state/connectivity checks.

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

The firewall rules remain installed. They simply do not match while `ygg0` does not exist. The shared Termux wake lock also remains; release it only if no other service needs it. [Power policy](#124-wake-lock-and-battery-cost).

Stopping Yggdrasil removes ULA addresses added by this handler and restores the saved IPv6 flag where safe. A pre-existing address that it did not add is left unchanged. Restarting recreates eligible ULA addresses; existing native IPv6 is preserved.

### Start

```sh
sv up yggdrasil
```

The service takes over any recorded previous session, checks the firewall, and recreates:

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

### 18.8 Why the firewall lives in run

Applying the idempotent rules before each daemon start covers boot, login-triggered startup and runit restart. It closes the earlier gap where a login could start Yggdrasil without executing a separate boot firewall script. This is one-shot kernel setup inside the service; no additional supervised firewall process is needed. Rules remain after the daemon stops. [Firewall and AFWall+](#11-firewall).

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

The VPN/physical ULA handler is Bash code in `run`; it requires no additional Yggdrasil source patch or build flag. Keep it when updating the binaries. The separate peer socket patch still needs review against each selected upstream release.

Check [upstream releases and release notes](https://github.com/yggdrasil-network/yggdrasil-go/releases), including the required Go version, configuration changes and peer/protocol compatibility. Choose a stable release tag deliberately; the examples below use the placeholder `vX.Y.Z`. They do not claim that an unreleased or untested version is compatible.

Use the instructions for your installed profile. `main` builds upstream Yggdrasil; `webrtc-vpn-compat` adds the runit ULA handler; `direct-vpn-bypass` also patches outgoing TCP-based and QUIC/UDP peer sockets; `ultimate` retains that patch and extends the common ULA handler to an IPv4-only physical Internet interface. An upstream binary installed over a direct build removes that socket patch. [Transport contract](../DIRECT-TRANSPORT.md).

A normal update builds separately, validates the existing configuration, saves a rollback copy, then replaces **both** `yggdrasil` and `yggdrasilctl`. Keep the configuration, private key, `Peers`, `MulticastInterfaces`, `IfName`, `AdminListen`, service/boot scripts and firewall. Do not run `-genconf`: preserving the key preserves the node address. No full reinstall or reboot is needed for a normal binary-only update.

Run the following stages in the same Termux shell, as its normal user. Save the printed source and backup paths; in a new shell, set `ygg_update_dir` and `ygg_backup_dir` to those paths again. If any command fails, stop at that stage; do not continue to installation.

### 19.1 Clone the selected release into a fresh directory

Replace `vX.Y.Z` before running this block. A fresh directory preserves earlier source trees and backups.

```sh
ygg_release='vX.Y.Z'
ygg_update_dir=$(mktemp -d "$HOME/yggdrasil-source.XXXXXX")
printf 'Source: %s\n' "$ygg_update_dir"
git clone --depth 1 --branch "$ygg_release" https://github.com/yggdrasil-network/yggdrasil-go.git "$ygg_update_dir"
```

### 19.2 Build and check the Android binaries

Check the selected release's build instructions and Go requirement. The commands below retain this guide's Android PIE build and the linker workaround used for v0.5.14; a future release may need different flags. Build in Termux with `GOOS=android`, the phone's `GOARCH` and `CGO_ENABLED=1`. A generic Linux/arm64 release binary is not this Android build.

Before building, review the patch against the selected release. The supplied patch was tested on **v0.5.14**. Successful `git apply --check` only proves textual applicability; it does not prove the routing behavior remains correct. If it fails, adapt and review the patch for that release or keep the working version. Do not force a failed patch or fall back to an unpatched binary to retain VPN bypass. If upstream later implements equivalent behavior, review that implementation before deciding whether the local patch is still needed.

The example uses the patch from this guide's `ultimate` checkout and labels the candidate with its actual upstream version plus `-direct.local`:

```sh
ygg_patch="$HOME/yggdrasil-android-guide/patches/android-peer-vpn-bypass.patch"
git -C "$ygg_update_dir" apply --check "$ygg_patch" &&
git -C "$ygg_update_dir" apply "$ygg_patch" &&
(cd "$ygg_update_dir" && PKGVER="${ygg_release#v}-direct.local" ./build -p -l "-checklinkname=0")
```

The suffix identifies a local build; it is not proof of VPN bypass.

Check both binaries before stopping the running daemon:

```sh
"$ygg_update_dir/yggdrasil" -version
go version -m "$ygg_update_dir/yggdrasil"
go version -m "$ygg_update_dir/yggdrasilctl"
```

Confirm the intended version, `GOOS=android`, the phone's architecture (arm64 on the tested device) and `CGO_ENABLED=1`. Build/metadata failures leave the current installation running.

### 19.3 Save a private rollback copy and validate the existing configuration

```sh
ygg_backup_dir=$(mktemp -d "$HOME/yggdrasil-backup.XXXXXX")
printf 'Backup: %s\n' "$ygg_backup_dir"
cp -p "$PREFIX/bin/yggdrasil" "$ygg_backup_dir/yggdrasil" &&
cp -p "$PREFIX/bin/yggdrasilctl" "$ygg_backup_dir/yggdrasilctl" &&
cp -p "$PREFIX/etc/yggdrasil.conf" "$ygg_backup_dir/yggdrasil.conf" &&
chmod 600 "$ygg_backup_dir/yggdrasil.conf"
```

The directory created by `mktemp -d` is private. Never publish its configuration or key. Keep it until the new version is known to work.

Parse the live configuration with the candidate and compare its derived node address with the installed binary's result:

```sh
"$ygg_update_dir/yggdrasil" -useconffile "$PREFIX/etc/yggdrasil.conf" -normaliseconf >/dev/null &&
"$PREFIX/bin/yggdrasil" -useconffile "$PREFIX/etc/yggdrasil.conf" -address > "$ygg_backup_dir/address.before" &&
"$ygg_update_dir/yggdrasil" -useconffile "$PREFIX/etc/yggdrasil.conf" -address > "$ygg_backup_dir/address.candidate" &&
cmp "$ygg_backup_dir/address.before" "$ygg_backup_dir/address.candidate" &&
echo CONFIG_OK
```

Only continue after `CONFIG_OK`. Normalized output is discarded; the installed config is not overwritten. If release notes require a config change, back it up first, make that change deliberately and validate again. Address comparison checks identity, not all future configuration semantics.

### 19.4 Replace only the two binaries

This interrupts Yggdrasil briefly. Other Termux services remain running.

```sh
sv -w 25 down yggdrasil &&
install -m 755 "$ygg_update_dir/yggdrasil" "$PREFIX/bin/yggdrasil" &&
install -m 755 "$ygg_update_dir/yggdrasilctl" "$PREFIX/bin/yggdrasilctl" &&
sv -w 25 up yggdrasil
```

The chained commands stop on failure. If installation fails after the service stops, restore **both** old binaries with section 19.6. This is a manual update, not an automatic rollback script.

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

Allow time for peers to reconnect. Confirm the original native node address, working peers, `ygg0`, rule `1000`, the `200::/7` route in table `200`, the three firewall rules and real overlay connectivity. The public HTTP endpoint is a test target whose availability may change. With multicast enabled and a compatible router on Wi-Fi, check that the local TLS peer returns too.

For v3, verify `fd43:<node low 112 bits>/128` on an eligible IPv4-only VPN TUN and `fd42:<same bits>/128` on the current IPv4-only physical Internet interface. A native dual-stack interface needs no additional ULA. For the usual `tun0`:

```sh
su -c "$PREFIX/bin/ip -6 addr show dev tun0"
```

If the active VPN uses another `tunN` name, inspect that interface instead. Use `ip -4 route get 1.1.1.1 mark 0x20000` to identify the primary physical interface and inspect its addresses too. The handler remains in the existing runit script.

With the VPN active, inspect the **public outgoing peer** sockets (TCP and UDP):

```sh
su -c "$PREFIX/bin/ss -tnep"
su -c "$PREFIX/bin/ss -ulnep"
```

Their marks must include Android's `protectedFromVpn` bit (`0x20000`; the tested public sockets show `fwmark:0x20000`) and TCP source addresses must belong to the physical network. QUIC UDP sockets may appear as unconnected/wildcard sockets in `ss`; use a bounded packet capture to establish their actual physical path. A version suffix or route lookup alone does not prove bypass. Check that applications requiring the VPN still use its address. After an actual version change, verify public-peer traffic outside the VPN, Wi-Fi/mobile reconnection and a call with the VPN active; retain the backup until those checks pass.

### 19.6 Roll back if the new version fails

Set `ygg_backup_dir` to the saved backup path if this is a new shell, then restore both binaries:

```sh
sv -w 25 down yggdrasil &&
install -m 755 "$ygg_backup_dir/yggdrasil" "$PREFIX/bin/yggdrasil" &&
install -m 755 "$ygg_backup_dir/yggdrasilctl" "$PREFIX/bin/yggdrasilctl" &&
sv -w 25 up yggdrasil
```

The normal update never changes the configuration. If you deliberately edited it for the new release, also restore the saved config:

```sh
sv -w 25 down yggdrasil &&
install -m 600 "$ygg_backup_dir/yggdrasil.conf" "$PREFIX/etc/yggdrasil.conf" &&
sv -w 25 up yggdrasil
```

Repeat the checks in section 19.5 with the restored version. Keep the source and backup directories until no rollback is needed; remove only the specific directories you recorded, never an older backup as part of preparing the next update.

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

### 20.3 Remove obsolete boot/state files

```sh
rm -f "$HOME/.termux/boot/05-ygg-firewall.sh"
```

The firewall boot script only exists on older installations. Keep `10-services.sh` if you use other Termux services; otherwise remove it too. After the root session is fully stopped, the stale `$PREFIX/var/run/yggdrasil-root` record may be removed. Logs under `$PREFIX/var/log/sv/yggdrasil/` remain for diagnosis; remove them only if no longer needed. The shared wake lock remains until released with `termux-wake-unlock`; only release it if no other Termux service needs it.

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

The final configuration in this installation guide is **not** a verbatim copy of either guide.

Important differences include:

- native Android/cgo build;
- fixed `ygg0`;
- UNIX admin socket;
- routing tied to `runit` lifecycle;
- event-driven VPN and physical Internet ULA restoration inside the same service;
- only destination rule `1000`, without source rule `999`;
- stateful `ip6tables` protection on `ygg0`;
- firewall applied in `run` before every daemon start;
- no custom `dnsmasq`;
- reboot verification distinguishing pre-login boot startup from login-triggered startup (recorded v2 pass; v3 pending);
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

No Android VPN API. No custom DNS daemon. No additional overlay-routing wrapper.

Just native Yggdrasil, Android TUN, policy routing, `runit`, an event-driven VPN/physical compatibility handler and a small stateful firewall.

## License

GPL-3.0-or-later — see [LICENSE](../LICENSE).
