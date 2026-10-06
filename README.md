# Mac Server Reliability

Helpful notes, and a suite of scripts written for my Mac mini M2 server, that help with server reliability, and notifications of errors. This server currently runs Plex, DEVONthink Server, Apple Music, and Mail.

The scripts in this repo have some sensitive information replaced with placeholders, for privacy. Otherwise they should be an accurate representation of what is running on my server.

The heart of it is **[`mac-server-watchdog.sh`](scripts/mac-server-watchdog.sh)**: a single script, run every minute by a LaunchAgent, that starts the server's apps in the right order after a reboot, waits for the network shares they depend on, checks that they're actually working (not just running), restarts them when they aren't, and tells me about it — with on-screen dialogs for anyone watching over screen sharing, and push notifications through Pushover.

> **Upgrading from the earlier AppleScript version?** The previous design — a "Startup Apps and Databases" AppleScript login item plus `monitor-network-drives.sh` running every 10 seconds — is in the history at commit [`70b77b5`](https://github.com/swizzlevixen/Mac-Server-Reliability/tree/70b77b5). See [Why the rewrite](#why-the-rewrite) for what went wrong with it.

## macOS settings

### Automatically log in on startup

Due to the nature of the apps that I'm using on this server, the Mac needs to run with a user logged in. This is accomplished with **System Settings > Users & Groups > Automatically log in as…** and select the user. Note that [FileVault must be disabled](https://support.apple.com/guide/mac-help/a-login-window-start-mac-mchlp1158/15.0/mac/15.0) for automatic login to be available. Yes, that's less secure, but this Mac lives in an equipment rack in my home, and if someone we don't trust has physical access to that machine, we have bigger problems.

With FileVault on, the Mac stops at the unlock screen after every restart, and nothing — including the watchdog — runs until someone types the password.

### Energy settings

We want this machine to always be running, and recover after a power failure or other interruption. So I have these settings:

- **System Settings > Login Password > Automatically login after a restart**: on
- **System Settings > Energy > Prevent automatic sleeping when the display is off**: on
- **System Settings > Energy > Wake for network access**: on
- **System Settings > Energy > Start up automatically after a power failure**: on
- **Lock Screen > (the top group of three settings)**: Never

A sleeping Mac pauses the watchdog too, so it can't fix anything.

### Don't reopen apps after a restart

After an abnormal restart (kernel panic, power loss) **and after every software update restart**, macOS "helpfully" reopens the apps that were running, even with **Reopen windows when logging back in** switched off. They open within seconds of login: before the network shares are mounted, and before the watchdog can start things in order. That does real damage. Music, for one, can't find its media folder on the share and quietly resets it to the local default, after which every song on the share looks missing. (The watchdog's [local media folder guard](#how-it-works) catches that.)

On **macOS 26 Tahoe**, the list of apps to reopen is kept here (you can see loginwindow load it with `/usr/bin/log show --predicate 'process == "loginwindow" AND category == "TAL"'`):

```
~/Library/Group Containers/group.com.apple.loginwindow.persistent-apps/persistantApps
```

(Yes, "persistant".) Empty it and lock it, so there's never anything to reopen. Terminal needs **Full Disk Access** for this (System Settings > Privacy & Security > Full Disk Access, then relaunch Terminal); even `sudo` can't open that folder without it.

```
cd ~/Library/Group\ Containers/group.com.apple.loginwindow.persistent-apps/
cp -p persistantApps persistantApps.bak
cat > persistantApps <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>PersistentApps</key>
	<array/>
</dict>
</plist>
EOF
chflags uchg persistantApps
```

To undo: `chflags nouchg persistantApps`, and put the backup back. Also turn off the older relaunch setting, which costs nothing:

```
defaults write com.apple.loginwindow LoginwindowLaunchesRelaunchApps -bool false
```

Tested on Tahoe 26.7.1 with the apps left running and **Reopen windows** switched *on*: loginwindow found 0 apps to reopen, opened only Finder, and the file was still empty and locked afterwards.

**Older advice, and why it no longer works.** The fix used to be to lock `~/Library/Preferences/ByHost/com.apple.loginwindow.*.plist`. Tahoe doesn't use that file for this any more. And if the Mac was set up with Migration Assistant, `ByHost` may hold files from the *old* Mac: the `*` is the hardware UUID, so check it against this Mac's (`ioreg -rd1 -c IOPlatformExpertDevice | grep IOPlatformUUID`) before locking anything.

Even with all this, the safest habit is to run [`before-update.sh`](#before-update) before installing a macOS update, and to [mount the shares before login](#mount-the-shares-before-login), so an app that does start early still finds its files.

### Remote Login (optional, but handy)

**System Settings > General > Sharing > Remote Login** lets you manage the server over SSH. If you want to read files on the Desktop or in Documents over SSH (the event log, say), also turn on **Allow full disk access for remote users** in Remote Login's ⓘ info panel — otherwise macOS privacy protections silently refuse.

## Login items

You can easily [set apps and network drives to launch when the user logs in](https://support.apple.com/guide/mac-help/open-items-automatically-when-you-log-in-mh15189/mac). Go to **System Settings > General > Login Items & Extensions** and you can either drag items into the **Open at Login** list, or use the **+** button at the bottom of the list.

With the watchdog in charge of the server apps, Login Items is now only for things that don't depend on anything:

- CCC Dashboard (Carbon Copy Cloner, for backups)
- `scandocs` and `plexmedia` network drives, from the Synology `mynas` NAS (or an app like AutoMounter — see below)
- Screens Connect (for remote access)

**Don't** put the server apps themselves in Login Items, and turn off any "open at login" setting inside those apps — otherwise they'll start before their network shares are mounted. The watchdog starts them.

### A note on AutoMounter

If you use [AutoMounter](https://www.pixeleyes.co.nz/automounter/) to keep the shares mounted, consider turning off its **unmount on network interface change** setting on a wired server. With it on, every network reconfiguration (a router DNS change, a DHCP renewal, an IPv6 update) briefly unmounts *every* share. My log showed that happening two or three times a month. The watchdog tolerates short drops, but there's no reason to cause them.

## Mount the shares before login

[Script](scripts/nas-early-mount.sh) · [Example config](nas-early-mount.conf.example) · [LaunchDaemon](LaunchDaemons/com.admin.nas-early-mount.plist)

Login items and AutoMounter only mount the shares *after* login, and anything that starts at login races them. [`nas-early-mount.sh`](scripts/nas-early-mount.sh) runs once at boot from a LaunchDaemon, before anyone logs in. It waits for the NAS, then mounts each share **as the logged-in user** (with `sudo -u`), at the usual `/Volumes/<share>` path. The mounts are indistinguishable from Finder's or AutoMounter's: same paths, same owner, same permissions.

AutoMounter (or your login items) keeps running and still handles reconnects after the NAS blips. macOS won't mount a share twice for the same user, so they don't end up with duplicate `/Volumes/<share>-1` mounts. In testing, the shares were mounted about 15 seconds after boot, before AutoMounter started and before the watchdog started the apps.

The script never mounts over a folder that has something in it, and if a mount fails it removes the empty folder it made and leaves the share to the automounter. It logs to `/var/log/nas-early-mount.log`.

**Installing:**

1. Copy the script somewhere root owns (root runs it, so it shouldn't be in a folder you can write to):
   ```
   sudo mkdir -p /usr/local/libexec
   sudo install -o root -g wheel -m 755 scripts/nas-early-mount.sh /usr/local/libexec/
   ```
2. Copy [`nas-early-mount.conf.example`](nas-early-mount.conf.example) to `/etc/nas-early-mount.conf`, edit it, and make it readable by root only, since it holds the NAS password:
   ```
   sudo chown root:wheel /etc/nas-early-mount.conf
   sudo chmod 600 /etc/nas-early-mount.conf
   ```
   To try it without touching your real mounts, list one share that isn't mounted as `"share:test-folder"`, and run `sudo zsh /usr/local/libexec/nas-early-mount.sh`.
3. Install the LaunchDaemon. Loading it runs it once: shares that are already mounted are skipped.
   ```
   sudo cp LaunchDaemons/com.admin.nas-early-mount.plist /Library/LaunchDaemons/
   sudo launchctl bootstrap system /Library/LaunchDaemons/com.admin.nas-early-mount.plist
   ```

**Why not autofs?** macOS's built-in automounter seems made for this: it mounts a share the moment anything touches its path. I tried it, and it doesn't fit:

- **The mounts belong to root.** autofs mounts as root, so every folder shows as `root`, `drwx------`, and the logged-in user can't even list them.
- **The options that would fix that are refused.** With `filemode`/`dirmode` (or `noowners`) in the map, automountd fails with a misleading "No route to host", even though the same options work with `mount_smbfs` directly.
- **Sandboxed apps can't trigger it.** The kernel denies `system-automount` to sandboxed apps (Mail, for one), so the "mounts on first touch" benefit doesn't apply to them anyway.
- autofs also refuses mount points under `/Volumes` ("mountpoint unavailable"), unless you write them as `/System/Volumes/Data/../Data/Volumes/<name>`.

## The watchdog

[Script](scripts/mac-server-watchdog.sh) · [Example config](watchdog.conf.example) · [LaunchAgent](LaunchAgents/com.admin.mac-server-watchdog.plist)

### How it works

Every 60 seconds (and once at login), the watchdog runs through this:

1. **Network shares.** For each share in `SHARES`, it checks whether it's mounted under `/Volumes`. Your login items or automounter should normally handle mounting; the watchdog gives them `SHARE_GRACE` (3 minutes) and only then remounts the share itself, via Finder, using the Keychain credentials already saved for the NAS. It tries again every minute until the share is back.
2. **Services, in config order.** For each app in `SERVICES`:
   - **Dependencies first.** If any share the app needs isn't mounted, the app isn't started (or restarted) — so Plex never starts against a missing media share. Apps that *don't* need that share start anyway; one slow share no longer holds up the whole server. If an app is already running when its share disappears, it's left alone — unless it's listed in `QUIT_WHEN_SHARE_MISSING`, in which case it's quit once the share has been gone for the grace period, and started again when the share returns.
   - **Running?** If not, it's started.
   - **Healthy?** If the app has a health URL (Plex's `/identity`, DEVONthink's web server), the watchdog actually requests it. A running-but-hung app is restarted after `UNHEALTHY_LIMIT` (3) failed checks in a row — gracefully quit first, force-quit only if it won't go. Freshly launched apps get `LAUNCH_GRACE` (5 minutes) to come up before their health checks count.
   - **Rate limited.** No app is restarted more than `MAX_RESTARTS` (3) times an hour. After that, the watchdog stops trying and sends a high-priority "needs a look" notification, so a broken app can't restart-loop forever. Starts during boot don't count toward the limit.
3. **DEVONthink databases.** If DEVONthink is configured, the watchdog makes sure the databases in `DEVONTHINK_DATABASES` are open, since DEVONthink's web server only serves open databases.
4. **System health.** It warns when the startup disk has less than `MIN_FREE_GB` (20 GB) free, when memory pressure has stayed high for `MEMORY_PRESSURE_RUNS` (10) runs in a row (naming the three processes using the most memory, so you know where to look), and when traffic to `NAS_HOST` is going over Wi-Fi instead of Ethernet. That last one is easy to miss: macOS can quietly move Wi-Fi above Ethernet in the network service order, and then file sharing and Time Machine run over Wi-Fi.
5. **Local media folder guard (optional).** Folders in `LOCAL_MEDIA_GUARD` should stay empty, such as Music's default local media folder when the real one is on a share. If an app starts before the share is mounted, it can quietly fall back to its local default, and new files landing there are the first sign of it. The watchdog warns as soon as one appears, and the warning clears once they're removed. Files already there when the guard is first set up are ignored.
6. **Heartbeat (optional).** If `HEARTBEAT_URL` is set, for example to an [Uptime Kuma](https://github.com/louislam/uptime-kuma) push monitor, the watchdog requests it at the end of every run. If the watchdog stops running, or the Mac goes down entirely, the pings stop and your monitor tells you, which the watchdog can't do for itself.

After a reboot, you get a notification when the Mac comes back up (from [`log-reboot.sh`](#log-reboot)), and another from the watchdog once everything is running — listing what it started — or, if something still isn't up after 15 minutes, a high-priority one saying what's wrong. Outside of boot, you get one notification when something goes down, and one when it comes back; nothing in between, however many times the watchdog checks.

### Dialogs

Every time the watchdog does something, it shows a small dialog that closes itself after a few seconds, so anyone watching the screen (over screen sharing, say) can see what's happening:

- During startup: *"Mac mini is starting its services. Checking network shares…"*, *"Waiting for network share plexmedia…"*, *"Starting Plex Media Server…"*, … *"All Mac mini services are running."*
- Later: *"Music wasn't running. Starting it…"*, *"DEVONthink isn't responding. Restarting it…"*, *"Network share scandocs has been missing for 3 min. Remounting it…"*

Dialogs are queued and shown one at a time, in order. They never wait for a click, so a dialog can't stall the watchdog.

### Finding apps: bundle ids and creator codes

Apps are identified by bundle id (`com.plexapp.plexmediaserver`), or by creator code with a `creator:` prefix. DEVONthink changes its name and bundle id between major versions ("DEVONthink 3" → "DEVONthink"), but its creator code stays `DNtp` — so `creator:DNtp` keeps working through upgrades. This is the same reason [the DEVONthink AppleScript docs](https://download.devontechnologies.com/download/devonthink/3.8.2/DEVONthink.help/Contents/Resources/pgs/automation-basics.html) recommend `application id "DNtp"`.

The watchdog looks the app up by reading `Info.plist` files in `/Applications` and `/System/Applications`, and caches where it found it. It deliberately does **not** use AppleScript's `path to application id "…"`: that launches the app as a side effect, which would start it before its shares are ready.

### Installing

1. Copy the scripts to `/Applications` and make them executable:
   ```
   cp scripts/mac-server-watchdog.sh scripts/pushover-notify.sh scripts/log-reboot.sh scripts/log-event.sh scripts/before-update.sh /Applications/
   chmod 755 /Applications/mac-server-watchdog.sh /Applications/pushover-notify.sh /Applications/log-reboot.sh /Applications/log-event.sh /Applications/before-update.sh
   ```
2. Copy [`watchdog.conf.example`](watchdog.conf.example) to `~/.config/mac-server-watchdog.conf` and edit it for your server: your NAS, shares, and apps, in the order you want them started, with the shares each one needs. Find an app's bundle id with `osascript -e 'id of app "Plex Media Server"'`.
3. Set up [notifications](#notifications).
4. Try it without changing anything. Dry-run mode prints what it *would* do — start, quit, mount, notify — without doing it:
   ```
   DRY_RUN=1 zsh /Applications/mac-server-watchdog.sh
   ```
   With everything already running and healthy, it should print nothing at all.
5. Install the LaunchAgent:
   ```
   cp LaunchAgents/com.admin.mac-server-watchdog.plist ~/Library/LaunchAgents/
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.admin.mac-server-watchdog.plist
   ```
6. Remove the server apps from Login Items (see above), and reboot to test. The first time the watchdog quits or controls an app, macOS may ask for permission (**System Settings > Privacy & Security > Automation**) — click **Allow**.

To stop it: `launchctl bootout gui/$(id -u)/com.admin.mac-server-watchdog`.

The watchdog keeps its state in `~/Library/Application Support/mac-server-watchdog/` (safe to delete; it starts fresh), and writes events and its own errors to the log file set in the config. Errors from before the config is read (a missing or broken config file) go to `/tmp/mac-server-watchdog.log`.

### Why the rewrite

The earlier design was an AppleScript startup app plus a monitor script. It worked — about half the time. Over 90 days, the startup app ran 33 times and finished 18. The reasons, which the watchdog is built around:

- **All-or-nothing startup.** The startup script launched *nothing* until *every* network share was mounted. If one share was slow, every app waited — forever, if it never came back.
- **A dialog could freeze it.** On an error, it showed `display alert` — which waits for someone to click OK. On an unattended server, nobody does, and the rest of the startup never ran. The watchdog's dialogs all close themselves.
- **"Running" isn't "working."** Checking that an app is running misses the common failure where it's running but hung. The watchdog requests the app's health URL.
- **Overreaction.** Any brief share drop made the monitor quit *every* app and rerun the whole startup — and with it checking every 10 seconds, it could send a notification every 10 seconds. The watchdog waits out short drops, only touches apps that depend on the missing share, and only notifies on changes.
- **The slowest way to find the NAS.** Mounting via the Bonjour service name (`mynas._smb._tcp.local`) is the least reliable right after boot. Use `mynas.local` or a fixed IP.

A few macOS behaviors worth knowing if you write your own:

- **launchd kills a job's leftover processes when it exits.** Anything started in the background (`&`) — a notification being sent, a dialog — dies with the run. Notifications are therefore sent synchronously, and the LaunchAgent sets `AbandonProcessGroup` so the dialog queue survives.
- **`path to application id` launches the app.** See above.
- **Privacy protections apply to background jobs too.** A log file on the Desktop can't be read over SSH without full disk access, and background scripts may be refused as well; the default log location is `~/Library/Logs/`.

## Notifications

### Pushover

[Link](scripts/pushover-notify.sh)

Notifications go through [Pushover](https://pushover.net). Create an application for the server at <https://pushover.net/apps/build> (giving the server its own name and icon in the Pushover app), then put your credentials in `~/.pushover-creds`, readable only by you (`chmod 600 ~/.pushover-creds`):

```
export PUSHOVER_USER="<YOUR_USER_KEY>"
export PUSHOVER_TOKEN="<APP_API_TOKEN>"
```

Test it with `/Applications/pushover-notify.sh "Test" "Hello from the server"`.

Priorities: normal for down / back / startup notifications, high for "gave up" and "startup finished with problems".

### Home Assistant (alternative)

[Link](scripts/hass-notify-iphone.sh)

To notify through Home Assistant instead, set `NOTIFY_CMD="/Applications/hass-notify-iphone.sh"` in the watchdog config (and `notify_cmd` in `log-reboot.sh`). It takes the same "Title" "Message" arguments.

This integration uses Home Assistant, the idea taken from [an article written by Viktor Mukha](https://medium.com/@viktor.mukha/push-notifications-from-bash-script-via-home-assistant-852fa92f60ab). I modified it to take both the title and message as arguments.

You'll need a [Home Assistant](https://www.home-assistant.io) (HASS) server, and a mobile device with the HASS [Companion App](https://companion.home-assistant.io). [Setting up Home Assistant](https://www.home-assistant.io/installation/) itself is outside the scope of this document, but you can see the linked article above for more information on how to configure this script for your particular setup. However, I noticed a few differences from his original instructions in the GUI I currently see in HASS.

- The Bearer `<LONG_TERM_TOKEN>` is an access token that you can set up HASS. Go to your **User** page (click on your name in the lower left), click on **Security** tab, and scroll to the bottom, to the section **Long-lived access tokens**. Here, you can create a token.
- `http://homeassistant.local:8123` is the most likely address for your HASS server, but if you have a different one, you'll need to change that.
- The `<MOBILE_APP_NAME>`, at the end of the API endpoint, is specific to the name you have given your mobile device. Viktor's directions to find this are basically correct: Go to **Settings > Automations & scenes > Automations**, click **+ CREATE AUTOMATION**, then **Create New Automation**, and in the **Then do** section, **+ ADD ACTION** and search for `send a notification`. If you have several mobile apps, you will see a list that looks mostly like "Notifications: Send a notification via mobile_app_\<name\>". Find the one with the \<name\> that matches the name of your device, and that will be the value you need for the script. For instance, if my iPhone is called "Ianthe", the value I am looking for is probably `mobile_app_ianthe`.

## Helper scripts

### Before Update

[Script](scripts/before-update.sh)

Run this just before installing a macOS update:

```
zsh /Applications/before-update.sh
```

It stops the watchdog, then quits the apps the watchdog manages (read from its config), last-started first, so macOS has nothing to reopen after the update restart. It only asks apps to quit. If one won't (an unsaved document, say), it tells you so you can deal with it, and never force-quits. After the restart, the watchdog loads at login as usual and starts each app once its shares are mounted. Changed your mind? `zsh /Applications/before-update.sh --undo` starts the watchdog again, and it relaunches the apps within a minute.

### Log Reboot

[Link](scripts/log-reboot.sh)

For a while, I was having trouble with the server kernel panicking, and so I wanted to make sure that I was notified any time the server rebooted. This is meant to run as a LaunchAgent, once on boot. It differs from the `log-event` script below, in that it grabs the latest boot time from `sysctl` for accuracy, instead of relying on the current time when this script runs. Since it runs right at login, when the network may not be up yet, it retries the notification for about two minutes.

[The LaunchAgent, `com.admin.log-reboot.plist`](LaunchAgents/com.admin.log-reboot.plist) should be placed in the folder `~/Library/LaunchAgents/`, and then registered with this command:

```
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.admin.log-reboot.plist
```

### Log Event

[Link](scripts/log-event.sh)

This simply logs events into a text log file, for easy reading, from your own scripts. This is not meant to substitute for full system logs in troubleshooting a problem, but provide a very narrow list of server-related events which may warrant further investigation. The event description is prefaced with a roughly ISO 8601 style date-time string, for easy reading. The watchdog writes to the same log, in the same format, with events prefixed `watchdog:`.

A typical reboot looks like this:

```
2026-09-30 14:50:13 PDT - REBOOT
2026-09-30 14:50:37 PDT - watchdog: DOWN plex: Plex Media Server was not running
2026-09-30 14:50:37 PDT - watchdog: starting Plex Media Server
2026-09-30 14:50:38 PDT - watchdog: starting Sonos
2026-09-30 14:50:39 PDT - watchdog: starting Music
2026-09-30 14:50:40 PDT - watchdog: starting DEVONthink
2026-09-30 14:50:44 PDT - watchdog: starting Mail
2026-09-30 14:51:46 PDT - watchdog: RECOVERED plex
2026-09-30 14:51:46 PDT - watchdog: startup complete
```
