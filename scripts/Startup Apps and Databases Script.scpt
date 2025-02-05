(*
Startup Apps and Databases
Copyright © 2024-2025 Mark Boszko
*)

-- Delay interval to wait between steps, in seconds
set theInterval to 5

-- Log start
do shell script "zsh /Applications/log-event.sh \"Startup Apps and Databases: running...\""

(*
*************************
Synology network drives
*************************
- Make sure the network drives are mounted
- Once they are, start the apps that are dependent on the files
*)

-- Grab the server drive icon
set GenericFileServerIcon to POSIX file "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericFileServerIcon.icns"

-- delay after boot, then see if the network drives are mounted
set diskMounted to false
repeat until diskMounted is true
	-- Check if the network drive is mounted
	tell application "System Events" to set diskNames to name of every disk
	if "plexmedia" is in diskNames and "scandocs" is in diskNames then
		set diskMounted to true
		tell me to activate
		display dialog "plexmedia and scandocs network drives are mounted.
Launching apps dependent on availability." buttons {"Cancel"} default button 1 with icon GenericFileServerIcon giving up after theInterval
	else
		-- Try to mount it again
		tell application "Finder"
			mount volume "smb://mynas._smb._tcp.local/plexmedia"
			mount volume "smb://mynas._smb._tcp.local/scandocs"
		end tell
		tell me to activate
		display dialog "Waiting for plexmedia and scandocs network drives to mount.
Retrying in " & theInterval & " seconds" as text buttons {"Cancel"} default button 1 with icon GenericFileServerIcon giving up after theInterval
	end if
end repeat

(*
*************************
Plex Media Server
*************************
- Launch it
*)

-- Grab the app icon
set appIcon to POSIX file "/Applications/Plex Media Server.app/Contents/Resources/Plex.icns"
tell me to activate
display dialog "Launching Plex" as text buttons {"Cancel"} default button 1 with icon appIcon giving up after theInterval
tell application "Plex Media Server"
	activate
end tell

(*
*************************
Sonos
*************************
- Launch it
*)

-- Grab the app icon
set appIcon to POSIX file "/Applications/Sonos.app/Contents/Resources/AppIcon.icns"
tell me to activate
display dialog "Launching Sonos" as text buttons {"Cancel"} default button 1 with icon appIcon giving up after theInterval
tell application "Sonos.app"
	activate
end tell

(*
*************************
Apple Music (with iTunes Match)
*************************
- Launch it
*)

-- Grab the app icon
set appIcon to POSIX file "/System/Applications/Music.app/Contents/Resources/AppIcon.icns"
tell me to activate
display dialog "Launching Music" as text buttons {"Cancel"} default button 1 with icon appIcon giving up after theInterval
tell application "Music"
	activate
end tell

(*
*************************
DEVONthink
*************************
- Launch it
- Open the Databases that I always want to have open in DEVONthink
    - Add any new databases to the list in databaseNames
*)


-- Grab the app icon
set appIcon to POSIX file "/Applications/DEVONthink 3.app/Contents/Resources/DEVONthink 3.icns"
tell me to activate
display dialog "Launching DEVONthink and loading databases" as text buttons {"Cancel"} default button 1 with icon appIcon giving up after theInterval
property databaseFolderPath : "/Users/admin/Databases/"
property databaseNames : {"My Scans", "Shared", "Other Scans"}

tell application id "DNtp"
	activate
	-- Give it a moment to launch
	delay theInterval
	try
		repeat with databaseName in databaseNames
			open database (databaseFolderPath & databaseName & ".dtBase2") as string
			
			-- open window for record (root of database databaseName)
			-- activate
			delay theInterval
		end repeat
		
	on error error_message number error_number
		if the error_number is not -128 then display alert "DEVONthink" message error_message as warning
	end try
end tell

--Log completion
do shell script "zsh /Applications/log-event.sh \"Startup Apps and Databases: completed\""
--Send notification to Mark's iPhone that services have restarted
do shell script "zsh /Applications/hass-notify-callisto.sh  \"Skyfall Notification\" \"Startup Apps and Databases: completed\""
