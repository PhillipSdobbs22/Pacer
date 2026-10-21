# Pacer Setup Guide (beginner)

Goal: go from nothing to a project on GitHub that runs a blank app on your iPhone and Apple Watch. After that, Claude writes the code stage by stage and you paste it in.

Menu names below come from memory of recent Xcode versions. If something looks different in Xcode 26.6, take a screenshot and send it to Claude.

## Part 0: What you need
- A Mac with Xcode 26.6 installed (Mac App Store)
- A GitHub account (free): github.com/signup
- An Apple ID (the one on your iPhone is fine)
- GitHub Desktop (free): desktop.github.com
- Your iPhone 13 Pro, its charging cable, and your Apple Watch

## Part 1: First launch of Xcode
1. Open **Xcode** from Applications. Agree to the license and let it install any extra components.
2. If asked, install the **iOS** and **watchOS** platforms. You can also do this later in **Xcode > Settings > Components**.
3. Sign in to your Apple ID: **Xcode > Settings > Accounts**, click **+**, choose **Apple ID**, and sign in. You should see a "Personal Team" listed.

## Part 2: Create the GitHub repository
1. Go to github.com and sign in. Click the **+** at the top right, then **New repository**.
2. Repository name: `Pacer`.
3. Choose **Private**.
4. Check **Add a README file**.
5. Under **Add .gitignore**, choose **Swift**. Leave the license empty.
6. Click **Create repository**.

## Part 3: Copy the repo to your Mac (clone)
1. Open **GitHub Desktop** and sign in to GitHub.
2. **File > Clone Repository**, choose `Pacer` from the list, and note the local path (for example Documents/GitHub/Pacer). Click **Clone**.
3. In GitHub Desktop, choose **Repository > Show in Finder** to open that folder.
4. Put these files in the folder: replace `README.md` with Claude's version, and create a `docs` folder holding `DESIGN.md` and `SETUP.md`.

## Part 4: Create the Xcode project
1. In Xcode: **File > New > Project**.
2. Choose the **iOS** tab, then **App**, then **Next**.
3. Fill in:
   - Product Name: `Pacer`
   - Team: your Personal Team
   - Organization Identifier: `com.` plus your last name in lowercase, such as `com.dobbs`
   - Interface: **SwiftUI**
   - Language: **Swift**
   - Storage / Testing: **None** (or leave tests unchecked)
4. Click **Next**. When asked where to save, pick your cloned `Pacer` folder.
5. **Uncheck "Create Git repository on my Mac"**, since the folder is already a repo. Click **Create**.
6. Add the Watch app: **File > New > Target**, choose the **watchOS** tab, then **App**, then **Next**. Name it `PacerRun`. If it offers a choice, pick the option for a Watch app that goes with your existing iPhone app, and select `Pacer` as the companion. Click **Finish**. If asked to activate a scheme, click **Activate**.
7. Set minimum versions: click the blue project icon at the top of the left sidebar, then each target under **Targets**, then the **General** tab, then **Minimum Deployments**. Set the iPhone app to **iOS 17.0** and the Watch app to **watchOS 10.0**.

## Part 5: Signing and capabilities
Do this for **both** targets (the iPhone app and the Watch app).
1. Select the target, then the **Signing & Capabilities** tab.
2. Check **Automatically manage signing** and choose your Personal Team.
3. If you see "bundle identifier is not available," change the Organization Identifier to something more unique (for example `com.dobbs26`).
4. Click **+ Capability** and add **HealthKit**.
5. On the **Watch** target only, click **+ Capability** again and add **Background Modes**, then check **Workout processing**.
6. Open the target's **Info** tab. Under Custom Target Properties, click **+** to add two rows:
   - **Privacy - Health Share Usage Description**: "Pacer reads your heart rate and calories to power the climb."
   - **Privacy - Health Update Usage Description**: "Pacer saves your workouts to Health."
   Do this on both targets.

## Part 6: Prepare your devices
1. Plug in your iPhone and unlock it. Tap **Trust This Computer** if asked.
2. In Xcode, open **Window > Devices and Simulators**. Your iPhone should appear. Your paired Watch should appear under it.
3. iPhone: **Settings > Privacy & Security > Developer Mode** (it may only show up after step 2). Turn it on and restart when asked.
4. Watch: **Settings > Privacy & Security > Developer Mode**. Turn it on and restart if asked. Keep the Watch unlocked, on your wrist, and near the iPhone.

## Part 7: First test run
1. At the top of Xcode, set the scheme to `Pacer` and the destination to your iPhone. Click the **Run** (play) button.
2. If the iPhone says "Untrusted Developer," go to **Settings > General > VPN & Device Management**, tap your Apple ID, and tap **Trust**. Run again.
3. Set the scheme to the Watch app (`PacerRun`) and the destination to your Watch. Click **Run**.
4. Success looks like a "Hello, world" screen on each device.

**Key check:** If your Watch isn't listed, or Xcode says its OS version isn't supported, stop and send Claude the exact message. We need a workaround before building further.

## Part 8: Save to GitHub
1. Open **GitHub Desktop**. The new files appear in the left list.
2. Type a summary such as `Initial Xcode project, README, docs`, then click **Commit to main**.
3. Click **Push origin**. Refresh github.com to see your files.
Do this after every working stage.

## Part 9: How we work after setup
1. Claude writes the Swift code for a stage.
2. In Xcode, create a file with **File > New > File > Swift File**, paste the code, and save. Or replace the code in an existing file.
3. Press **Cmd+B** to build. Errors appear as red markers and in the left **Issue navigator** (the triangle icon).
4. Press **Cmd+R** to run on your device.
5. Send Claude any error text exactly, or a screenshot.
6. When the stage works, commit and push (Part 8).

## Troubleshooting
- **Developer Mode missing on iPhone or Watch:** connect to Xcode first, then check again.
- **Watch not listed:** unlock it, keep it near the iPhone, restart both, and reopen Devices and Simulators.
- **App stops opening after about 7 days:** free Apple ID installs expire. Run it again from Xcode.
- **No heart rate in the simulator:** heart rate only works on your real Watch.
- **Signing errors:** recheck that the Team is set on both targets and the bundle identifiers are unique.
