ColimaBar
=========

Requirements: a Mac with Apple silicon, macOS 14 or later, and Colima.
To install Colima, run: brew install colima docker

1. Drag ColimaBar into the Applications folder.
2. Open ColimaBar from Applications.

First launch
------------
Apple does not notarize ColimaBar. Thus the first launch shows
"Apple could not verify ColimaBar". Do these steps one time:

1. Click Done.
2. Open System Settings > Privacy & Security.
3. Scroll down. Next to "ColimaBar was blocked", click Open Anyway.
4. Enter your password, then click Open Anyway again.

As an alternative, run this command in Terminal, then open ColimaBar:

    xattr -dr com.apple.quarantine /Applications/ColimaBar.app

The installer does not need these steps. To use the installer, run this
command in Terminal:

    curl -fsSL https://raw.githubusercontent.com/imohitkr/colima-bar/main/scripts/install.sh | bash

More information: https://github.com/imohitkr/colima-bar

ColimaBar is an independent project. It is not part of Colima, and the
Colima maintainers do not support it. Report problems at the link above.
