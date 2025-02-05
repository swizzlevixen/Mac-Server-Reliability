# Mac Server Reliability

Helpful notes, and a suite of scripts written for my Mac mini M2 server, that help with server reliability, and notifications of errors. This server currently runs Plex, DEVONthink Server, Sonos, and Apple Music.

The scripts in this repo have some sensitive information replaced with placeholders, for privacy. Otherwise they should be an accurate representation of what is running on my server.

## Automatically log in on startup

Due to the nature of the apps that I'm using on this server, the Mac needs to run with a user logged in. This is accomplished with **System Settings > Users & Groups > Automatically log in as…** and select the user. Note that [FileVault must be disabled](https://support.apple.com/guide/mac-help/a-login-window-start-mac-mchlp1158/15.0/mac/15.0) for automatic login to be available. Yes, that's less secure, but this Mac lives in an equipment rack in my home, and if someone we don't trust has physical access to that machine, we have bigger problems.

## Energy Settings

We want this machine to always be running, and recover after a power failure or other interruption. So I have these settings:

- **System Settings > Login Password > Automatically login after a restart**: on
- **System Settings > Energy > Prevent automatic sleeping when the display is off**: on
- **System Settings > Energy > Wake for network access**: on
- **System Settings > Energy > Start up automatically after a power failure**: on
- **Lock Screen > (the top group of three settings)**: Never

## Login items

You can easily [set apps and network drives to launch when the user logs in](https://support.apple.com/guide/mac-help/open-items-automatically-when-you-log-in-mh15189/mac). Go to **System Settings > General > Login Items & Extensions** and you can either drag items into the **Open at Login** list, or use the **+** button at the bottom of the list.

Currently in the list:

- CCC Dashboard (Carbon Copy Cloner, for backups)
- `scandocs` network drive, from the Synology `mynas` NAS
- `plexmedia` network drive, from the Synology `mynas` NAS
- Screens Connect (for remote access)
- Startup Apps and Databases (app version of the AppleScript, see below)

## Startup Apps and Databases

[Link](scripts/Startup%20Apps%20and%20Databases%20Script.scpt)

Of course, there are more apps that we need to be running on this server, but I was running into two issues when putting them all in the Login Items list — this M2 Mac mini is _so fast_ that the apps would start up before the network drives were connected, and would not have the necessary files available. The second issue, we'll get to in a moment.

To solve this, I wrote the [Startup Apps and Databases](scripts/Startup%20Apps%20and%20Databases%20Script.scpt) AppleScript. This script expects to launch as a Login Item, waits to make sure that the network drives have mounted, and then launches the server apps one by one, giving a few seconds between each one, to make sure they get a chance to start up smoothly.

Much of this is very specific to my setup. Change the name of the network drives and apps for the ones that you need to launch. You can also change the delay between apps by modifying `theInterval` variable at the top.

> NOTE: I used `application id "DNtp"` to reference DEVONthink, since this is recommended in [the DEVONthink AppleScript docs](https://download.devontechnologies.com/download/devonthink/3.8.2/DEVONthink.help/Contents/Resources/pgs/automation-basics.html) so that when the app updates to a new version, and changes its name (e.g., “DEVONthink 3” to “DEVONthink 4”), the ID will remain the same. 

I could have partially done this as a shell script, as I have several other parts of this server monitoring and setup workflow, but AppleScript allowed me to easily show dialogs with information about what was happening, and allow user interaction to cancel if something is going wrong. It also allows me to easily open the necessary databases in DEVONthink for web sharing.

The shell scripts called by this AppleScript are simple helper scripts to write to a log file, and send a notification theough Home Assistant, and they will be discussed later.

### Export AppleScript as an App

To allow for the correct permissions to control everything, when it runs on its own, the script needs to be signed, and that means exporting it as an Application. Any time you make changes to the Startup script, follow these steps:

1. Open **Script Editor**
2. Open `Startup Apps and Databases Script.scpt`
3. Edit the script as necessary
4. Save the script
5. **File > Export**, delete `Script` from the name of the file, and save in the `Applications` folder, with **File Format: Application**, and **Code Sign: Sign to Run Locally**
6. **Replace** if it asks
7. If this is your first time adding the script, use the instructions in the **Login Items** section above to add it as a Login Item. This exported app version of the script is the one that should run every time the Mac boots.
7. Run the app once, and allow it to manage the computer when asked. This will be in **System Settings > Privacy & Security > App Management**
8. You may also need to give it permission to to write to disk, since it is writing to the log file. It will ask for permission, but this is in **System Settings > Privacy & Security > Full Disk Access**, if you want to add it manually.
8. Run it again, to make sure it runs without complaint about permissions
9. Reboot the Mac and let the script run on startup, to confirm all is well

### The second problem

If the Mac reboots abnormally (kernel panic, power loss, etc.), it “helpfully” automatically re-opens all previously running apps, which defeats my carefully crafted startup sequence.

[The solution](https://superuser.com/questions/338004/prevent-mac-from-reloading-apps-after-restart) is to close all open apps, and then find the `.plist` that saves information about which apps are currently running, that the Mac uses to re-open the apps when you reboot. Look for this file:

```
~/Library/Preferences/ByHost/com.apple.loginwindow.*.plist
```

The `*` will be a long random character identifier. Select the file in the Finder, and then **File > Get Info** (⌘-I) to open the Info window for the file. In the General section, check the **Locked** box, and close the window. This will prevent macOS from changing the contents of the file, and no other apps will be opened if the Mac reboots abnormally.

If it becomes necessary, you can easily revert this behavior by unchecking the box in the Info window.

## Helper Scripts

To give myself a little more information about any potential problems, I have scripts that add events to a log file, or send a notification to my iPhone.

### Log Event

[Link](scripts/log-event.sh)

This simply logs events into a text log file, for easy reading. This is not meant to substitute for full system logs in troubleshooting a problem, but provide a very narrow  list of server-related events which may warrant further investigation. The event description is prefaced with a roughly ISO 8601 style date-time string, for easy reading.

### Send Notification to iPhone

[Link](scripts/hass-notify-iphone.sh)

This integration uses Home Assistant, the idea taken from [an article written by Viktor Mukha](https://medium.com/@viktor.mukha/push-notifications-from-bash-script-via-home-assistant-852fa92f60ab). I modified it to take both the title and message as arguments.

You'll need a [Home Assistant](https://www.home-assistant.io) (HASS) server, and a mobile device with the HASS [Companion App](https://companion.home-assistant.io). [Setting up Home Assistant](https://www.home-assistant.io/installation/) itself is outside the scope of this document, but you can see the linked article above for more information on how to configure this script for your particular setup. However, I noticed a few differences from his original instructions in the GUI I currently see in HASS.

- The Bearer `<LONG_TERM_TOKEN>` is an access token that you can set up HASS. Go to your **User** page (click on your name in the lower left), click on **Security** tab, and scroll to the bottom, to the section **Long-lived access tokens**. Here, you can create a token.
- `http://homeassistant.local:8123` is the most likely address for your HASS server, but if you have a different one, you'll need to change that.
- The `<MOBILE_APP_NAME>`, at the end of the API endpoint, is specific to the name you have given your mobile device. Viktor's directions to find this are basically correct: Go to **Settings > Automations & scenes > Automations**, click **+ CREATE AUTOMATION**, then **Create New Automation**, and in the **Then do** section, **+ ADD ACTION** and search for `send a notification`. If you have several mobile apps, you will see a list that looks mostly like “Notifications: Send a notification via mobile_app_\<name\>”. Find the one with the \<name\> that matches the name of your device, and that will be the value you need for the script. For instance, if my iPhone is called “Ianthe”, the value I am looking for is probably `mobile_app_ianthe`.

### Log Reboot

[Link](scripts/log-reboot.sh)

For a while, I was having trouble with the server kernel panicking, and so I wanted to make sure that I was notified any time the server rebooted. This is meant to run as a LaunchAgent, once on boot. It differs from the `log-event` script above, in that it grabs the latest boot time from `sysctl` for accuracy, instead of relying on the current time when this script runs.

[The LaunchAgent, `com.admin.log-reboot.plist`](LaunchAgents/com.admin.log-reboot.plist) should be placed in the folder `~/Library/LaunchAgents/`, and then registered with this command:

```
launchctl bootstrap gui/<ADMIN_USER_ID> ~/Library/LaunchAgents/com.admin.log-reboot.plist
```

`<ADMIN_USER_ID>` can be found by running `id -u <USERNAME>` for the user which your server is normally logged in as.

### Monitor Network Drives

[Link](scripts/monitor-network-drives.sh)

This script came about because the curent version of macOS Sequoia has an issue connecting over SMB to some Synology drive shares, and sometimes the drives disconnect unexpectedly. So now I have this script that is registered as a LaunchAgent that runs every 10 seconds, to make sure the drives are still connected, and if not, to log and notify me, reconnect them, and restart any necessary apps that rely on them.

It uses `osascript` (a command line version of AppleScript) to quit the affected apps, because this allows the apps to quit gracefully, as opposed to just killing them without warning.

[The LaunchAgent, `com.admin.monitor-network-drives.plist`](LaunchAgents/com.admin.monitor-network-drives.plist) should be placed in the folder `~/Library/LaunchAgents/`, and then registered with this command:

```
launchctl bootstrap gui/<ADMIN_USER_ID> ~/Library/LaunchAgents/com.admin.monitor-network-drives.plist
```
