#!/bin/bash
#
# Erase-Installanator v1.0
#
# This will allow you to use eraseinstall from a USB stick with a Big Sur installer
# just by double-clicking, typing in a password, and walking away like a bossss
#
# Works on any Big Sur machine - including M1s!
#
# It will capture the account password immediately and not make you wait the 3-5 mins
# while it verifies the installer's integrity - because we all know you're going to start
# the script, walk away, come back an hour later and facepalm at the --passprompt ;)
#
# Drop this into a .command file & throw it the root of a USB stick with a Big Sur installer.
# Double-cick .command file to run, type in the pass (validated immediately), and go do
# something better with your time!


# Determine current logged-in user account
currentUserAccount="$(ls -la /dev/console | cut -d " " -f 4)"

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

    # Determine UID
    currentUserAccountUID=$(dscl . -read "/Users/$currentUserAccount" UniqueID | awk '{print $2}')

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

# Create a couple of random 16-bit hex strings to use as names for ephemeral password files.
# Using a file instead echo'ing the password as obfuscation to mitigate password being easily
# visible via ps. Making a point of keeping file names random and storing them for the least
# amount of time possible.

randomFileName1=$(xxd -l 16 -c 16 -p < /dev/random)
randomFileName2=$(xxd -l 16 -c 16 -p < /dev/random)

# Cache sudo token before running startosinstall to avoid having an ugly "Password:" string
# inserted in the beginning of startosinstall's output if piping directly into that command
# (hiding it via redirection of stderr would unfortunately hide any errors - and we all know
# eraseinstall is riddled with issues on M1s - so we def want that stderr untouched.

echo "$currentUserAccountPass" > /private/tmp/"$randomFileName1"   # Store password in file
cat /private/tmp/"$randomFileName1" | sudo -S echo > /dev/null 2>&1   # Cache sudo token
rm  /private/tmp/"$randomFileName1"   # Delete password file

echo
echo Please wait 3-5 minutes while the macOS Big Sur installer integrity is verified.
echo
echo
echo Verifying macOS installer integrity...
echo 

echo "$currentUserAccountPass" > /private/tmp/"$randomFileName2"   # Store password in file

# Run eraseinstall process and delete ephemeral password file a second later
(sleep 1; rm /private/tmp/"$randomFileName2") & sudo -S sh -c "cat /private/tmp/$randomFileName2 | /Volumes/Install\ macOS\ Big\ Sur/Install\ macOS\ Big\ Sur.app/Contents/Resources/startosinstall --eraseinstall --nointeraction --agreetolicense --forcequitapps --user $currentUserAccount --stdinpass"
