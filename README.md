# Nextcloud Drive

Mounts a Nextcloud folder as a Windows network drive (WebDAV), without
syncing. An ad-free replacement for RaiDrive. Engine:
[rclone](https://rclone.org) and [WinFsp](https://winfsp.dev).

## Usage

1. Run `NextcloudDrive.cmd`.
2. **Install / Update**: downloads rclone (SHA-256 checksum verified) and
   installs WinFsp (Windows asks for administrator approval).
3. Fill in the fields:
   - Address: your Nextcloud server name (e.g. `nextcloud.example.org`),
     port 443;
   - Path: `/remote.php/dav/files/<login>/` (follows the login
     automatically);
   - Password: an **app password** created in Nextcloud (Settings →
     Security). The main password is refused (`PasswordLoginForbidden`).
4. **Test**, then **Connect**.

On the first save, the script is copied to `%LOCALAPPDATA%\NextcloudDrive\`
and a "Nextcloud Drive" shortcut is created in the Start menu. If "Connect
at Windows logon" is checked, a shortcut is also placed in the Startup
folder to mount the drive at logon.

## Drive icon

`NextcloudDrive.ico` ships next to the script: it is the default Nextcloud
theme icon (`/apps/theming/icon`, 512 px), scaled from 16 to 256 px. Save
and Connect apply it to the drive in Explorer, to both shortcuts and to the
window. For the drive, the key is
`HKCU\Software\Classes\Applications\Explorer.exe\Drives\<letter>\DefaultIcon`
(per-user icon, no administrator rights needed; RaiDrive used the same
one). It stays attached to the letter, even while the drive is
disconnected. Keys tried without effect on a network drive:
`HKCU\…\Explorer\DriveIcons` and `MountPoints2\…\DefaultIcon`.

The volume name shown by Explorer is `\\<first word of the server>\<name>`,
for example `\\nextcloud\Nextcloud`. WinFsp truncates this name to 32
characters: `\\nextcloud.example.org\Nextcloud` became `…\Nextclou`, and
Explorer then showed a "disconnected network drive".

Explorer's **Disconnect** menu answers "This network connection does not
exist": WinFsp's network provider only disconnects drives mounted by its own
launcher. Disconnect from the app instead.

## Files

| Location (`%LOCALAPPDATA%\NextcloudDrive\`) | Purpose |
| --- | --- |
| `bin\rclone.exe` | rclone |
| `settings.json` | settings; password encrypted with DPAPI (this account, this PC) |
| `rclone.log` | log (mount errors) |
| `cache\` | write cache: files being uploaded |

rclone options: `--network-mode --vfs-cache-mode writes --dir-cache-time 1m`.
A file stays in the cache only until its upload ends: this is not a sync.
A change made elsewhere shows up within a minute.

**Disconnect** sends Ctrl+C to rclone's hidden console, which unmounts the
drive cleanly. It goes through a separate PowerShell, because attaching to
that console would force the app to leave its own. If rclone has not
stopped after 15 s, it is killed. The drive removal is then announced to
Windows (`WM_DEVICECHANGE`) and to Explorer (`SHChangeNotify`): without
this, a killed rclone leaves a ghost drive in Explorer. A file still being
uploaded stays in `cache\` and rclone resumes the upload at the next mount.

## Uninstall

Disconnect, then delete `%LOCALAPPDATA%\NextcloudDrive\`, both "Nextcloud
Drive" shortcuts (Start menu and Startup folder), and the registry key
`Applications\Explorer.exe\Drives\<letter>` (see "Drive icon").
WinFsp is uninstalled from Settings → Apps.

## License

The code and documentation are released under the [MIT License](LICENSE).

**The icon `NextcloudDrive.ico` is not covered by this license.** It is the
Nextcloud logo, owned by Nextcloud GmbH, and is included only to identify
the server the drive connects to. Its use is governed by Nextcloud's
trademark policy. Replace it with your own icon if you redistribute or
modify this project.

## Trademarks

Nextcloud and the Nextcloud logo are trademarks of Nextcloud GmbH. This is
an independent project: it is not affiliated with, sponsored by or endorsed
by Nextcloud GmbH. rclone, WinFsp and RaiDrive are the property of their
respective owners.
