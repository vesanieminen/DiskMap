# DiskMap

A tiny native macOS 15 disk-space viewer inspired by SpaceMonger 1.4. It uses nested rectangles whose area is proportional to each file or folder's allocated size.

## Build

Install Apple's Command Line Tools, then run:

```sh
./build.sh
open build/DiskMap.app
```

There is no Xcode project, dependency download, or package-manager step. The app is one Swift source file and uses only AppKit.

### Keep privacy access between builds

The build script automatically uses the first code-signing identity in your Keychain. You can select one explicitly:

```sh
CODESIGN_IDENTITY="Apple Development: Your Name" ./build.sh
```

A stable Apple Development, Developer ID, or trusted local code-signing certificate lets macOS recognize rebuilt versions as the same app. Without one, the script falls back to an ad-hoc signature and macOS may request privacy access again after the executable changes. Use `security find-identity -v -p codesigning` to list available identities.

For private local builds, no developer account is required: open **Keychain Access → Certificate Assistant → Create a Certificate**, choose **Self Signed Root** and **Code Signing**, and accept the remaining defaults. After it appears as a valid identity, run `./build.sh` normally; the script will find and use it automatically. You will need to approve DiskMap once more after switching identities, but later rebuilds keep the same privacy identity.

## Use

Click **Open** and choose a folder or mounted volume. Hover over any rectangle to see its full name and size. Double-click a folder to zoom in, or use **Zoom Out** and **Zoom Full** to navigate. Double-click a file to open it; **Reveal** shows the selection in Finder.

The treemap is fully keyboard navigable: use the arrow keys or **H/J/K/L** to move between rectangles, **Return** or **Control-I** to enter a folder, **Backspace** or **Control-O** to move up one level, and **Escape** to return to the full map. Press **?** or choose **Help → Keyboard Shortcuts** for the complete shortcut list.

macOS privacy protections may prevent access to some folders. To inspect everything, grant DiskMap Full Disk Access in **System Settings → Privacy & Security → Full Disk Access**.
