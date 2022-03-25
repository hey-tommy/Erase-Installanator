#!/bin/bash
#
# Erase-Installanator v1.2
#
# This will allow you to use eraseinstall from a USB stick with a Monterey installer
# just by double-clicking, typing in a password, and walking away like a bossss
#
# Works on any Monterey machine - including M1s!
#
# It will capture the account password immediately and not make you wait the 3-5 mins
# while it verifies the installer's integrity - because we all know you're going to start
# the script, walk away, come back an hour later and facepalm at the --passprompt ;)
#
# Drop this into a .command file & throw it the root of a USB stick with a Monterey installer.
# Double-cick .command file to run, type in the pass (validated immediately), and go do
# something better with your time!


# versionCompare Function
#
# Converts a versions into a numerically comparable number

function versionCompare 
{ 
    # Parameter format:    versionCompare [version]

    echo "$@" | awk -F. '{ printf("%d%03d%03d%03d\n", $1,$2,$3,$4); }'
}


# dialogOutput Function
#
# Displays an AppleScript dialog

function dialogOutput ()
{
    # Parameter format:    dialogOutput [dialogText] 
    #                        (optional: [iconName]) 
    #                        (optional: [fallbackIcon]) 
    #                        (optional: [buttonsList])   *** see below 
    #                        (optional: [defaultButton]) 
    #                        (optional: [dialogAppTitle]) 
    #                        (optional: [dialogTimeout]) 
    #                        (optional: [returnButtonClickedVarName]) 
    #                        (optional: [returnValuesViaPipes] {bool}) 
    #
    #      *** Each button name should be double-quoted, then comma-delimited. 
    #          Pass this entire parameter surrounded with single quotes. Also, 
    #          while there is no way to have NO buttons in AppleScript dialogs, 
    #          any button can be made blank by setting the button name to an empty 
    #          string (i.e ""). Lastly, if this parameter is omitted entirely, 
    #          the dialog will automatically get an OK and Cancel buttons. 
    #
    #      Note: function parameters are positional. If skipping an optional 
    #      parameter, but not skipping the one that follows it, replace the 
    #      skipped parameter with an empty string (i.e. "") 
    

    # Check dialog icon resources & prepare icon path for dialog

    local dialogText="$1"
    local dialogIcon
    local iconPath

    # shellcheck disable=2154
    if [[ -n "$2" ]]; then
        if [[ ("$2" != "note") && ("$2" != "caution") && ("$2" != "stop") ]]; then
            if [[ -f "${2}" ]]; then
                iconPath="${2}"
            elif [[ -f "$scriptDirectory"/"${2}" ]]; then
                iconPath="$scriptDirectory"/"${2}"
            elif [[ -f "$scriptDirectory"/Resources/"${2}" ]]; then
                iconPath="$scriptDirectory"/Resources/"${2}"
            elif [[ -f "$(dirname "$scriptDirectory")"/Resources/"${2}" ]]; then
                iconPath="$(dirname "$scriptDirectory")"/Resources/"${2}"
            fi

            if [[ -n "$iconPath" ]]; then
                dialogIcon="with icon alias POSIX file \"$iconPath\""
            elif [[ ("$3" == "note") || ("$3" == "caution") || ("$3" == "stop") ]]; then
                dialogIcon="with icon $3"
            else
                dialogIcon="with icon note"
            fi
        else
            dialogIcon="with icon $2"
        fi
    else
        dialogIcon=""
    fi

    if [[ -n "$4" ]]; then
        local dialogButtonsList="buttons {$4}"    
        if [[ -n "$5" ]]; then
            local dialogDefaultButton="default button \"$5\""; fi
    fi

    if [[ -n "$6" ]]; then
        local dialogAppTitle="$6"; fi

    if [[ -n "$7" ]]; then
        local dialogTimeout="giving up after $7"; fi

    local dialogContent
    read -r -d '' dialogContent <<-EOF
	display dialog "$dialogText" with title "$dialogAppTitle" $dialogButtonsList \
	$dialogDefaultButton $dialogIcon $dialogTimeout
	EOF

    # Display dialog box
    local dialogPID
    local dialogReturned
    local buttonClicked
    
    mkfifo /tmp/dialogReturned
    exec 3<> /tmp/dialogReturned
    unlink /tmp/dialogReturned
    
    launchctl asuser "$currentUserAccountUID" osascript -e "$dialogContent" 1>&3 \
    & dialogPID=$!
    
    # Return dialog PID immediately, if requested
    if [[ -n "$9" ]]; then
        echo "$dialogPID" 1>&5
    fi
    read -r -u3 dialogReturned
    exec 3>&-
    
    buttonClicked="$(echo "$dialogReturned" \
                   | sed -E 's/^button returned:(, )?(.*)$/\2/')"
    
    # Return button clicked, if requested
    if [[ -n "$9" ]]; then
        echo "$buttonClicked" 1>&6
    elif [[ -n "$8" ]]; then
        export -n "${8}"="$buttonClicked"
    fi
}


# checkArchMacOSVersion Function
#
# Verifies that macOS version is compatible with tool

function checkArchMacOSVersion ()
{
    # Parameter format: none
    
    if [[ $(versionCompare "$(sw_vers -productVersion)") \
      -lt $(versionCompare "11.5") && $(uname -m) == "arm64" ]]; then

        dialogOutput \
            "Since this is an Apple Silicon Mac, and its macOS version is older `
            `than 11.5, eraseinstall is not possible.\n\n`
            `It is recommended to instead let this tool first upgrade this Mac `
            `to macOS 12 (Monterey), then use Monterey's built-in Erase All `
            `Content and Settings feature to wipe.\n\n" \
            "caution" \
            "" \
            '"Upgrade to macOS 12 without wiping","Exit"' \
            "Upgrade to macOS 12 without wiping" \
            "Eraseinstall not possible - upgrade without wiping?" \
            "" \
            "upgradeOrExit" 

            # shellcheck disable=2154
            if [[ "$upgradeOrExit" != 'Upgrade to macOS 12 without wiping' ]]; then
    	        exit 1
            else
    	        upgradeOnly=1
            fi

    fi
}


# Determine current logged-in user account
# shellcheck disable=2012
currentUserAccount="$(ls -la /dev/console | cut -d " " -f 4)"

# Determine UID
currentUserAccountUID=$(dscl . -read "/Users/$currentUserAccount" UniqueID | awk '{print $2}')

# Determine currently connected WiFi SSID
connectedSSID=$(/System/Library/PrivateFrameworks/Apple80211.framework/Versions/Current/Resources/airport -I | awk -F:  '($1 ~ "^ *SSID$"){print $2}' | cut -c 2-)

checkArchMacOSVersion

# Exit if current logged-in user is non-admin
if dseditgroup -o checkmember -m "$currentUserAccount" admin|grep -q -w ^no; then
	echo 
	echo Current logged-in user must be an admin!
	echo
	exit 1
fi

# Initialize pass prompt variables
askForPassword=1
passwordRetries=0

# Obtain and validate current logged-in user's password
while [[ ! "$askForPassword" == 0 ]] && [[ $passwordRetries -lt 5 ]]; do   # Using string comparison for 1st term because that's what dscl returns later in the while loop
	if [[ ! $passwordRetries -gt 0 ]]; then   # Define password capture dialog boxes
		read -r -d '' applescriptCode <<EOF
        set dialogText to text returned of (display dialog "Please enter this Mac admin account's password:" default answer "" buttons {"Continue"} default button "Continue" with hidden answer)
return dialogText
EOF
    else
        read -r -d '' applescriptCode <<EOF
		set dialogText to text returned of (display dialog "The password your entered is incorrect.

Please re-enter this Mac admin account's password:" default answer "" buttons {"Continue"} default button "Continue" with hidden answer)
return dialogText
EOF
    fi

    # Display capture password dialog box
    currentUserAccountPass="$(/bin/launchctl asuser "$currentUserAccountUID" osascript -e "$applescriptCode")"

    # Validate password
    askForPassword=$(dscl . authonly "$currentUserAccount" "$currentUserAccountPass"; echo $?)
    
    ((passwordRetries++))
    
    done

# Exit after 5 incorrect password entry attempts
if [[ ! "$askForPassword" == 0 ]]; then
    echo
    echo Failed to provide the correct user password after 5 tries - exiting!
    echo
    exit 1
fi  

# Cache sudo token before running startosinstall to avoid having an ugly "Password:" string
# inserted in the beginning of startosinstall's output if piping directly into that command
# (hiding it via redirection of stderr would unfortunately hide any errors - and we all know
# eraseinstall is riddled with issues on M1s - so we def want that stderr untouched.

echo "$currentUserAccountPass" | sudo -S echo > /dev/null 2>&1   # Cache sudo token

if [[ "upgradeOnly" -ne 1 ]]; then

    echo
    echo Preparing for eraseinstall process...
    echo

    echo
    echo "Forgetting current WiFi network ($connectedSSID)"
    echo "(and disconnecting from it in 15 minutes)..."
    echo
    (sleep 900 && networksetup -setnetworkserviceenabled Wi-Fi off && networksetup -setnetworkserviceenabled Wi-Fi on ) & sudo networksetup -removepreferredwirelessnetwork en0 "$connectedSSID"
    sudo nvram -c &> /dev/null    
    echo

    echo
    echo Please wait 3-5 minutes while the macOS installer integrity is verified.
    echo
    echo
    echo Verifying macOS installer integrity...
    echo 

	# Run eraseinstall process
	sudo sh -c "echo $currentUserAccountPass | /Volumes/Install\ macOS\ Monterey/Install\ macOS\ Monterey.app/Contents/Resources/startosinstall --eraseinstall --nointeraction --agreetolicense --forcequitapps --user $currentUserAccount --stdinpass"

else

    echo
    echo Preparing for upgrade-only process...
    echo

    echo
    echo Please wait 3-5 minutes while the macOS installer integrity is verified.
    echo
    echo
    echo Verifying macOS installer integrity...
    echo 

	# Run upgrade process
	sudo sh -c "echo $currentUserAccountPass | /Volumes/Install\ macOS\ Monterey/Install\ macOS\ Monterey.app/Contents/Resources/startosinstall --nointeraction --agreetolicense --forcequitapps --user $currentUserAccount --stdinpass"

fi

