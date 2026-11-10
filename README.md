# pi-vctl

Runs the [pi](https://pi.dev) coding agent inside a VMware Workstation `vctl` container on Windows, without Hyper-V. Each container gets its own lightweight VM.

Requires Workstation 17. **Do not upgrade to 25H2, which removed `vctl`.** Tested on 17.5.2.

## Setup

```powershell
.\setup.ps1
```

This starts the runtime, creates a blank `crx.vmdk`, and builds the `pi-sandbox` image. It is safe to re-run.

Use `.\setup.ps1 -Rebuild` to rebuild the image after editing `image\Dockerfile`. A failed build keeps the old image.

## Usage

Run from a project folder, in Windows Terminal or another real console:

```powershell
D:\dev\js\pi-vctl\pi-vctl.ps1
D:\dev\js\pi-vctl\pi-vctl.ps1 -p "list the failing tests"
```

All arguments go to pi. The current folder is mounted read-write at its own path, written Unix-style (`D:\dev\app` at `/d/dev/app`), so commit your work first. Each project keeps its own sessions for `--continue` and `--resume`, separate from Windows pi's.

| Variable | Default | Use |
|---|---|---|
| `PI_VCTL_MEMORY` | `2g` | Memory limit. The VM gets 512 MB on top of this |
| `PI_VCTL_CPUS` | `4` | CPU cores |
| `PI_VCTL_WORKSPACE` | current folder | Folder to mount |

The launcher refuses drive roots, home folders and their parents, and folders such as `.pi`, `.ssh` and `AppData`.

## How it fits together

- **Paths:** vctl keeps its data under `HOME` and unpacks images under `TMP`. The scripts point both at your Windows profile for vctl only, because `C:\msys64` ACLs block the case-sensitive folders vctl needs.
- **`crx.vmdk`:** vctl requires this file, but its download host no longer exists. The VM boots from the kernel and initrds in Workstation's `vkd` folder and attaches no disk, so a blank file works.
- **Config:** your real `~/.pi` is mounted read-write at `/root/.pi`, so the container and Windows pi share settings, credentials, sessions, skills and extensions.
- **Image changes for the shared config:** `image\patch-shell.js` makes Linux pi ignore a Windows `shellPath` and use `/bin/bash`. `fd` and `rg` are installed in the image, so pi does not download Linux binaries into the shared `bin` folder.
- **TUI freeze fix:** the launcher patches the container's guest agent in memory. See the first Known quirk.

## Security limits

- **The network is open.** A container can reach the host's LAN IP, including SMB and RPC, and the rest of the LAN. Check with `test\network-probe.ps1`.
- **The agent can read every credential in `~/.pi/agent`**, including `auth.json`, `mcp-auth.json`, and keys in `models.json` and `mcp.json`.
- **The agent can escape through `~/.pi`.** It can write to `bin`, `install`, `extensions`, `npm`, `git` and `skills`, and Windows pi runs code from those folders with your full user rights. The container does not contain a compromised agent once you next run pi on the host.
- **The agent can write to anything in the mounted project folder.**
- **The guest kernel is from 2021** (Linux 4.19) and only changes with Workstation. Treat the hypervisor as the boundary.

## Known quirks

- **vctl's guest agent freezes the terminal after 64 KB of output without a newline.** It logs terminal output line by line to `/tmp/<container>/1.log` in the VM's memory, and its copy loop stops for good once it has buffered 64 KB without one. The program then blocks on its next terminal writes, at about 83 KB. For interactive runs, `lib\agent-patch.ps1` runs hidden next to pi. Once the VM is up, it runs `image\agent-patch.sh` there through `vctl execvm`. That script pauses the agent at a moment when no thread is inside the bytes being replaced. It then has `image\agent-patch.cjs` make `pkg/logfile.(*DatedLog).Write` return success without logging, and resumes the agent. This removes the freeze for every program and stops the log using memory. Only that container's VM is changed, in memory: nothing on disk, and no other container. It applies only to the agent build from Workstation 17.5.2, checked by SHA-256 and by the original bytes. Otherwise it changes nothing, and the launcher prints a warning when pi exits, because long output can then freeze the terminal. With the patch, `vctl logs` is empty.
- Install tools in `image\Dockerfile`. `apt` fails inside a running container, but works during the build.
- The mount is case-insensitive, so files differing only by case collide.
- `vctl` flags parse values as CSV, so paths and `-e` values cannot contain commas.
- **`vctl build` leaves the runtime hung.** Every later `vctl run` hangs with no output, `~\.vctl\containerd.log` stops growing, and each attempt leaves a `vmware-vmx` process running. `setup.ps1` restarts the runtime after a build, unless containers are running. In that case, run `vctl system stop` once they have exited. The next launch starts the runtime again.
- **Startup takes about 17 seconds, mostly spent copying the image.** vctl gives every container a fresh copy of the image, about 25,000 files, and deletes it on exit. Excluding the copies from Microsoft Defender cut startup to about 11 seconds. Run this in an admin PowerShell, using your own profile path:
  ```powershell
  Add-MpPreference -ExclusionPath "C:\Users\<you>\.vctl\storage"
  ```
  Defender then skips files inside container filesystems. Your project folder and `~/.pi` are separate mounts and are still scanned. Any other program running as you could also put files there to avoid a scan.
- **The first run after the runtime starts takes about a minute longer**, while it unpacks the image. `setup.ps1` does this run itself after a build. The agent patch waits until `vctl ps` lists the container, because `vctl execvm` during the unpack makes the run hang.
- **Cleanup:**
  - A normal exit removes the container, its VM and its copy of the image.
  - After a run that hung or was interrupted, the launcher removes what that run left behind.
  - A launcher that was killed, for example by closing its window, cannot clean up. Its container keeps running and uses memory until the next launch removes it. To remove it sooner, run `vctl ps -a`, then `vctl rm -f <name>`.
  - Each image build leaves its intermediate layers on disk, about 2 GB per build. containerd removes them about 24 hours later, when the leases vctl created for them expire.
- Extensions load from the shared folder, so ones with Windows-only binaries may not work in the container.

## Tests

```powershell
.\test\smoke.ps1           # sends one prompt to your configured model
.\test\network-probe.ps1   # shows what a container can reach
```
