# Direct Yggdrasil peer transport outside an Android VPN

The [full installation guide](docs/INSTALL.md) and [QUICKSTART](QUICKSTART.md) include this patch. This document explains the transport patch. Installing the v3 service profile is a separate step.

A small patch to Yggdrasil v0.5.14 marks outgoing TCP-based and QUIC/UDP peer sockets with Android's `protectedFromVpn` bit (`SO_MARK=0x20000`). This setup needs root. Android chooses the physical network. Use normal `Peers` without fixed interface names.

This branch keeps the same peer socket patch and firewall. Its runit ULA handler also supports the current IPv4-only physical Internet interface. [Section 10.3](docs/INSTALL.md#103-android-vpn--webrtcvoip-compatibility) explains this separate compatibility layer.

The setup adds no switching daemon or polling loop. Socket setup errors stop the connection. Other Termux/root processes keep their VPN path. No global routing or firewall bypass is installed.

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

The default example uses IPv4 TCP peers, empty `InterfacePeers` and empty regular `Listen`. Wi-Fi multicast discovers local TLS/TCP peers. You can choose other supported transports in `Peers` and keep the socket patch enabled.

Android's [Fwmark.h](https://android.googlesource.com/platform/system/netd/+/refs/heads/main/include/Fwmark.h) defines the bit layout. Setting the mark needs root socket privileges. Tests used Amnezia Premium IPv4-only on arm64 LineageOS 23 / Android 16. Check the actual socket path with your VPN.

## Build

Start in the root directory of this guide checkout. Use the v0.5.14 source from the main guide. The patch must not already be applied:

```sh
guide_patch="$PWD/patches/android-peer-vpn-bypass.patch"
cd ~/yggdrasil-go
git apply --check "$guide_patch"
git apply "$guide_patch"
PKGVER=0.5.14-direct.3 ./build -p -l "-checklinkname=0"
./yggdrasil -version
```

## Install on an existing node

Follow [installation guide section 19](docs/INSTALL.md#19-updating-yggdrasil) for updates and rollback. It checks the configuration and identity, saves a private backup and stops on command failure. It replaces **both** `yggdrasil` and `yggdrasilctl`.

Keep the existing key, peers and multicast policy. The transport patch does not require changing them.

A binary-only update does not install ultimate v3. Also follow [the service migration instructions](docs/INSTALL.md#95-upgrading-an-existing-service-profile) for distinct VPN/physical ULAs, previous-session takeover, firewall setup before daemon start, event batching and logging.

Stop an older session without a takeover record through its supervisor before replacing its script. Built-in Wi-Fi multicast works separately from public peer transport. See [multicast details](docs/INSTALL.md#wi-fi-multicast-discovery).

## Verify

```sh
su -c "$PREFIX/bin/yggdrasilctl -endpoint=unix://$PREFIX/tmp/yggdrasil.sock getPeers"
su -c "$PREFIX/bin/ss -tnep"
su -c "$PREFIX/bin/ss -ulnep"
```

Public peers should be up. Outgoing TCP and QUIC UDP sockets should carry the `protectedFromVpn` bit (`0x20000`). TCP shows its physical source address. Unconnected QUIC UDP sockets may show a wildcard address. Capture packets to the chosen peer on `any` and check the interface to confirm their path.

Discovered LAN peers appear separately as link-local TLS connections on Wi-Fi. Check that other applications requiring the VPN still use its address.

With the VPN enabled, switch Wi-Fi off and back on. Check peer reconnection and the new physical source address **without restarting Yggdrasil**. Compare the daemon PID before and after. An existing connection may take time to reconnect. A route lookup alone does not prove handover.

The earlier `direct.2` build passed the handover, latency, call, clean-install, reboot and multicast checks below. They have not all been repeated on `direct.3`.

On the tested phone, both transitions passed with the same daemon PID. The overlay HTTP endpoint stayed reachable after each transition. Each ping sample used twenty requests:

| Network/test | Replies | Average RTT |
|---|---:|---:|
| Wi-Fi through VPN | 18/20 | 444 ms |
| Wi-Fi direct | 20/20 | 122 ms |
| After switching to mobile, first sample | 13/20 | 101 ms |
| Mobile, repeat sample | 20/20 | 90 ms |
| After returning to Wi-Fi | 20/20 | 144 ms |

These small samples come from one phone and network. They do not guarantee latency or loss. The first mobile sample had losses. The user reported a browsing interruption after a transition. It cleared when the user reconnected the VPN. Neither cause was established, and the failed browsing state was not captured.

Conversations calls passed separate Wi-Fi tests with Amnezia XRay and AmneziaWG active. Captures recorded about 66 seconds of bidirectional WebRTC media with XRay and 42 seconds with AmneziaWG. In both tests, media used `ygg0`. Peer transport used only `wlan0`, outside the VPN. The user confirmed both calls worked. Codex kept its VPN connection.

Switching to AmneziaWG restored the ULA automatically. No Yggdrasil restart or configuration change was needed. The captures prove the media path outside Amnezia on the phone. They do not show whether a relay was used inside Yggdrasil. Separate IPv4 candidate probes went through the VPN during the XRay test. Network switching during a call has not been tested with this patched build.

A clean reinstall from the published branch and a full Android reboot passed on 2026-10-09. About 25 seconds after boot, a Termux:Boot snapshot showed the service running. Both peers were connected through physical Wi-Fi. The three firewall rules were restored.

Later checks confirmed the original node identity, rule `1000`, table `200`, overlay HTTP 200 and automatic ULA restoration after VPN connection. A bounded capture showed peer TCP traffic only on `wlan0`, with none on the VPN interface. Other applications kept their VPN connections. The one-time diagnostic script removed itself. It is not part of the installation or a permanent helper.

The latency, handover, call, clean-install and reboot tests above used `MulticastInterfaces: []`. Wi-Fi multicast was enabled and checked separately on 2026-10-09. The same patched binary automatically connected as a direct local peer to the OpenWrt router. Both public peers stayed up.

A 15-second capture showed discovery and peer traffic only on `wlan0`. Node identity, firewall, rule `1000`, table `200` and VPN ULA stayed unchanged. Codex kept its VPN connection. Enabling multicast needs only a Yggdrasil restart, with no helper service. The earlier tests were not repeated after enabling it.

### All outgoing peer transports in direct.3

On 2026-10-09, the QUIC socket path was added to the v0.5.14 patch. The runtime diff changes three source files: 56 added lines and 7 removed lines. It adds no permanent service, routing rule, firewall rule or timer. TCP socket setup is unchanged from `direct.2`.

Local Android/root tests passed payload round trips and socket mark checks for TCP, TLS, WS, WSS, SOCKS and SOCKS+TLS. QUIC passed over IPv4 and IPv6. Its tests covered owned UDP socket closure, cleanup after repeated failed dials and refusal to connect without root socket-mark privileges. UNIX IPC and the existing core test suite also passed.

An isolated headless node then connected to a real public QUIC peer outside the active VPN. Its capture showed 85 packets on `wlan0`, including replies. None appeared on `tun0`. Its UDP sockets carried `0x20000`.

Some other public peers timed out or refused connections. A public-list entry does not guarantee availability.

The installed `direct.3` daemon was then checked with both existing TCP peers and a temporary pinned public QUIC peer. The temporary peer was removed after the initial check. The saved peer configuration stayed unchanged.

Checks preserved native identity, multicast, configuration and service/boot file hashes, full firewall rules, ULA, routing, overlay HTTP and Codex's VPN connection. No test daemon or collector remained. The QUIC-only checks below used separate temporary configurations.

### QUIC handover, calls and reboot

On 2026-10-09, a QUIC-only configuration passed Wi-Fi → mobile → Wi-Fi checks without restarting Yggdrasil. TCP peers and multicast were disabled. Captures showed public-peer UDP on physical interfaces, with none on the VPN interface. Node identity, routing, the three Yggdrasil firewall rules and VPN access stayed unchanged.

Short ping samples had packet loss and variable RTT. These results do not prove lossless handover or latency equal to TCP.

The user reported successful VLESS/Xray calls, including Monocles/Conversations interoperability. On 2026-10-10, the user also reported a successful Wi-Fi call lasting more than an hour with VLESS/Xray. Bounded captures did not record those calls' media. These are user-reported results.

With AmneziaWG and two Russian QUIC peers, fresh XMPP server connections succeeded on mobile data. The application reported connected. A QUIC-only call with that VPN protocol was not separately confirmed.

Some public peers timed out. Earlier attempts also lost overlay reachability. The reference web endpoint and ICMP probes failed in a normal TCP baseline too, while XMPP stayed reachable. The cause was not established.

Check the actual application endpoint as well as peer status. A public-list entry or an `up` peer alone does not prove application readiness.

On 2026-10-10, a full Android reboot passed with `direct.3` and two QUIC peers. TCP and multicast were disabled. A one-time Termux:Boot observer recorded the service about 28 seconds after boot. Both UDP sockets were marked and both peer handshakes had completed.

A second snapshot showed table `200` and automatic ULA restoration after the VPN appeared. The early capture recorded 122 peer UDP packets on `wlan0`, with none on the VPN interface and no kernel capture drops. The observer only read state. It removed its boot entry after completion.

Post-reboot checks preserved the node address/key and hashes of both binaries, config and service/boot scripts. They confirmed:

- The three firewall rules, routing and ULA.
- A fresh XMPP connection and HTTP 200.
- 20/20 ICMP replies, with 126.654 ms mean RTT.
- Physical QUIC traffic and continued VPN access for Codex.

No manual service start or repair came before these checks. Afterward, the original TCP peer configuration with Wi-Fi multicast was restored. The binary still supports QUIC.

### IPv4-only physical Internet and the ultimate handler

On 2026-10-13, the 207-line common handler passed on an IPv4-only mobile APN with AmneziaWG. The phone was also providing a hotspot. ICE connected in 0.443 seconds. The roughly 95-second call first selected a relay pair, then the two native Yggdrasil addresses.

Captures showed sustained bidirectional UDP between the nodes. The user confirmed working audio. Peer sockets kept their protected-from-VPN marks and physical mobile source. Other VPN traffic stayed on the tunnel.

The handler passed address deletion/restoration on the real Internet interface and VPN TUN. It also passed ownership cleanup across service down/up and uplink-selection model checks.

Primary-uplink selection excluded IMS and hotspot downstream on the tested phone. It does not classify networks by role. The earlier transport/boot results used older runit profiles. This 207-line handler test included no full Android reboot or Wi-Fi handover.

The 276-line v3 service passed IPv4-only mobile/Amnezia calls on 2026-10-14. Calls after mobile ↔ Wi-Fi transitions also passed. It uses different helpers derived from the key: `fd42:` for physical interfaces and `fd43:` for VPNs.

In controlled A/B tests, an identical ULA on both networks produced zero IPv6 candidates and ICE FAILED. The different-address control connected. Reboot and orphan-takeover results came from v2 with the same startup/takeover logic. v3 itself has not been reboot-tested. See the [current verification matrix](docs/INSTALL.md#evidence-and-limits).

## Updating to another upstream release

Follow [installation guide section 19](docs/INSTALL.md#19-updating-yggdrasil) for updates and rollback. Build in a fresh directory. Keep the installed configuration/key. Validate before replacing both binaries.

This patch was tested on v0.5.14. Review and check it against the new release before applying it. If it no longer fits, port and review it or keep the working release. An unpatched build is not an equivalent replacement. A patch that applies cleanly or a local version suffix does not prove VPN bypass.

Before discarding the backup, verify public peer socket marks and physical traffic, local multicast, network reconnection and a call with the VPN active.

## Restore

Follow [installation guide section 19.6](docs/INSTALL.md#196-roll-back-if-the-new-version-fails) to restore both binaries from the private backup. Stop on command failure. Restore the configuration only if you changed it. If you also migrated service scripts, restore their saved versions while the service is stopped. Repeat the checks for that profile.

Keep the patch when rebuilding this version. An unpatched binary loses this socket behavior. Recheck the patch and socket path for newer versions.
