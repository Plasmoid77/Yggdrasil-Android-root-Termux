# Yggdrasil on rooted Android via Termux - Full Guide

Native Yggdrasil node on rooted Android without the Android VPN API.

The goal of this guide is to run the regular Yggdrasil userspace router directly on Android, create a real `ygg0` TUN interface, route only the Yggdrasil address space through it, supervise the daemon with `runit`, restore the firewall and service supervisor after reboot with Termux:Boot, and keep Android's normal network stack untouched.

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
                │   ├── adds RPDB rule 1000
                │   ├── removes stale ygg0
                │   ├── prepares /dev/net/tun
                │   ├── starts Yggdrasil as root
                │   ├── waits for ygg0
                │   ├── adds 200::/7 to table 200
                │   └── waits for Yggdrasil
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
- Termux;
- Termux:Boot, launched at least once from the Android launcher before the first reboot test.

This guide assumes root is already configured and working.

---

## 4. Prepare Termux

Update package metadata:

```sh
pkg update
```

Install the packages required for the setup itself:

```sh
pkg install git golang termux-services iproute2 procps nano
```

They are used for:

- `git` — cloning the Yggdrasil source tree;
- `golang` — building Yggdrasil;
- `termux-services` — `runit` integration;
- `iproute2` — `ip` and policy routing;
- `procps` — `pgrep` and `pkill`;
- `nano` — editing the configuration and service files used in this guide.

There is no need to install `clang` separately: the Termux `golang` package already depends on it, and cgo uses it as the C compiler.

Some verification steps later in the guide use additional tools. They are not required for Yggdrasil itself. Install them if you want to reproduce those tests:

```sh
pkg install curl iputils openssh tcpdump
```

They are used only for verification:

- `curl` — HTTP connectivity test over Yggdrasil;
- `iputils` — `ping` test;
- `openssh` — temporary inbound SSH target for the firewall test;
- `tcpdump` — observing packets on `ygg0` during the firewall test.

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

Build:

```sh
./build -p -l "-checklinkname=0"
```

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

Generate a fresh configuration:

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

A peering URI can look like:

```text
tcp://host:port
tls://host:port
quic://host:port
ws://host:port
```

For example, at the time this guide was prepared the public peer list included:

```text
tcp://yggno.de:18226
```

Peer availability changes over time. Do not treat any single URI in this README as permanent.

Example:

```text
Peers: [
  tcp://yggno.de:18226
  tls://another-nearby-peer.example:12345
]
```

Replace example entries with current peers from the public-peers repository.

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

```sh
#!/data/data/com.termux/files/usr/bin/sh

# Send all traffic destined for the Yggdrasil 200::/7 network to routing table 200.
su -c 'ip -6 ru add to 200::/7 lookup 200 prio 1000' 2>/dev/null || true

# Remove a stale ygg0 interface left by an unclean previous shutdown.
su -c 'ip link del ygg0' 2>/dev/null || true

# Prepare the standard /dev/net/tun path for the TUN interface.
su -c 'mkdir -p /dev/net && ln -sf /dev/tun /dev/net/tun'

# Merge stderr into stdout for runit service output.
exec 2>&1

# Start Yggdrasil with root privileges.
su -c "/data/data/com.termux/files/usr/bin/yggdrasil -useconffile /data/data/com.termux/files/usr/etc/yggdrasil.conf" &
YGG_PID=$!

# Wait up to 30 seconds for ygg0 to appear.
for i in $(seq 1 30); do
    su -c 'ip link show ygg0' >/dev/null 2>&1 && break || true
    sleep 1
done

# Once ygg0 exists, route the Yggdrasil network through it in table 200.
if su -c 'ip link show ygg0' >/dev/null 2>&1; then
    su -c 'ip r add 200::/7 dev ygg0 metric 128 table 200'
else
    echo "ERROR: ygg0 did not appear" >&2
    su -c "kill $YGG_PID" 2>/dev/null
    exit 1
fi

# Keep the run script alive for as long as the Yggdrasil process is running.
wait "$YGG_PID"
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

Give it a moment:

```sh
sleep 1
```

Enable the Yggdrasil service:

```sh
sv-enable yggdrasil
```

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
Yggdrasil process -> stopped
ygg0               -> removed
rule 1000           -> removed
table 200 route     -> removed with ygg0
```

The firewall rules remain installed. They simply do not match while `ygg0` does not exist.

### Start

```sh
sv up yggdrasil
```

The service recreates:

```text
rule 1000
ygg0
table 200 route
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
│   └── yggdrasil
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

Just native Yggdrasil, Android TUN, policy routing, `runit` and a small stateful firewall.
