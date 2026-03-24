# Quitty

[English] | [简体中文](README_zh.md)

**Quitty** is a lightweight, modern macOS utility that automatically terminates applications when their last window is closed. It is designed to be a robust, high-performance, and macOS Tahoe-compatible alternative to older tools like SwiftQuit.

[![Download Quitty](https://img.shields.io/badge/Download-Latest%20Release-blue?style=for-the-badge&logo=apple)](https://github.com/chentao1006/quitty/releases/latest)

## 🚀 Key Features

-   **Automatic Termination**: Quits apps instantly (or with a delay) when you close their last window.
-   **macOS Tahoe Ready**: Uses raw Accessibility API (`AXObserver`) for maximum compatibility with macOS 16.
-   **Smart Filtering**:
    *   **Include Mode**: Only quit applications in your specific list.
    *   **Exclude Mode**: Quit all applications except for those you want to keep running.
-   **Configurable Delay**: Set a custom grace period (0-5 seconds) before an app is terminated.
-   **Launch at Login**: Seamlessly starts with your Mac.
-   **Settings Sync**: Synchronize your settings and excluded apps across machines using a JSON sync file (perfect for iCloud Drive).
-   **Built-in Diagnostics**: Integrated logging and health checks to ensure the monitoring engine is running smoothly.

## 🛠 Installation

### 1. Download Latest Release (Recommended)
Download the latest version as a DMG file from the [Releases Page](https://github.com/chentao1006/Quitty/releases). 
Simply open `Quitty.dmg` and drag **Quitty** to your `Applications` folder.

### 2. Build from Source
You can also build and install Quitty directly from source using the provided script.

1.  Clone this repository to your local machine.
2.  Open Terminal and navigate to the project directory.
3.  Run the installation script:
    ```bash
    chmod +x build_and_install.sh
    ./build_and_install.sh
    ```
4.  The script will compile the project in Release mode and install `Quitty.app` to your `/Applications` folder.

## 📖 Usage & Setup

### 1. Accessibility Permissions
Quitty requires **Accessibility Permissions** to monitor window events across other applications.
-   Upon first launch, Quitty will prompt you to grant access.
-   Go to `System Settings > Privacy & Security > Accessibility` and ensure Quitty is enabled.
-   If the engine doesn't start, use the **Run Diagnostic** button in the Troubleshooting tab.

### 2. Configuration
Open the Settings window from the menu bar icon (the "X" icon).
-   **General**: Toggle "Launch at Login" and adjust the "Quit Delay".
-   **App List**: 
    -   Choose between **Include Mode** (Quit Only These) or **Exclude Mode** (Quit All Except These).
    -   Add apps by clicking the `+` button and selecting them from your Applications folder.
-   **Data**: Enable "File Sync" to keep your app list and settings in a JSON file on your iCloud Drive or Dropbox.

## 🔍 How It Works (Technical Overview)

Unlike some tools that rely on high-level frameworks which broke in recent macOS updates, Quitty uses a direct approach:
1.  It monitors `NSWorkspace` notifications for app launches and terminations.
2.  For each target app, it attaches a raw C-based `AXObserver` to the process.
3.  It listens for the `AXWindowClosed` notification.
4.  When triggered, it performs a non-blocking check of the app's current window list.
5.  If the count is zero (excluding drawers and sheets), it schedules a termination via `NSRunningApplication.terminate()`.

## ⚠️ Important Notes

-   **System Apps**: Quitty is hard-coded to ignore critical system processes (Finder, Dock, Spotlight, Control Center, etc.) to ensure system stability.
-   **Safety First**: If the Accessibility API fails to return a valid window count, Quitty will abort the quit process rather than risk "killing" an app that might still have active windows.
-   **Development Tools**: It is recommended to add IDEs (like Xcode, VS Code) to the exclusion list to prevent unexpected closures during compilation or background tasks.

## 📝 Notes

Due to macOS security mechanisms and the fact that each app may use its own window management and technical implementation, Quitty cannot guarantee to fully quit every application in all scenarios. We always follow a conservative principle to avoid quitting apps that are still in use, but 100% accuracy cannot be guaranteed. If you encounter apps that cannot be quit or are quit incorrectly, please submit an issue ([submit here](https://github.com/chentao1006/quitty/issues)) and I will try to investigate when possible. Thank you for your understanding and support!

## 🛡 License

This project is provided "as is" under the MIT License.
