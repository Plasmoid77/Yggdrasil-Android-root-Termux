# Yggdrasil on rooted Android via Termux — Script Installation

> **Tested with Yggdrasil v0.5.14 on LineageOS 23 (Android 16).**
>
> **Guide by Plasmoid (Neuroslopped)**

`install.sh` performs the [manual installation](QUICKSTART.md) with one command: it builds the patched Yggdrasil, installs the runit service, firewall, ULA helper and boot script, then starts and checks the service. The [full installation guide](docs/INSTALL.md) explains each part.

## 1. Requirements

Complete the [requirements](QUICKSTART.md#1-requirements) first:

- rooted Android with working `su -c`;
- Termux and the separate **Termux:Boot Android app** from the same signing source;
- **Termux:Boot opened once through its launcher icon**.

## 2. Run the installer

Install `git` if needed (`pkg install git`), then run these commands as the normal Termux user, without `su`:

```sh
git clone --depth 1 --branch ultimate https://github.com/Plasmoid77/Yggdrasil-Android-root-Termux.git ~/yggdrasil-android-guide
bash ~/yggdrasil-android-guide/install.sh
```

Options can be combined; replace the example values with current public peers and your own devices:

```sh
bash ~/yggdrasil-android-guide/install.sh --peer tcp://192.0.2.10:12345 --peer quic://192.0.2.20:12345 --trusted 200:1234:5678:9abc:def0:1234:5678:9abc
```

These are documentation addresses, not working peers or devices. Choose peers from the [public peer list](https://github.com/yggdrasil-network/public-peers).

## 3. Options

- `--peer URI`: public peer; repeat for each. Replaces the configured peers. Without it, peers are kept, and a new node connects only to Wi-Fi multicast neighbours until you add public peers.
- `--trusted ADDR`: Yggdrasil address or prefix within `200::/7` allowed to connect to this phone; repeat for each. Replaces the trusted list. Without it, the list is kept.
- `--private-key-file FILE`: use an existing node identity. `FILE` holds only the 128-character hex private key. The environment variable `YGG_PRIVATE_KEY` may hold it instead; the key is never accepted on the command line. Without either, the configured key is kept and a new node gets a new key.
- `--rebuild`: build again even when version `0.5.14-direct.3` is installed.
- `--help`: show usage.

On a fresh install, keep a private copy of `$PREFIX/etc/yggdrasil.conf`: it contains the node's private key and is not in any installer backup.

## 4. Running it again

It is safe to run the installer again. Unchanged files are left alone, changed code files are replaced with the service stopped first and started again, and settings change only through the options above. Running it again with the same options changes nothing and does not restart Yggdrasil. Each run reloads `YGG_IN`, resetting packet counters.

**Code is replaced; settings change only when requested.** The installer backs up only code files it replaces under `~/yggdrasil-backup-<time>/` (mode 700), mirroring `usr/`. It never copies `yggdrasil.conf` into this backup. When `--peer` or `--private-key-file` changes the configuration, the previous file stays beside it as `yggdrasil.conf.previous` (mode 600; it holds the previous key) and Yggdrasil restarts. These two options edit only a JSON configuration, as the installer creates; for other formats it stops without changes. Missing settings are created. No backup is made when nothing is replaced.

To change peers or trusted devices later, run the installer again with `--peer` or `--trusted`, or edit by hand: peers in `$PREFIX/etc/yggdrasil.conf`, then `sv restart yggdrasil`; trusted devices in `$PREFIX/etc/yggdrasil-trusted`, then run `$PREFIX/var/service/yggdrasil/firewall` without a daemon restart.

## 5. What the installer does

The installer uses `files/` and `patches/` beside `install.sh`. It writes under the current `$PREFIX` and `$HOME`. The installed service files use the standard Termux paths shown in [section 9 of the full guide](docs/INSTALL.md#9-create-the-runit-service).

1. **Checks.** Require a non-root Termux user, working `su` and a clone containing `files/` and `patches/`. Warn about Termux:Boot and a nonstandard `$PREFIX`; the service scripts use standard Termux paths.
2. **Packages.** Install only missing tools, including `root-repo`; no full upgrade.
3. **Binaries.** Skip the build if `0.5.14-direct.3` and an executable `yggdrasilctl` are installed, unless `--rebuild` is given. Otherwise clone v0.5.14, verify commit `422836eeb21a99790caa286aa63d493bbc4766d7`, apply the patch and build with `GOFLAGS=-p=2` to reduce parallel processes under Android's limit. Check the resulting version.
4. **Configuration.** Never print `yggdrasil.conf` or copy it into a backup. In an existing file, apply only `--peer` and `--private-key-file` with `jq`, keeping every other field. For a new node, generate JSON (valid HJSON) with `ygg0`, the admin socket, `--peer` values, the given key or a new one, no listening endpoints and Wi-Fi multicast. Require `IfName: ygg0`; warn about `AdminListen`. Build the trusted list from `--trusted`.
5. **Supervisor.** Start runit if needed with a wake lock and `start-services.sh`, without running the user's boot script.
6. **Install files.** Publish a new service directory atomically with `down` and `log/` already inside. If any code differs (binaries, `run`, `finish`, `ula`, `firewall`, `log/run`), first create `down` and stop the service with `sv -w 45 down`. Back up replaced files to `~/yggdrasil-backup-<time>/`, then replace each by atomic rename, `run` last. Create config, trusted list, log settings and `10-services.sh` only when missing. Replace the config only when requested, with the service stopped, after saving the old file as `yggdrasil.conf.previous`. Replace the trusted list only when `--trusted` is given.
7. **Start.** Run `firewall`, remove `down` and run `sv -w 45 up yggdrasil`. The service is enabled afterwards. An unchanged running service is left running.
8. **Verify.** For about 45 seconds (command waits can extend this), check for the service running for at least ten seconds, the node address on `ygg0`, rule 1000 and exactly one `YGG_IN` jump. Print the node address, peers up, backup path and next steps.

If installation or verification fails after code replacement, the service stays stopped with `down`. Re-run the installer to complete installation.

The installer was tested with a clean installation on the author's phone. [Checks and limits](docs/INSTALL.md#evidence-and-limits).

## 6. After installation

Use the [control commands](QUICKSTART.md#10-yggdrasil-control-commands) to check peers and the node address. Termux:Boot starts the service after a reboot. Android 12+ can kill the Termux supervisor; read [background restrictions](docs/INSTALL.md#31-optional-android-child-process-restrictions). The boot script holds a wake lock, which costs battery power: [power policy](docs/INSTALL.md#124-wake-lock-and-battery-cost).
