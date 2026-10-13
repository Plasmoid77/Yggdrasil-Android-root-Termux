# Yggdrasil on rooted Android via Termux

Run native Yggdrasil on rooted Android. This setup uses a real `ygg0` interface, policy routing, runit supervision and a stateful IPv6 firewall.

**[Quick setup](QUICKSTART.md) · [Full installation guide](docs/INSTALL.md)**

The **`ultimate` v3 profile** sends outgoing TCP-based/QUIC peer traffic outside the Android VPN. Android chooses the physical network. Other applications keep their VPN policy. An event-driven WebRTC handler adds local helpers derived from the node identity: `fd42:` on the primary IPv4-only physical uplink and `fd43:` on eligible IPv4-only VPN TUNs. It preserves existing global-scope IPv6. [Compatibility and verification matrix](docs/INSTALL.md#103-android-vpn--webrtcvoip-compatibility) · [Transport details](DIRECT-TRANSPORT.md).

> **Tested with Yggdrasil v0.5.14 on LineageOS 23 (Android 16).**
>
> **Guide by Plasmoid (Neuroslopped)**

## Before installation

1. Configure working root access through `su -c`.
2. Install **Termux and the separate Termux:Boot Android app** from matching signing sources.
3. **Open Termux:Boot once through its launcher icon** to activate its boot receiver.

The guides install one boot script, `10-services.sh`, and enable Yggdrasil. Termux:Boot is an Android app, not a `pkg` package. [Official instructions](https://github.com/termux/termux-boot#how-to-use).

## Service and autostart

```text
Termux:Boot → 10-services.sh → wake lock + runit
    → run: previous-session takeover → routing/firewall → Yggdrasil
        → batched VPN/physical ULA handler + bounded svlogd logs
    → finish: stop daemon and remove interface/rule
```

`run` applies the firewall before each start, including starts from a login. No separate firewall boot script is needed. It records the root-session PID/start time and waits for the previous session to clean up before changing networking. [Lifecycle](docs/INSTALL.md#94-previous-session-takeover) · [Firewall and AFWall+](docs/INSTALL.md#11-firewall).

Android 12+ can kill the Termux supervisor while root Yggdrasil keeps running. Login or reboot restores supervision. Until then, a failed daemon cannot restart. Disabling phantom-process monitoring is optional and affects all apps. The boot script holds a wake lock, which costs battery power. [Background restrictions](docs/INSTALL.md#31-optional-android-child-process-restrictions) · [Power policy](docs/INSTALL.md#124-wake-lock-and-battery-cost).

v3 passed calls on IPv4-only mobile data with Amnezia and after mobile ↔ Wi-Fi transitions. v2 passed reboot with the same boot/firewall logic. **v3 itself has not passed a reboot test**. Login can start runit; compare service start times with the first login to verify boot startup. [Reboot verification](docs/INSTALL.md#16-verify-everything-after-reboot).

## Branches

Use installation instructions from the same branch as the chosen profile.

| Branch | Profile |
| --- | --- |
| [main](https://github.com/Plasmoid77/Yggdrasil-Android-root-Termux/tree/main) | Upstream Yggdrasil, routing, firewall and runit |
| [webrtc-vpn-compat](https://github.com/Plasmoid77/Yggdrasil-Android-root-Termux/tree/webrtc-vpn-compat) | Adds the event-driven VPN ULA handler |
| [direct-vpn-bypass](https://github.com/Plasmoid77/Yggdrasil-Android-root-Termux/tree/direct-vpn-bypass) | Adds marked outgoing TCP-based and QUIC peer sockets outside the VPN |
| [ultimate](https://github.com/Plasmoid77/Yggdrasil-Android-root-Termux/tree/ultimate) | v3: direct peers, distinct VPN/physical ULAs derived from the key, previous root-session cleanup, firewall in run, batched events and bounded logs |

## License

GPL-3.0-or-later — see [LICENSE](LICENSE).
