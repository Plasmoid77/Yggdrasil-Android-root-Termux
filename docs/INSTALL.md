# Yggdrasil on rooted Android via Termux - Full Guide

[Project overview](../README.md) · [Quick setup](../QUICKSTART.md)

Native Yggdrasil node on rooted Android without the Android VPN API.

This guide runs the regular Yggdrasil userspace router directly on Android. It creates a real `ygg0` TUN interface and routes only Yggdrasil addresses through it. `runit` supervises the daemon. Termux:Boot starts the supervisor after reboot. `run` applies the firewall before starting Yggdrasil. Android keeps its existing Internet/VPN routing policy.

The ultimate profile combines direct peer transport with one event-driven ULA handler. The handler supports IPv4-only VPNs and the current physical Internet interface. The service keeps two different ULAs from the node identity: `fd43:` for the VPN and `fd42:` for the primary physical uplink.

The service has four files: `run` owns the root session and daemon, `firewall` loads the inbound trusted list, `ula` handles helper addresses and Netlink events, and `finish` stops the session. The service takes over a previous session and limits log storage. See [section 10.3](#103-android-vpn--webrtcvoip-compatibility) for details, interface selection and tested limits.

This guide builds Yggdrasil v0.5.14 with a small socket patch for outgoing TCP-based and QUIC peers. Peer traffic stays outside the Android VPN. Android chooses Wi-Fi or mobile data. Other applications keep their VPN policy. No extra switching service is needed. [Transport details](../DIRECT-TRANSPORT.md).

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
   - [Automatic installation](#automatic-installation)
4. [Prepare Termux](#4-prepare-termux)
5. [Build Yggdrasil natively for Android](#5-build-yggdrasil-natively-for-android)
6. [Create the Yggdrasil configuration](#6-create-the-yggdrasil-configuration)
7. [Install binaries and configuration](#7-install-binaries-and-configuration)
8. [Final filesystem layout](#8-final-filesystem-layout)
9. [Create the runit service](#9-create-the-runit-service)
    - [Full service files](#91-run), [finish](#92-finish) and [logger](#93-service-logs)
    - [Previous-session takeover](#94-previous-session-takeover)
10. [Policy routing](#10-policy-routing)
    - [Android VPN + WebRTC/VoIP compatibility](#103-android-vpn--webrtcvoip-compatibility)
    - [Direct peer transport](#104-direct-peer-transport)
11. [Firewall](#11-firewall)
    - [AFWall+](#112-afwall)
    - [Allow a device / example: Syncthing](#113-allow-a-device--example-syncthing)
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
trusted sources     -> ACCEPT
everything else     -> DROP
```

The service applies the firewall before each daemon start, including starts from a login shell. Automatic restart needs a live supervisor. See [previous-session takeover](#94-previous-session-takeover).

---

## 2. Architecture

The final setup looks like this:

```text
Android boot
└── Termux:Boot
    └── 10-services.sh → wake lock + runit
        └── yggdrasil service
            ├── run → one persistent root Bash session
            │   ├── previous-session takeover
            │   ├── deduplicates rule 1000 → table 200
            │   ├── firewall → YGG_IN + trusted list
            │   ├── Yggdrasil → ygg0 + 200::/7 route in table 200
            │   └── ula → monitor + worker, batched Netlink events
            │       └── distinct key-derived VPN/physical helpers
            ├── finish → stop root session by PID + start time
            │   └── fallbacks: daemon, ygg0, rule 1000
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

If `runsvdir` and `runsv yggdrasil` are killed, the root Yggdrasil session can survive. A Termux login can restore supervision. The service handles a surviving session before changing its network state. It cannot restart a dead supervisor itself. [Takeover details](#94-previous-session-takeover).

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

## Automatic installation

The installer keeps existing settings, backs up files it replaces, and installs this service.

Complete the requirements above, including opening the Termux:Boot app once. Install `git` if needed (`pkg install git`), clone the guide, then run the installer as the normal Termux user:

```sh
git clone --depth 1 --branch ultimate https://github.com/Plasmoid77/Yggdrasil-Android-root-Termux.git ~/yggdrasil-android-guide
bash ~/yggdrasil-android-guide/install.sh
```

Run as the normal Termux user. Repeat `--peer URI` to set peers for a **new** configuration; replace the example URIs with current public peers:

```sh
bash ~/yggdrasil-android-guide/install.sh --peer tcp://192.0.2.10:12345 --peer quic://192.0.2.20:12345
```

These are documentation addresses, not working peers. Without `--peer`, a new node connects only to Wi-Fi multicast neighbours until you add public peers. Existing configurations and their peers are kept; `--peer` does not edit them. Use `--rebuild` to build again even when version `0.5.14-direct.3` is already installed. `--help` shows usage.

**Code is replaced; settings are created only when missing.** The installer backs up only files it replaces under `~/yggdrasil-backup-<time>/` (mode 700), mirroring `usr/`. It never copies `yggdrasil.conf` into this backup. Existing settings are kept; missing settings are created. No backup is made when nothing is replaced.

It is safe to run the installer again: unchanged files are left alone, changed code files are replaced with the service stopped first and started again, and settings are never overwritten. Each run reloads `YGG_IN`, resetting packet counters.

The installer was tested in a fake environment. It has **not yet run on a clean phone**.

The installer uses `files/` and `patches/` beside `install.sh`. It writes under the current `$PREFIX` and `$HOME`. The installed service files use the standard Termux paths shown in section 9.

It follows these steps:

1. **Checks.** Require a non-root Termux user, working `su` and a clone containing `files/` and `patches/`. Warn about Termux:Boot and a nonstandard `$PREFIX`; the service scripts use standard Termux paths.
2. **Packages.** Install only missing tools, including `root-repo`; no full upgrade.
3. **Binaries.** Skip the build if `0.5.14-direct.3` and an executable `yggdrasilctl` are installed, unless `--rebuild` is given. Otherwise clone v0.5.14, verify commit `422836eeb21a99790caa286aa63d493bbc4766d7`, apply the patch and build with `GOFLAGS=-p=2` to reduce parallel processes under Android's limit. Check the resulting version.
4. **Configuration.** Never change, print or copy an existing `yggdrasil.conf`. Require `IfName: ygg0`; warn about `AdminListen`. For a new node, generate JSON (valid HJSON) with `ygg0`, the admin socket, `--peer` values, no listening endpoints and Wi-Fi multicast. Keep a private copy of this new file: it contains the node's private key and is not in any installer backup.
5. **Supervisor.** Start runit if needed with a wake lock and `start-services.sh`, without running the user's boot script.
6. **Install files.** Publish a new service directory atomically with `down` and `log/` already inside. If any code differs (binaries, `run`, `finish`, `ula`, `firewall`, `log/run`), first create `down` and stop the service with `sv -w 45 down`. Back up replaced files to `~/yggdrasil-backup-<time>/`, then replace each by atomic rename, `run` last. Create config, trusted list, log settings and `10-services.sh` only when missing.
7. **Start.** Run `firewall`, remove `down` and run `sv -w 45 up yggdrasil`. The service is enabled afterwards. An unchanged running service is left running.
8. **Verify.** For about 45 seconds (command waits can extend this), check for the service running for at least ten seconds, the node address on `ygg0`, rule 1000 and exactly one `YGG_IN` jump. Print the node address, peers up, backup path and next steps.

If installation or verification fails after code replacement, the service stays stopped with `down`. Re-run the installer to complete installation.

The installer does not edit existing peers or trusted devices. Add peers in `$PREFIX/etc/yggdrasil.conf`, then restart Yggdrasil. Add trusted devices in `$PREFIX/etc/yggdrasil-trusted`, then run `firewall` without a daemon restart.

The manual steps below provide the same service files and explain each part.

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

The compiler name may vary with the Termux toolchain. If `LD_PRELOAD` interferes with Go, use `env -u LD_PRELOAD go ...` for the affected command. For the build wrapper, use `env -u LD_PRELOAD GOFLAGS=-p=2 PKGVER=0.5.14-direct.3 ./build -p -l "-checklinkname=0"`. Use this workaround only when needed. You do not need to change the shell environment globally.

Build an **Android** binary with **cgo enabled**. A generic Linux/arm64 binary is not suitable for this guide.

---

## 5. Build Yggdrasil natively for Android

This guide uses a fixed upstream release. See [checks and limits](#evidence-and-limits) for what has been verified with these files:

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
GOFLAGS=-p=2 PKGVER=0.5.14-direct.3 ./build -p -l "-checklinkname=0"
```

Use fresh source and apply the patch only once. The daemon version should be `0.5.14-direct.3`.

These commands perform three separate steps:

1. `git apply --check` checks whether the patch fits the source. It changes no files. It does not prove that the patch works correctly on a future release.
2. `git apply` changes the source files listed in the patch. It does not rebuild or change the installed daemon.
3. `./build` builds `yggdrasil` and `yggdrasilctl` in the current directory. You install them later.

`GOFLAGS=-p=2` limits parallel compiler processes, because Android kills apps that start too many. `PKGVER=0.5.14-direct.3` sets the displayed build version. The suffix does not enable VPN bypass. `-p` selects `-buildmode=pie` for Android. `-l` passes the next string to the Go linker. See the upstream [v0.5.14 build script](https://github.com/yggdrasil-network/yggdrasil-go/blob/v0.5.14/build). The source changes provide bypass.

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

The filename ends in `_linux.go` because Android also uses Go's Linux platform files. `runtime.GOOS == "android"` limits the new mark to Android. A generic Linux binary would skip that code path.

**`src/core/link_quic.go` — give QUIC a marked UDP socket.** Upstream's `quic.DialAddr` creates its own UDP socket. On Android, the patch creates one through `net.ListenConfig` with the same socket-control callback:

```go
lc := net.ListenConfig{Control: l.tcp.getControl(info.sintf)}
```

The patch chooses UDP/IPv4 or UDP/IPv6 for the resolved destination. It calls `ListenPacket`, then passes the socket to `quic.Dial`. The mark is set before the first QUIC handshake packet.

The outgoing stream wrapper stores the owned `packetConn`. Failed connections, failed stream creation and stream closure close that socket. Non-Android QUIC dialing keeps the original `DialAddr` path.

These changes protect only outgoing peer transport sockets. They add no service, polling loop, routing rule or firewall rule. `unix://` is local IPC and needs no IP-routing change. DNS may still use the VPN. For SOCKS, the marked connection reaches the proxy. The proxy controls the route from there. The patch does not change incoming QUIC listeners.

See [section 10.4](#104-direct-peer-transport) for coverage and [DIRECT-TRANSPORT](../DIRECT-TRANSPORT.md#verify) for verification.

---

## 6. Create the Yggdrasil configuration

Generate a configuration for the new node:

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

The default example uses TCP IPv4 addresses in ordinary `Peers`. The socket patch supports TCP, TLS, WS, WSS, SOCKS, SOCKS+TLS and QUIC. See section 10.4. Replace the documentation addresses below with current peers; these placeholders are not reachable peers:

```text
Peers: [
  tcp://192.0.2.10:12345
  tcp://192.0.2.20:12345
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
~/yggdrasil-go/yggdrasil -address -useconffile ~/yggdrasil.conf 2>/dev/null ||
echo 'Configuration check failed; review the file locally.' >&2
```

It should return an address from Yggdrasil's `200::/7` range.

The configuration contains the node's cryptographic identity. Keep it to retain the same Yggdrasil address.

### 6.5 Validate the configuration

Run:

```sh
if ~/yggdrasil-go/yggdrasil -useconffile ~/yggdrasil.conf -normaliseconf >/dev/null 2>/dev/null; then
    echo CONFIG_OK
else
    echo 'Configuration check failed; review the file locally.' >&2
fi
```

Expected:

```text
CONFIG_OK
```

This command checks parsing and compatibility. It does not overwrite the configuration.

---

## 7. Install binaries and configuration

Install the binaries and configuration before creating the service below. Apply the firewall before enabling the service in section 13.

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
├── yggdrasil.conf
└── yggdrasil-trusted     # inbound sources; empty/comment-only by default

$PREFIX/var/service/yggdrasil/
├── run
├── firewall
├── ula
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

Prepare the service directory under a hidden name with `down` and `log/` inside, then rename it. runit ignores hidden directories, so it never sees a half-ready service, and `down` keeps it stopped until all files are ready:

```sh
mkdir -p "$PREFIX/var/service/.yggdrasil/log" "$PREFIX/var/run"
touch "$PREFIX/var/service/.yggdrasil/down"
mv "$PREFIX/var/service/.yggdrasil" "$PREFIX/var/service/yggdrasil"
```

The files below are also supplied in the guide's `files/usr/var/service/yggdrasil/` tree. [Quick setup step 6](../QUICKSTART.md#6-create-the-runit-service) copies them from the clone. Keep all four together.

### 9.1 `run`

Save this as `$PREFIX/var/service/yggdrasil/run`. It starts one persistent root Bash session, takes over the recorded previous session, sets routing, calls `firewall`, starts Yggdrasil and waits for its node address. It then starts `ula` and waits for either process to exit. Cleanup stops and reaps both. Copy the full block, including `YGG_ROOT` and the final `wait`.

```sh
#!/data/data/com.termux/files/usr/bin/sh
# Yggdrasil uses ygg0; Android VpnService uses tunN.
# run owns the root session and Yggdrasil; firewall owns inbound ygg0 rules;
# ula keeps helper addresses for Android WebRTC on IPv4-only networks.
# One persistent root Bash session does the following, in this order:
#   1. take over from a previous session left without its supervisor;
#   2. route 200::/7 through table 200 and call firewall;
#   3. run Yggdrasil and wait for its node address;
#   4. start ula, driven by Netlink events without timers;
#   5. wait for Yggdrasil or ula to stop, then clean up both.
# Merge stderr into stdout for runit service output.
exec 2>&1

# Run the following Bash block in one persistent root session.
# Keep the outer shell waitable by runit; finish stops Yggdrasil.
su -c 'exec /data/data/com.termux/files/usr/bin/bash -s' <<'YGG_ROOT' &
P=/data/data/com.termux/files/usr
D=$P/var/service/yggdrasil
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

### 2. Routing ###########################################################

# Send all traffic destined for the Yggdrasil 200::/7 network to routing table 200.
# Remove duplicate copies first so exactly one rule remains.
while ip -6 rule del to 200::/7 lookup 200 prio 1000 2>/dev/null; do :; done
ip -6 rule add to 200::/7 lookup 200 prio 1000 || exit 1

# Accept inbound ygg0 traffic only from trusted addresses (see firewall).
"$D/firewall" || exit 1

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

### 4. Helper ULAs #######################################################

# Keep helper addresses for WebRTC calls (see ula).
"$D/ula" "$node" &
ula_pid=$!
children+=("$ula_pid")

# Exit and clean up if Yggdrasil or the helper stops.
# An enabled runit service can then restart the complete run script.
wait -n "$ygg_pid" "$ula_pid"
YGG_ROOT
# Keep the run script alive for as long as the Yggdrasil process is running.
wait "$!"
```

#### `firewall`

Save this as `$PREFIX/var/service/yggdrasil/firewall`. It elevates itself when run as the normal Termux user. [Trusted-list format and reload](#11-firewall).

```sh
#!/data/data/com.termux/files/usr/bin/bash
# Reload the trusted list without restarting Yggdrasil.
# Inbound ygg0 traffic: replies to our connections and traffic from addresses
# listed in $PREFIX/etc/yggdrasil-trusted pass; everything else is dropped.
# Safe to run again: replace our whole chain in one transaction, with no
# gap that would leave inbound ygg0 traffic open. Leave other chains alone.
D=/data/data/com.termux/files/usr/var/service/yggdrasil
if ((EUID != 0)); then
    exec su -c "exec /data/data/com.termux/files/usr/bin/bash '$D/firewall'"
fi

trusted_file=/data/data/com.termux/files/usr/etc/yggdrasil-trusted
trusted=()
line_number=0
if [[ -f $trusted_file ]]; then
    while IFS= read -r line || [[ -n $line ]]; do
        ((line_number+=1))
        line=${line%$'\r'}
        read -r address _ <<< "$line"
        [[ -z $address || $address == \#* ]] && continue
        [[ $address == */* ]] || address+=/128
        # Accept only the Yggdrasil range 200::/7; ip rejects malformed
        # addresses, so one typo cannot make the whole list fail to load.
        # A prefix shorter than /7 would also cover addresses outside it.
        if [[ ! $address =~ ^[23][0-9a-fA-F]{2}:.*/([0-9]+)$ ]] ||
           ((10#${BASH_REMATCH[1]} < 7)) ||
           ! ip -6 addr show to "$address" >/dev/null 2>&1; then
            echo "[Firewall] Ignored line $line_number: $line"
            continue
        fi
        trusted+=("$address")
    done < "$trusted_file"
fi

# --noflush is required: without it restore would erase Android's filter
# table. This chain declaration creates or clears only our own YGG_IN.
{
    printf '*filter\n:YGG_IN - [0:0]\n'
    printf '%s\n' '-A YGG_IN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT'
    printf '%s\n' '-A YGG_IN -m conntrack --ctstate INVALID -j DROP'
    for address in "${trusted[@]}"; do
        printf '%s\n' "-A YGG_IN -s $address -j ACCEPT"
    done
    printf '%s\n' '-A YGG_IN -j DROP' 'COMMIT'
} | ip6tables-restore --noflush --wait=10 || exit 1

ip6tables -w -C INPUT -i ygg0 -j YGG_IN 2>/dev/null ||
    ip6tables -w -A INPUT -i ygg0 -j YGG_IN || exit 1
echo "[Firewall] Inbound ygg0 traffic allowed from ${#trusted[@]} trusted address(es)"
```

#### `ula`

Save this as `$PREFIX/var/service/yggdrasil/ula`. `run` passes the native node address to this root helper. It batches Netlink events, limits address-add attempts, ignores further stop signals while removing owned addresses and removes this node's stale fd42/fd43 helpers at startup. [Policy and limits](#103-android-vpn--webrtcvoip-compatibility).

```sh
#!/data/data/com.termux/files/usr/bin/bash
# Keep helper ULAs for Android WebRTC, using the node address from run.
[[ $# == 1 && $1 =~ ^[23][0-9a-fA-F]{2}:[0-9a-fA-F:]*$ ]] ||
    { echo 'ERROR: Expected one Yggdrasil node address without /7'; exit 1; }
node=$1
children=()

# Stop and reap all owned child processes when this helper exits.
cleanup() {
    trap - EXIT
    ((${#children[@]})) && kill "${children[@]}" 2>/dev/null
    wait 2>/dev/null || true
}
trap cleanup EXIT
trap 'exit 0' TERM INT HUP

### 1. Helper ULAs for WebRTC ############################################

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

# Start from a clean state: remove our addresses left by a session that was
# killed before it could clean up. Interfaces keep their current IPv6 switch.
while read -r index dev family address rest; do
    [[ $address == "$ula_physical" || $address == "$ula_vpn" ]] || continue
    ip -6 addr del "$address" dev "${dev%%@*}" && echo "[ULA] Removed stale $address from $dev"
done < <(ip -6 -o addr show scope global 2>/dev/null)

### 2. Network events ####################################################

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
    # Ignore further stop signals so removing our addresses always completes.
    trap 'trap "" TERM INT HUP; release_all' EXIT
    trap 'exit 0' TERM INT HUP
    refresh_primary
    for path in /sys/class/net/{tun,rmnet_data,wlan}[0-9]*; do sync_ula "${path##*/}"; done
    declare -A pending=()
    while read -r event <&3; do
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
            read -r event <&3 || break
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

# Exit and clean up if the monitor or the worker stops.
# run will then stop Yggdrasil so runit can restart the service.
wait -n "$monitor_pid" "$worker_pid"
exit 1
```

### 9.2 `finish`

Save this as `$PREFIX/var/service/yggdrasil/finish`. It stops the recorded root session by PID and start time, waits for cleanup, then uses daemon/interface/rule fallbacks. This also works during startup, before the daemon exists.

```sh
#!/data/data/com.termux/files/usr/bin/sh
# Stop the root session started by run. Its cleanup stops Yggdrasil and ula,
# which removes the helper addresses. This also works while run is still
# starting, before Yggdrasil exists.
su -c 'exec /data/data/com.termux/files/usr/bin/bash -s' <<'YGG_ROOT'
P=/data/data/com.termux/files/usr

# The process start time tells the live session apart from a reused PID.
start_time() {
    local stat
    read -r stat 2>/dev/null < "/proc/$1/stat" || return 1
    stat=(${stat##*) })
    printf '%s\n' "${stat[19]}"
}
if read -r pid start 2>/dev/null < "$P/var/run/yggdrasil-root" &&
   [[ $(start_time "$pid") == "$start" ]]; then
    kill "$pid" 2>/dev/null
    for ((attempt=0; attempt<100; attempt++)); do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.1
    done
fi

# Fallbacks for a session that was killed before its own cleanup.
pkill -f '[y]ggdrasil -useconffile /data/data/com.termux/files/usr/etc/yggdrasil.conf' 2>/dev/null
ip link del ygg0 2>/dev/null
# Remove the policy rule that sends the Yggdrasil network to routing table 200.
ip -6 rule del to 200::/7 lookup 200 prio 1000 2>/dev/null
YGG_ROOT
exit 0
```

Set private executable modes after saving all four files:

```sh
chmod 700 "$PREFIX/var/service/yggdrasil/run" "$PREFIX/var/service/yggdrasil/firewall" "$PREFIX/var/service/yggdrasil/ula" "$PREFIX/var/service/yggdrasil/finish"
```

Create the logger, trusted list and boot script before enabling the service. `run` calls `firewall` before starting Yggdrasil.

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

The root session stops and reaps Yggdrasil and `ula`; `ula` stops its monitor and worker. The worker removes ULAs it owns, ignoring further stop signals until removal completes. This handles a session that survived the loss of its Termux supervisor.

`finish` checks the same PID/start-time record and stops the root session, even while `run` is still starting. It waits up to ten seconds, then falls back to stopping the daemon by configuration path and removing the interface/rule. Use runit for service control. Do not launch concurrent copies of `run` manually. The state file records takeover data; it is not an atomic lock for simultaneous launches.

Killing only `runsvdir` leaves existing `runsv` processes supervising their services. Killing `runsv` too removes that protection. SIGKILL cannot run `finish` or shell traps.

A root session started by Magisk can outlive the Termux supervisor. A later Termux login or Termux:Boot can start the supervisor. The service then takes over in the order above. Until then, an orphaned Yggdrasil can keep working, but runit cannot restart it if it fails. See [background restrictions](#31-optional-android-child-process-restrictions), [runsv](https://smarden.org/runit/runsv.8) and [runsvdir](https://smarden.org/runit/runsvdir.8).

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

The `ula` file handles two IPv4-only cases: an Android VPN and the phone's physical Internet network. The peer socket patch handles transport. The ULA handler handles IPv6 compatibility for applications. Yggdrasil itself can carry its IPv6 overlay over IPv4 peers.

On IPv4-only Internet/VPN networks, Android WebRTC may need a non-link-local IPv6 address on the relevant interface to gather IPv6 ICE candidates. The helper supplies that address. It does not provide general IPv6 Internet access. Calls have not yet been verified with these files.

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
Yggdrasil: 200:1234:5678:9abc:def0:1234:5678:9abc
Physical:  fd42:1234:5678:9abc:def0:1234:5678:9abc/128
VPN:       fd43:1234:5678:9abc:def0:1234:5678:9abc/128
```

Do not share one constant address on a physical Wi-Fi LAN. Duplicate unicast addresses can fail [IPv6 duplicate-address detection](https://www.rfc-editor.org/rfc/rfc4862.html#section-5.4).

Keep the VPN and physical helper addresses different so each belongs to one network.

#### What the handler changes

The worker records the interface index and original `disable_ipv6` value. It enables IPv6 only when needed and adds its own /128 with `nodad`. These addresses come from the key and skip duplicate-address detection.

The handler adds no Internet default route and does not change the native Yggdrasil identity. Calls still use the overlay address through rule `1000`, table `200` and `ygg0`.

The primary physical uplink is the `dev` returned by:

```sh
ip -4 route get 1.1.1.1 mark 0x20000
```

This kernel lookup sends no packet and makes no DNS query. It uses the protected-from-VPN mark of peer sockets. The handler considers only the eligible physical interface returned by the lookup. It does not classify IMS/hotspot networks. Other interface names or ROM routing policies need separate checks.

#### Events and cleanup

The `ula` helper subscribes before its initial snapshot:

```sh
ip -o monitor label link address route rule
```

The helper confirms the subscription through the monitor's socket inode. It matches the inode in `/proc/PID/fd` to a subscribed entry in `/proc/net/netlink`. It does not assume the Netlink port ID equals the process PID.

After a blocking read, `read -t 0` checks for queued lines. Each batch checks each named link/address interface once. Route/rule events trigger at most one primary-uplink refresh per batch. If the primary changes, the handler checks both old and new uplinks. It adds no periodic timer or extra switching daemon.

Replaying about 15 minutes of recorded events reduced primary route lookups from **860 to 52**. This was an offline replay. It did not count live syscalls or measure battery savings.

The handler still forks `ip` for address checks and route lookups. Repeated netd policy-rule changes can cause work even when the uplink stays the same.

Deleting an owned ULA triggers restoration. The handler releases owned addresses on:

- Link down or loss of IPv4.
- A primary-uplink change.
- Arrival of another global-scope IPv6 address.
- Orderly shutdown.

It restores the saved IPv6 switch only on the same interface index. It also checks that restoration would not disable another global-scope IPv6 address. It leaves other addresses alone. At startup the handler removes this node's exact fd42/fd43 helpers left by an abruptly killed session; it keeps the interfaces' current IPv6 switches because the old saved values are unavailable.

The handler allows four address-add attempts per interface in ten seconds, including failures. Further attempts require a later network event; elapsed time alone does not trigger a retry. Link down clears the limit; interface recreation starts a new window. It logs `[ULA] Too many changes` once per exhausted window.

The root session owns Yggdrasil and `ula`. The helper owns the monitor and event worker. Each uses `wait -n` to detect a child exit and stops/reaps the remaining children. The worker reads events with the default IFS so a stop signal during `read` does not skip address removal. Its exit cleanup ignores further TERM/INT/HUP until removal completes. A live runit supervisor restarts the enabled service.

Startup waits have time limits. Normal event handling uses no polling loop or recurring `dumpsys`. The handler takes no wake lock. The **boot script's persistent Termux wake lock** is a separate power policy. [Logging](#93-service-logs) · [Supervisor loss and takeover](#94-previous-session-takeover).

#### Verify the installed service

After completing the manual installation, start and enable the service:

```sh
sv-enable yggdrasil && sv -w 45 up yggdrasil
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

Repeat after a VPN reconnect and a Wi-Fi/mobile transition without restarting Yggdrasil. Test reboot separately with sections 15 and 16.

#### Evidence and limits

These checks use exactly these files on the author's rooted LineageOS 23 / Android 16 phone with Yggdrasil 0.5.14-direct.3:

- **Verified:** trusted-device ping/TCP; untrusted sources dropped in `YGG_IN` counters; Syncthing over Yggdrasil in both directions; service start/stop.
- **Not yet verified:** calls; Wi-Fi ↔ mobile handover; reboot; AFWall+ enabled; the installer on a clean phone.

The installer was tested in a fake environment. Lifecycle and firewall logic also passed stub tests. These checks do not establish call, handover or boot behavior. Kernel addresses alone do not prove Android `LinkProperties` or ICE candidates. Check other ROMs, network names, VPNs and application versions separately.

### 10.4 Direct peer transport

The patch in section 5 sets `SO_MARK=0x20000` on outgoing TCP-based and QUIC/UDP peer sockets on Android. Socket setup errors stop the connection instead of allowing an unprotected connection. Android selects Wi-Fi or mobile data. No new supervisor, timer or interface selector is needed. The runit scripts need no transport changes.

Verify the actual peer sockets with the VPN connected:

```sh
su -c "$PREFIX/bin/ss -tnep"
su -c "$PREFIX/bin/ss -ulnep"
```

Public outgoing Yggdrasil peer socket marks should include `0x20000`. TCP shows its physical source address. An unconnected QUIC UDP socket may show a wildcard source. Use a bounded capture to that peer to confirm its interface.

Applications that need the VPN should still use its address. A route lookup alone does not prove the peer socket path.

The ULA helper supports IPv6 candidate gathering on IPv4-only networks. Calls use the Yggdrasil address on `ygg0`. The helper addresses and peer socket marks serve separate purposes.

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

See [checks and limits](#evidence-and-limits) for the current service status and [transport details](../DIRECT-TRANSPORT.md) for the patch reference.

---

## 11. Firewall

Treat the public Yggdrasil network as untrusted. Other nodes can reach the host even behind NAT or CGNAT. The `firewall` file protects incoming `ygg0` traffic with one INPUT jump:

```text
-A INPUT -i ygg0 -j YGG_IN
```

Inside `YGG_IN` the order is:

```text
ESTABLISHED,RELATED -> ACCEPT
INVALID             -> DROP
each trusted source -> ACCEPT
everything else     -> DROP
```

Outbound traffic is not filtered. This host-only setup adds no FORWARD rules. Do not flush Android's tables: Android uses other chains for networking, bandwidth accounting and tethering.

### 11.1 Trusted list and reload

The list is `$PREFIX/etc/yggdrasil-trusted`. Create it only if missing, then edit it:

```sh
if [ ! -e "$PREFIX/etc/yggdrasil-trusted" ]; then
    install -m 600 ~/yggdrasil-android-guide/files/usr/etc/yggdrasil-trusted "$PREFIX/etc/yggdrasil-trusted"
fi
nano "$PREFIX/etc/yggdrasil-trusted"
```

The supplied template contains comments only and trusts nobody:

```text
# One Yggdrasil address or prefix (200::/7) per line, then an optional note.
# Blank lines and lines starting with # are ignored. No prefix means /128.
# 200:1234:5678:9abc:def0:1234:5678:9abc laptop
```

Use one address or prefix per line, with an optional note after it. Keep prefixes at /7 or longer and contained within the Yggdrasil range. Blank lines and `#` comments are ignored; no prefix means /128. The list is for sources within `200::/7` only. Malformed lines and prefixes shorter than /7 are reported as `Ignored line N` and skipped, so one typo cannot break the reload or open the whole interface. A trusted prefix permits every source in that prefix, so prefer /128 for one device.

Apply changes as the normal Termux user:

```sh
"$PREFIX/var/service/yggdrasil/firewall"
```

It elevates with `su` itself. No Yggdrasil restart is needed. `run` also calls it before each daemon start, including starts from a login. Failure to apply the firewall stops service startup.

The chain is created or replaced in one `ip6tables-restore --noflush --wait=10` transaction. Reload has no interval with inbound `ygg0` open. **`--noflush` is required:** without it restore would erase Android's whole filter table. Only `YGG_IN` is rebuilt. A checked append creates the INPUT jump if missing; normal re-runs do not add duplicates.

Inspect the full INPUT order and our chain:

```sh
su -c '/system/bin/ip6tables -S INPUT'
su -c '/system/bin/ip6tables -S YGG_IN'
```

Expect exactly one `-A INPUT -i ygg0 -j YGG_IN`. Earlier rules from Android or another firewall can affect the result. Use [packet and counter tests](#15-verify-the-firewall). The script applies rules when called; it does not continuously restore rules removed by another application.

### 11.2 AFWall+

These points come from a **source audit of AFWall+ 5.0.0**, not a phone test with AFWall+ enabled. The audited source version alone does not prove that an installed APK contains the same code.

Normal apply/disable operations manage AFWall+'s own chains and jumps. They do not flush INPUT or replace `YGG_IN`. An optional `afwall-input` jump returns to the remaining INPUT rules. The separate **“Flush all rules”** action performs a global flush and deletes `YGG_IN` when IPv6 support is enabled. Run `$PREFIX/var/service/yggdrasil/firewall` again, or restart Yggdrasil, afterwards and verify the INPUT jump and counters.

In whitelist mode, allow **`(root)` on Wi-Fi and mobile data** so the root Yggdrasil daemon can reach its peers. This permission covers all UID 0 processes. Enable IPv6 support when using AFWall+ to control IPv6.

`ygg0` matches none of AFWall+'s Wi-Fi, mobile or VPN interface classes. The VPN patterns are `tun+`, `ppp+`, `tap+` and `wg+`. **App checkboxes do not control app traffic over Yggdrasil** with the standard interface mapping. With the usual OUTPUT ACCEPT policy, unclassified traffic passes; other rules or a DROP policy can still block it. A custom-rule mapping is possible but untested.

AFWall+'s custom script field is an **iptables-command parser, not a shell**. Do not paste a shell script, `||`, redirections or a call to the `firewall` file there. Keep ownership of `YGG_IN` in the service.

With Wi-Fi LAN control, destinations in `fc00::/7` count as LAN, including the fd42/fd43 helpers; this classification does not grant access. Traffic through a VPN TUN uses VPN permissions when VPN control is enabled. Yggdrasil's `200::/7` range is not in that LAN range.

The **“Fix startup data leak”** option can set built-in policies to DROP early at boot. Its timing with this service and Termux:Boot is **untested**. Verify boot startup and application traffic separately; the source audit does not verify AFWall+ compatibility with this service.

### 11.3 Allow a device / example: Syncthing

Add the other device's Yggdrasil address to the phone's trusted list, then run `firewall` as shown above. Use the other device's own address, not the phone's address. Configure any firewall on that device to allow the phone too.

In Syncthing, set the remote device address explicitly **on both sides**:

```text
tcp://[200:1234:5678:9abc:def0:1234:5678:9abc]:22000
```

Replace the placeholder with the other device's Yggdrasil address on each side. Yggdrasil addresses are not announced by Syncthing discovery. On the same LAN, Syncthing prefers the direct LAN link, which is fine.

For privacy, you can disable global discovery and relays. The public discovery server returns a device's current IP to anyone who knows its device ID. Relays see device IDs and traffic volume.

Syncthing-Fork on Android does not run while Battery Saver is on unless its run condition **“respect battery saver”** is turned off. Check that condition if the device appears offline.

On the author's phone, Syncthing connected over Yggdrasil in both directions: the phone dialled the laptop and the laptop dialled the phone. Trusted-device ping/TCP and an untrusted-source DROP were also verified. [Evidence and limits](#evidence-and-limits).

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

Opening a Termux login shell can start the supervisor through `start-services.sh`. It does not scan `~/.termux/boot/`. The service still applies the firewall because `run` calls `firewall`. A successful start from login does not prove Termux:Boot worked. [Reboot proof](#161-prove-startup-before-the-first-login).

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
    sv-enable yggdrasil && sv -w 45 up yggdrasil
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

### 14.5 Route selection and a ping test

Use the address of a reachable Yggdrasil node. Replace this placeholder before running the route lookup and ping:

```sh
su -c 'ip -6 route get 200:1234:5678:9abc:def0:1234:5678:9abc'
```

Expected properties:

```text
dev ygg0
table 200
src <YOUR_YGG_IP>
```

Then test basic reachability:

```sh
ping -6 200:1234:5678:9abc:def0:1234:5678:9abc
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

Choose a reachable Yggdrasil HTTP service and replace the placeholder below:

```sh
curl -6 --noproxy '*' --connect-timeout 10 -I 'http://[200:1234:5678:9abc:def0:1234:5678:9abc]/'
```

Availability of a public endpoint can change; verify the application endpoint you need.

---

## 15. Verify the firewall

Check replies, trusted sources and untrusted sources separately. Use devices you control and new connections; existing connections are accepted by conntrack even after you remove a source from the list.

### 15.1 Check initial counters

```sh
su -c '/system/bin/ip6tables -L INPUT -n -v --line-numbers'
su -c '/system/bin/ip6tables -L YGG_IN -n -v --line-numbers'
```

Expect one INPUT jump for `ygg0` and, in `YGG_IN`, established/related ACCEPT, invalid DROP, each trusted source ACCEPT and final DROP. Reloading `firewall` rebuilds the chain and resets its counters. Record counters immediately before each test.

### 15.2 Verify replies to outbound traffic

Use a reachable Yggdrasil HTTP server you control. Replace this documentation address first:

```sh
curl -6 --noproxy '*' --connect-timeout 10 -I 'http://[200:1234:5678:9abc:def0:1234:5678:9abc]/'
su -c '/system/bin/ip6tables -L YGG_IN -n -v --line-numbers'
```

The established/related ACCEPT counter should increase as replies arrive. This checks replies to connections initiated by the phone.

### 15.3 Verify trusted and untrusted inbound sources

Use another Yggdrasil node and an existing TCP listener, such as Termux SSH on port 8022. If SSH is down, you may start it temporarily with `sv up sshd`; stop it afterwards only if this test started it. Keep its existing enabled/disabled state.

Check the listener and watch packets on the phone:

```sh
su -c "ss -lntp | grep ':8022'"
su -c "tcpdump -n -tttt -vv -i ygg0 'icmp6 or tcp port 8022'"
```

First add the test node's address to `yggdrasil-trusted` and run `firewall`. From that node, use the phone's address:

```sh
ping -6 200:1234:5678:9abc:def0:1234:5678:9abc
ssh -o ConnectTimeout=5 -p 8022 <TERMUX_USER>@200:1234:5678:9abc:def0:1234:5678:9abc
```

Replace both placeholders. Ping and a new TCP connection should reach the phone. A login prompt or TCP handshake is sufficient; SSH authentication is separate. The trusted source's ACCEPT counter should increase.

Next use a different node absent from every trusted prefix, or close all test connections and remove the test node from the list, then reload `firewall`. Try a **new** TCP connection. Expected: a timeout, incoming SYNs visible on `ygg0`, no SYN-ACK from the phone and an increasing final DROP counter:

```sh
su -c '/system/bin/ip6tables -L YGG_IN -n -v --line-numbers'
```

A timeout alone is not enough: the packet capture confirms arrival, and the counter confirms the firewall dropped it. Restore the intended trusted list and reload it after testing. Stop packet capture with Ctrl-C. If this test started SSH from a confirmed down state, restore that state with `sv down sshd`.

The checks with these files passed trusted laptop ping/TCP and an untrusted-source drop visible in `YGG_IN` counters. These checks do not cover AFWall+ enabled or reboot. [Checks and limits](#evidence-and-limits).

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

Reboot has not yet been verified with these files. Use this comparison to check whether Termux:Boot started the service before login.

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
ula monitor/worker -> stopped
ygg0               -> removed
rule 1000           -> removed
table 200 route     -> removed with ygg0
```

The firewall rules remain installed. They do not match while `ygg0` is absent. The shared Termux wake lock also remains. Release it only if no other service needs it. [Power policy](#124-wake-lock-and-battery-cost).

Stopping Yggdrasil removes ULAs added by this handler. It restores the saved IPv6 flag where safe. It leaves other addresses alone; startup removes only this node's exact stale helper addresses. Restarting adds eligible ULAs again and preserves existing native IPv6.

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

This guide builds directly inside Termux and verifies:

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

This setup uses only the destination rule `1000`.

### 18.8 Why run calls firewall

Applying rules without duplicates before each daemon start covers boot, starts from a login and runit restarts.

The service calls the separate `firewall` file at startup. Editing the trusted list needs only another call to that file. It needs no extra supervised firewall process. Rules remain after the daemon stops. [Firewall and AFWall+](#11-firewall).

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

The VPN/physical ULA handler is Bash code in the separate `ula` file, started by `run`. It needs no extra Yggdrasil source patch or build flag. Keep it when updating binaries. Review the separate peer socket patch for each new upstream release.

Check [upstream releases and release notes](https://github.com/yggdrasil-network/yggdrasil-go/releases) for the required Go version, configuration changes and peer/protocol compatibility. Choose a stable release tag. The examples use the placeholder `vX.Y.Z`. They do not claim that an unreleased or untested version is compatible.

Keep the peer socket patch when building a new upstream release. Installing an unpatched upstream binary removes VPN bypass. [Transport contract](../DIRECT-TRANSPORT.md).

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

Use the patch from the guide clone. Label the build with the selected upstream version plus `-direct.local`:

```sh
ygg_patch="$HOME/yggdrasil-android-guide/patches/android-peer-vpn-bypass.patch"
git -C "$ygg_update_dir" apply --check "$ygg_patch" &&
git -C "$ygg_update_dir" apply "$ygg_patch" &&
(cd "$ygg_update_dir" && GOFLAGS=-p=2 PKGVER="${ygg_release#v}-direct.local" ./build -p -l "-checklinkname=0")
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
if "$ygg_update_dir/yggdrasil" -useconffile "$PREFIX/etc/yggdrasil.conf" -normaliseconf >/dev/null 2>/dev/null &&
"$PREFIX/bin/yggdrasil" -useconffile "$PREFIX/etc/yggdrasil.conf" -address > "$ygg_backup_dir/address.before" 2>/dev/null &&
"$ygg_update_dir/yggdrasil" -useconffile "$PREFIX/etc/yggdrasil.conf" -address > "$ygg_backup_dir/address.candidate" 2>/dev/null &&
cmp -s "$ygg_backup_dir/address.before" "$ygg_backup_dir/address.candidate"; then
    echo CONFIG_OK
else
    echo 'Configuration check failed; review the file locally.' >&2
fi
```

Continue only after `CONFIG_OK`. The command discards normalized output and keeps the installed config unchanged. If release notes require a config change, back it up first. Make the change and validate again. Address comparison checks identity, not every future config behavior.

### 19.4 Replace only the two binaries

This interrupts Yggdrasil briefly. Other Termux services remain running.

```sh
touch "$PREFIX/var/service/yggdrasil/down" &&
sv -w 45 down yggdrasil &&
install -m 755 "$ygg_update_dir/yggdrasil" "$PREFIX/bin/yggdrasil" &&
install -m 755 "$ygg_update_dir/yggdrasilctl" "$PREFIX/bin/yggdrasilctl" &&
rm -f "$PREFIX/var/service/yggdrasil/down" &&
sv -w 45 up yggdrasil
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
curl -6 --noproxy '*' --max-time 15 -I 'http://[200:1234:5678:9abc:def0:1234:5678:9abc]/'
```

Allow time for peers to reconnect. Check:

- The original native node address and working peers.
- `ygg0`, rule `1000` and the `200::/7` route in table `200`.
- Exactly one INPUT jump to `YGG_IN`, the trusted-source rules and real overlay connectivity.

Replace the example HTTP address with a reachable server. If multicast is enabled and a compatible router is on Wi-Fi, check that the local TLS peer returns too.

For this service, check `fd43:<node low 112 bits>/128` on an eligible IPv4-only VPN TUN. Check `fd42:<same bits>/128` on the current IPv4-only physical Internet interface. A native dual-stack interface needs no extra ULA. For the usual `tun0`:

```sh
su -c "$PREFIX/bin/ip -6 addr show dev tun0"
```

If the VPN uses another `tunN` name, inspect it instead. Find the primary physical interface with `ip -4 route get 1.1.1.1 mark 0x20000`; this lookup sends no packet. Inspect its addresses too. The handler stays in the separate `ula` file.

With the VPN active, inspect the **public outgoing peer** sockets (TCP and UDP):

```sh
su -c "$PREFIX/bin/ss -tnep"
su -c "$PREFIX/bin/ss -ulnep"
```

The socket marks must include Android's `protectedFromVpn` bit (`0x20000`). Tested public sockets show `fwmark:0x20000`. TCP source addresses must belong to the physical network.

QUIC UDP sockets may appear as unconnected/wildcard sockets in `ss`. Use a bounded packet capture to prove their physical path. A version suffix or route lookup alone does not prove bypass. Check that applications requiring the VPN still use its address.

After changing versions, verify public-peer traffic outside the VPN, Wi-Fi/mobile reconnection and a call with the VPN active. Keep the backup until those checks pass.

### 19.6 Roll back if the new version fails

In a new shell, set `ygg_backup_dir` to the saved path first. Stop the service and restore both binaries:

```sh
touch "$PREFIX/var/service/yggdrasil/down" &&
sv -w 45 down yggdrasil &&
install -m 755 "$ygg_backup_dir/yggdrasil" "$PREFIX/bin/yggdrasil" &&
install -m 755 "$ygg_backup_dir/yggdrasilctl" "$PREFIX/bin/yggdrasilctl"
```

A normal update leaves the configuration unchanged. Only if you edited it for the new release, restore the saved config while the service is still stopped:

```sh
install -m 600 "$ygg_backup_dir/yggdrasil.conf" "$PREFIX/etc/yggdrasil.conf"
```

Then start the service again:

```sh
rm -f "$PREFIX/var/service/yggdrasil/down" &&
sv -w 45 up yggdrasil
```

Repeat section 19.5 checks with the restored version. Keep source and backup directories until you no longer need rollback. Remove only the directories you recorded. Do not delete an older backup while preparing the next update.

---

## 20. Removing the setup

Follow these steps to remove Yggdrasil but keep Termux and `termux-services`.

### 20.1 Stop and disable the service

```sh
sv-disable yggdrasil && sv -w 45 down yggdrasil
```

Stop here if either command fails. Confirm that the root session and Yggdrasil have exited and `ygg0` is gone before removing the service directory or firewall:

```sh
sv status yggdrasil
su -c 'ps -A -o PID,PPID,ARGS'
su -c 'ip link show'
```

Expect `down`, no Yggdrasil daemon or recorded root session, and no `ygg0`. If unsure, keep the service directory and firewall and resolve the stop failure first. Never stop it with `service-daemon stop`, `sv exit` or by deleting the directory: on runit 2.3.1 these skip `finish` and can leave the root session and Yggdrasil running. `sv down` and `sv restart` run `finish`.

### 20.2 Remove the service directory

```sh
rm -rf "$PREFIX/var/service/yggdrasil"
```

### 20.3 Remove boot/state files

Keep `10-services.sh` if you use other Termux services. Otherwise, remove it.

After the root session has fully stopped, you may remove the stale `$PREFIX/var/run/yggdrasil-root` record. Logs stay under `$PREFIX/var/log/sv/yggdrasil/` for diagnosis. Remove them only if no longer needed.

`~/yggdrasil-backup-*` may contain old service files; `~/.cache/yggdrasil-ultimate` is the build cache. Both are safe to delete when you no longer need rollback or cached builds. Installer backups never contain `yggdrasil.conf`; keep your private configuration copy if you want to retain the identity.

The shared wake lock remains. Release it with `termux-wake-unlock` only if no other Termux service needs it.

### 20.4 Remove the currently loaded Yggdrasil firewall rules

After the service has stopped, remove its INPUT jump before deleting its chain:

```sh
su -c '
while /system/bin/ip6tables -w -D INPUT -i ygg0 -j YGG_IN 2>/dev/null; do :; done
/system/bin/ip6tables -w -F YGG_IN && /system/bin/ip6tables -w -X YGG_IN
'
```

These commands flush only `YGG_IN`. Keep Android's other chains intact.

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
- trusted-source `YGG_IN` chain applied by `firewall`, called from `run` before every daemon start;
- no custom `dnsmasq`;
- reboot checks compare boot startup with login startup; reboot remains unverified with these files;
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
│       ├── run: root-session takeover + routing
│       │   ├── firewall: YGG_IN + trusted sources
│       │   ├── Yggdrasil daemon
│       │   └── ula: VPN/physical Netlink handler
│       ├── finish: stop root session + fallbacks
│       └── log/run: svlogd (bounded service logs)
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
└── IPv6 INPUT → YGG_IN
    ├── ESTABLISHED,RELATED -> ACCEPT
    ├── INVALID             -> DROP
    ├── trusted sources     -> ACCEPT
    └── everything else     -> DROP
```

The setup uses no Android VPN API, custom DNS daemon or extra overlay-routing wrapper.

It uses native Yggdrasil, Android TUN, policy routing, `runit`, an event-driven VPN/physical compatibility handler and a small stateful firewall.

## License

GPL-3.0-or-later — see [LICENSE](../LICENSE).
