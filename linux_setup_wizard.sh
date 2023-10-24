#!/bin/bash
#linux_setup_wizard_v2.1
echo -e "\e[91m"linux_setup_wizard_v2.1"\e[0m"

# Create a log file to collect errors
ERROR_LOG="error_log.txt"
touch "$ERROR_LOG"

# Function to log errors in red and display them at the end
log_error() {
    local error_message="$1"
    echo -e "\e[91m$error_message\e[0m"  # Print in red
    echo "$error_message" >> "$ERROR_LOG"
}

# Function to log messages in green
log_success() {
    local success_message="$1"
    echo -e "\e[32m$success_message\e[0m"  # Print in green
}

# Function to log messages in yellow
log_warning() {
    local warning_message="$1"
    echo -e "\e[93m$warning_message\e[0m"  # Print in yellow
}

# Update and upgrade the system
log_warning "Updating and upgrading the system..."
sudo apt update
sudo apt upgrade -y

# Fix any broken dependencies
log_warning "Fixing broken dependencies..."
sudo apt --fix-broken install -y

# Update and upgrade again after fixing dependencies
log_warning "Updating and upgrading the system again..."
sudo apt update
sudo apt upgrade -y

# Download Google Chrome Debian package
log_warning "Downloading Google Chrome..."
if wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -O google-chrome-stable_current_amd64.deb; then
    log_success "Google Chrome Debian package downloaded successfully."

    # Install Google Chrome
    log_warning "Installing Google Chrome..."
    sudo dpkg --install google-chrome-stable_current_amd64.deb

    # Delete the downloaded package to free up space
    log_warning "Deleting downloaded Google Chrome package..."
    rm google-chrome-stable_current_amd64.deb

    # Launch Google Chrome
    log_warning "Launching Google Chrome..."
    google-chrome
else
    log_error "Error: Failed to download Google Chrome Debian package."
fi

# Install Brave browser
log_warning "Installing Brave Browser..."
sudo apt install curl

sudo curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg

echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" | sudo tee /etc/apt/sources.list.d/brave-browser-release.list

sudo apt update
sudo apt install brave-browser -y

if [ $? -eq 0 ]; then
    log_success "Brave browser installed successfully."

    # Launch Brave browser
    log_warning "Launching Brave browser..."
    brave-browser
else
    log_error "Error: Failed to install Brave browser."
fi

# Download and extract the Tor Browser
log_warning "Downloading Tor Browser..."
if wget -q https://www.torproject.org/dist/torbrowser/12.5.3/tor-browser-linux64-12.5.3_ALL.tar.xz -O tor-browser-linux64-12.5.3.tar.xz && tar -xf tor-browser-linux64-12.5.3.tar.xz; then
    log_success "Tor Browser downloaded and extracted successfully."

    # Navigate into the tor-browser directory
    cd tor-browser

    # Run the start-tor-browser.desktop script to start Tor Browser
    log_warning "Running Tor Browser..."
    ./start-tor-browser.desktop
    cd ..
else
   log_error "Error: Failed to download or extract Tor Browser."
fi

# Download Discord Debian package
log_warning "Downloading Discord..."
if wget -q "https://discord.com/api/download?platform=linux&format=deb" -O discord.deb; then
    log_success "Discord Debian package downloaded successfully."

    # Install Discord
    log_warning "Installing Discord..."
    if sudo dpkg --install discord.deb; then
        # Launch Discord
        log_warning "Launching Discord..."
        discord
    else
        log_warning "Fixing broken dependencies..."
        sudo apt --fix-broken install -y
        sudo dpkg --install discord.deb
        # Launch Discord
        log_warning "Launching Discord..."
        discord
    fi
else
    log_error "Error: Failed to download Discord Debian package."
fi

# Download and install Telegram Desktop
log_warning "Downloading Telegram Desktop..."
if wget -q "https://telegram.org/dl/desktop/linux" -O telegram.tar.xz && tar -xf telegram.tar.xz; then
    log_success "Telegram Desktop downloaded and extracted successfully."

    # Navigate into the Telegram Desktop directory
    #cd Telegram

    # Run the Telegram Desktop executable
   # log_warning "Running Telegram Desktop..."
   # ./Telegram
   # cd ..
else
    log_error "Error: Failed to download or extract Telegram Desktop."
fi

# Download and install Obsidian Markdown editor
log_warning "Downloading Obsidian Markdown editor..."
if wget -q "https://github.com/obsidianmd/obsidian-releases/releases/download/v1.4.5/obsidian_1.4.5_amd64.deb" -O obsidian.deb; then
    log_success "Obsidian Markdown editor package downloaded successfully."

    # Install Obsidian
    log_warning "Installing Obsidian Markdown editor..."
    if sudo dpkg --install obsidian.deb; then
        # Launch Obsidian Markdown editor
        log_warning "Launching Obsidian Markdown editor..."
        obsidian
    else 
        log_warning "Fixing broken dependencies..."
        sudo apt --fix-broken install -y
        sudo dpkg --install obsidian.deb
        # Launch Obsidian Markdown editor
        log_warning "Launching Obsidian Markdown editor..."
        obsidian
    fi
else
    log_error "Error: Failed to download Obsidian Markdown editor package."
fi

# Download and install Sublime Text 3
log_warning "Downloading Sublime Text 3..."
if wget -q "https://download.sublimetext.com/sublime-text_build-3211_amd64.deb" -O sublime-text.deb; then
    log_success "Sublime Text 3 package downloaded successfully."

    # Install Sublime Text 3
    log_warning "Installing Sublime Text 3..."
    if sudo dpkg --install sublime-text.deb; then
        # Launch Sublime Text 3
        log_warning "Launching Sublime Text 3..."
        subl
    else
        log_warning "Fixing broken dependencies..."
        sudo apt --fix-broken install -y
        sudo dpkg --install sublime-text.deb
        # Launch Sublime Text 3
        log_warning "Launching Sublime Text 3..."
        subl
    fi
else
    log_error "Error: Failed to download Sublime Text 3 package."
fi

# Download and install Terminator
log_warning "Installing Terminator terminal..."
if sudo apt install terminator -y
    log_success "Terminator terminal installed successfully."
elif
    sudo apt --fix-broken install -y
    sudo apt install terminator -y
else
    log_error "Can't install terminator"

# Download and install Flameshot
log_warning "Installing screenshot tool Flameshot..."
if sudo apt install apt install flameshot -y
    log_success "Flameshot installed successfully."
elif
    sudo apt --fix-broken install -y
    sudo apt install flameshot -y
else
    log_error "Can't install flameshot"
#Unpacking rockyou.txt
log_warning "Unpacking rockyou.txt"
if sudo gunzip /usr/share/wordlists/rockyou.txt.gz
    log_success "rockyou.txt unpacked successfully"
else
    log_error "Can't unpack rockyou.txt"
