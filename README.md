# [Linux Apps Setup Witchcraft](https://github.com/Gandalf-7he-Grey/linux_apps_bewitched_setup/blob/root/README.md#linux-setup-witchcraft) v4.0.0

### [Introduction](https://github.com/Gandalf-7he-Grey/linux_apps_bewitched_setup/blob/root/README.md#introduction) 

This Bash script automates the process of setting up and installing various applications on a Linux system. It performs the following tasks:

1. Updates and upgrades the system.
2. Fixes any broken dependencies.
3. Downloads and installs Google Chrome.
4. Downloads and installs Brave browser.
5. Downloads and extracts the Tor Browser.
6. Downloads and installs Yandex browser.
7. Downloads and installs Discord.
8. Downloads and installs Telegram Desktop.
9. Downloads and installs Obsidian Markdown editor.
10. Downloads and installs Sublime Text 3.
11. Installs Terminator.
12. Installs LibreOffice.
13. Installs Flameshot.
14. Installs qBittorrent.
15. Unpacks rockyou.txt.
16. Installs SecLists.
17. Installs Go.
18. Downloads and installs the assetfinder tool.

While it works, Gandalf stirs his cauldron on the right side of the terminal, the output of the commands scrolls on the left and a progress bar on the last line shows how much of the script is done.

The script also:

- skips apps that are already installed (so it is safe to run it again),
- tries every step a second time if it fails,
- logs any errors encountered during execution in a log file and prints a summary at the end.

---

### [Usage](https://github.com/Gandalf-7he-Grey/linux_apps_bewitched_setup/blob/root/README.md#usage)

1. Make sure you have Bash installed on your Linux system.
    
2. Download the script to your system.
    
3. Open a terminal and navigate to the directory where the script is located.
    
4. Make the script executable with the following command:
    
    > chmod +x linux_apps_setup_wizard.sh
    
5. Run the script with bash & root privileges:
    
    You may be prompted to enter your password for sudo access.
    
    > sudo bash linux_apps_setup_wizard.sh

Options (optional):

- `--demo` plays the animation with fake tasks, nothing is installed.
- `--no-animation` plain text output, no picture and no progress bar.
- `--ascii` Gandalf drawn with plain ASCII characters.
- `--stacked` picture on top and output below it (the old layout).

---


### [Error Handling](https://github.com/Gandalf-7he-Grey/linux_apps_bewitched_setup/blob/root/README.md#error-handling)

- Any errors encountered during the execution of the script will be logged in a file named `error_log.txt`.
- Errors will be displayed in red text for easy identification.
- A step that fails is tried a second time. If it still fails, it is skipped and listed in the summary at the end.
