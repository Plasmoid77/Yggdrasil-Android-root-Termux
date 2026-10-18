# Yggdrasil on rooted Android via Termux

Run native Yggdrasil on rooted Android. This setup uses a real `ygg0` interface, policy routing, runit supervision and a stateful IPv6 firewall.

**[Quick setup](QUICKSTART.md) · [Full installation guide](docs/INSTALL.md)**

Yggdrasil peer connections bypass the Android VPN. The **ultimate profile** also adds trusted-device access and IPv6 helpers for calls on IPv4-only networks. [Compatibility and checks](docs/INSTALL.md#103-android-vpn--webrtcvoip-compatibility) · [Transport details](DIRECT-TRANSPORT.md).

> **Tested with Yggdrasil v0.5.14 on LineageOS 23 (Android 16).**
>
> **Guide by Plasmoid (Neuroslopped)**

## Before installation

1. Configure working root access through `su -c`.
2. Install **Termux and the separate Termux:Boot Android app** from matching signing sources.
3. **Open Termux:Boot once through its launcher icon** to activate its boot receiver.

The guides install one boot script, `10-services.sh`, and enable Yggdrasil. Termux:Boot is an Android app, not a `pkg` package. [Official instructions](https://github.com/termux/termux-boot#how-to-use).

## Install

After the requirements above, install `git` if needed (`pkg install git`), then:

```sh
git clone --depth 1 --branch ultimate https://github.com/Plasmoid77/Yggdrasil-Android-root-Termux.git ~/yggdrasil-android-guide
bash ~/yggdrasil-android-guide/install.sh
```

Options: `--peer URI` and `--trusted ADDR` (repeatable; each replaces its list), `--private-key-file FILE` (keep a node identity), `--rebuild` (build again). Other settings are kept. [Automatic installation and manual steps](QUICKSTART.md#automatic-installation).

## Service and autostart

```text
Termux:Boot → 10-services.sh → wake lock + runit
    → run: previous-session takeover + routing
        ├── firewall → YGG_IN + trusted list
        ├── Yggdrasil → ygg0 + table 200
        └── ula → batched VPN/physical helper addresses
    → finish: stop recorded root session; clean up interface/rule
    → log/run → bounded svlogd logs
```

`run` calls `firewall` before each start, including starts from a login. It records the root-session PID/start time and waits for the previous session to clean up before changing networking. `finish` stops that session even during startup. [Lifecycle](docs/INSTALL.md#94-previous-session-takeover) · [Firewall and AFWall+](docs/INSTALL.md#11-firewall).

Android 12+ can kill the Termux supervisor while root Yggdrasil keeps running. Login or reboot restores supervision. Until then, a failed daemon cannot restart. Disabling phantom-process monitoring is optional and affects all apps. The boot script holds a wake lock, which costs battery power. [Background restrictions](docs/INSTALL.md#31-optional-android-child-process-restrictions) · [Power policy](docs/INSTALL.md#124-wake-lock-and-battery-cost).

Verified with these files on the author's phone: trusted-device ping/TCP, dropped untrusted sources, Syncthing over Yggdrasil in both directions, service start/stop, calls on Wi-Fi and mobile data, Wi-Fi ↔ mobile handover, reboot, AFWall+ enabled, and the installer on a clean phone. [Checks and limits](docs/INSTALL.md#evidence-and-limits).

## License

GPL-3.0-or-later — see [LICENSE](LICENSE).
