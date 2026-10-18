# Direct Yggdrasil peer transport outside an Android VPN

The ultimate profile uses a small patch to Yggdrasil v0.5.14. It marks outgoing TCP-based and QUIC/UDP peer sockets with Android's `protectedFromVpn` bit (`SO_MARK=0x20000`). Android then routes them through the physical Wi-Fi or mobile network. This keeps peer transport outside an active Android VPN. The daemon needs root to set the mark.

TCP, TLS, WS, WSS, SOCKS and SOCKS+TLS use the marked TCP dialer. QUIC uses a marked UDP socket created before its handshake. Socket setup errors stop the connection. Failed QUIC handshakes and closed outgoing streams release the owned socket. UNIX sockets are local IPC.

Only Yggdrasil's outgoing peer sockets get this mark. Other applications keep their VPN policy. Hostname resolution can still use the VPN. For SOCKS or an environment HTTP proxy, the mark controls the connection to the proxy; the proxy controls the onward route. Use ordinary `Peers` without fixed interfaces. No switching service or polling loop is needed.

The ULA helper and trusted-device firewall are separate parts of the service. See [the full guide](docs/INSTALL.md#103-android-vpn--webrtcvoip-compatibility) for those and [checks and limits](docs/INSTALL.md#evidence-and-limits) for the current status.

## Build

Follow [the manual build steps](docs/INSTALL.md#5-build-yggdrasil-natively-for-android) to obtain fresh v0.5.14 source, apply `patches/android-peer-vpn-bypass.patch` once and build both Android binaries as `0.5.14-direct.3`. The installer performs these steps automatically. The version suffix is a label; the source patch provides bypass.

## Verify

With the VPN connected, inspect peers and sockets:

```sh
su -c "$PREFIX/bin/yggdrasilctl -endpoint=unix://$PREFIX/tmp/yggdrasil.sock getPeers"
su -c "$PREFIX/bin/ss -tnep"
su -c "$PREFIX/bin/ss -ulnep"
```

Outgoing public-peer sockets should carry `0x20000`. TCP shows the physical source address. An unconnected QUIC UDP socket may show a wildcard source. Use a bounded capture to the chosen peer to confirm traffic uses the physical interface. Check application connectivity and that applications requiring the VPN still use it. A route lookup or an `up` peer alone does not prove the traffic path.

See [transport verification](docs/INSTALL.md#104-direct-peer-transport) and [post-reboot checks](docs/INSTALL.md#163-direct-transport-and-vpn-compatibility). Calls, Wi-Fi ↔ mobile handover and reboot were verified with these service files.

## Updating to another upstream release

Follow [section 19](docs/INSTALL.md#19-updating-yggdrasil). Review the patch against the selected release, build in a fresh directory, validate the existing configuration and save a private rollback copy before replacing both binaries. Keep the private key and service settings.

The patch targets v0.5.14. If it no longer fits, port and review it or keep the working release. A clean patch application or version suffix does not prove VPN bypass. Check socket marks and physical traffic with the VPN active before discarding the backup.

## Restore

Follow [section 19.6](docs/INSTALL.md#196-roll-back-if-the-new-version-fails) to restore both binaries with the service stopped. Stop if any command fails. Restore the configuration only if you changed it, then repeat the checks for the restored build. Keep the socket patch when rebuilding this release.
