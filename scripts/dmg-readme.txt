ColimaBar
=========

1. Drag ColimaBar into the Applications folder.
2. Open ColimaBar from Applications.

First launch
------------
ColimaBar is not notarized by Apple. The first time you open it, macOS shows
"Apple could not verify ColimaBar". Do this one time:

1. Click Done.
2. Open System Settings > Privacy & Security.
3. Scroll down. Next to "ColimaBar was blocked", click Open Anyway.
4. Enter your password, then click Open Anyway again.

Or run this command in Terminal, then open ColimaBar:

    xattr -dr com.apple.quarantine /Applications/ColimaBar.app

To skip these steps, install with the one-line installer instead:

    curl -fsSL https://raw.githubusercontent.com/imohitkr/colima-bar/main/scripts/install.sh | bash

Requirements: a Mac with Apple silicon, macOS 14 or later, Colima (brew install colima docker).
More: https://github.com/imohitkr/colima-bar
