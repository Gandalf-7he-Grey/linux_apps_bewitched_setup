#!/bin/bash
#linux_setup_wizard_v3.3
echo -e "\e[91m"linux_setup_wizard_v3.3"\e[0m"

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
log_success "Updating and upgrading the system done!"

# Download Google Chrome Debian package
log_warning "Downloading Google Chrome..."
wget -q https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb -O google-chrome-stable_current_amd64.deb;
log_success "Google Chrome Debian package downloaded successfully!"

# Install Google Chrome
log_warning "Installing Google Chrome..."
sudo dpkg --install google-chrome-stable_current_amd64.deb

log_warning "Fixing broken dependencies..."
sudo apt --fix-broken install -y

log_warning "Installing Google Chrome..."
sudo dpkg --install google-chrome-stable_current_amd64.deb


# Delete the downloaded package to free up space
log_warning "Deleting downloaded Google Chrome package..."
rm google-chrome-stable_current_amd64.deb

# Launch Google Chrome
#log_warning "Launching Google Chrome..."
#google-chrome

# Install Brave browser
log_warning "Installing Brave Browser..."
sudo apt install curl
sudo curl -fsSLo /usr/share/keyrings/brave-browser-archive-keyring.gpg https://brave-browser-apt-release.s3.brave.com/brave-browser-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/brave-browser-archive-keyring.gpg] https://brave-browser-apt-release.s3.brave.com/ stable main" | sudo tee /etc/apt/sources.list.d/brave-browser-release.list
sudo apt update
sudo apt install brave-browser -y
log_warning "Fixing broken dependencies..."
sudo apt --fix-broken install -y
sudo apt install brave-browser -y
log_success "Brave browser installed successfully."

# Launch Brave browser
#log_warning "Launching Brave browser..."
#brave-browser


# Download and extract the Tor Browser
log_warning "Downloading Tor Browser..."
sudo apt install tor torbrowser-launcher -y
log_success "Tor dowloaded and extracted!"

# Download Discord Debian package
log_warning "Downloading Discord..."
wget -q "https://discord.com/api/download?platform=linux&format=deb" -O discord.deb

# Install Discord
log_warning "Installing Discord..."
sudo dpkg --install discord.deb

log_warning "Fixing broken dependencies..."
sudo apt --fix-broken install -y
sudo dpkg --install discord.deb
log_success "Discord done!"

# Download and install Telegram Desktop
log_warning "Downloading Telegram Desktop..."
wget -q "https://telegram.org/dl/desktop/linux" -O telegram.tar.xz && tar -xf telegram.tar.xz
log_success "Telegram Desktop downloaded and extracted successfully."

# Download and install Obsidian Markdown editor
log_warning "Downloading Obsidian Markdown editor..."
wget -q "https://github.com/obsidianmd/obsidian-releases/releases/download/v1.4.5/obsidian_1.4.5_amd64.deb" -O obsidian.deb
log_success "Obsidian Markdown editor package downloaded successfully."

# Install Obsidian
log_warning "Installing Obsidian Markdown editor..."
sudo dpkg --install obsidian.deb
log_warning "Fixing broken dependencies..."
sudo apt --fix-broken install -y

# Download and install Sublime Text 3
log_warning "Downloading Sublime Text 3..."
wget -q "https://download.sublimetext.com/sublime-text_build-3211_amd64.deb" -O sublime-text.deb
log_success "Sublime Text 3 package downloaded successfully."

# Install Sublime Text 3
log_warning "Installing Sublime Text 3..."
sudo dpkg --install sublime-text.deb
log_warning "Fixing broken dependencies..."
sudo apt --fix-broken install -y

# Download and install Terminator
log_warning "Installing Terminator terminal..."
sudo apt install terminator -y
log_success "Terminator terminal installed successfully."
sudo apt --fix-broken install -y
sudo apt install terminator -y

# Download and install Flameshot
log_warning "Installing screenshot tool Flameshot..."
sudo apt install apt install flameshot -y
log_warning "Fixing broken dependencies..."
sudo apt --fix-broken install -y
sudo apt install apt install flameshot -y
log_success "Flameshot installed successfully."

# Download and install assetfinder
# log_warning "Installing subdomain searching tool assetfinder..."
# go get -u github.com/tomnomnom/assetfinder
# log_warning "Fixing broken dependencies..."
# log_success "assetfinder installed successfully."

#Unpacking rockyou.txt
log_warning "Unpacking rockyou.txt"
sudo gunzip /usr/share/wordlists/rockyou.txt.gz


# Installing Go
log_warning "Installing Go"
sudo apt install golang-go -y

log_warning "Fixing broken dependencies..."
sudo apt --fix-broken install -y

log_warning "Installing Go"
sudo apt install golang-go -y
log_success "Go installed!"

#Dowloading and installing assetfinder
log_warning "Dowloading and installing assetfinder"
go install github.com/tomnomnom/assetfinder@latest

log_warning "Fixing broken dependencies..."
sudo apt --fix-broken install -y

log_warning "Dowloading and installing assetfinder"
go install github.com/tomnomnom/assetfinder@latest
log_success "assetfinder installed!"
