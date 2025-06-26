#!/usr/bin/env bash
IFS=$'\n\t'

# Every time this script is modified, the SCRIPT_VERSION must be incremented
SCRIPT_VERSION="1.0.42"

# Get current user's username
USERNAME=$(whoami)

# User email for git and SSH configuration
EMAIL="pal@subtree.se"

# Record start time
START_TIME=$(date +%s)

log(){
  if command -v gum &>/dev/null; then
    gum style --foreground 212 "$1"
  else
    printf "\n%s\n" "$1"
  fi
}

error(){
  if command -v gum &>/dev/null; then
    gum style --foreground 196 "ERROR: $1"
  else
    printf "\n\033[31mERROR: %s\033[0m\n" "$1"
  fi
  return 1
}

spin(){
  if command -v gum &>/dev/null; then
    gum spin --spinner dot --title "$1" -- "$2"
  else
    eval "$2"
  fi
}

need_cmd(){
  command -v "$1" &>/dev/null || { error "missing $1"; return 1; }
}

# ---- Intro banner ---------------------------------------------------------
log "⭐  mac-setup-script v$SCRIPT_VERSION ⭐"
log "This script will prepare a new Mac: Xcode, Homebrew, apps, defaults, repos, etc." \
    "\nYou'll be asked for your administrator password once so the script can run commands that require sudo.\n" \
    "After that it runs unattended — feel free to grab a coffee.\n"

# --------------------------------------------------------------------------

# Request sudo up-front with context for the user
log "🔑  Requesting sudo — please enter your macOS password if prompted."
sudo -v || error "Failed to get sudo access"
while true; do sudo -n true; sleep 60; kill -0 "$BASHPID" || exit; done 2>/dev/null &

ARCH=$(uname -m)
BREW_PREFIX="/opt/homebrew"
[[ "$ARCH" == "i386" || "$ARCH" == "x86_64" ]] && BREW_PREFIX="/usr/local"

# Install Rosetta 2 if on Apple Silicon
if [[ "$ARCH" == "arm64" ]]; then
  log "Installing Rosetta 2..."
  if ! /usr/bin/pgrep -q oahd; then
    sudo softwareupdate --install-rosetta --agree-to-license || error "Failed to install Rosetta 2"
  fi
fi

install_xcode_clt(){
  log "📦 Installing Xcode Command Line Tools..."
  if xcode-select -p &>/dev/null; then
    log "Xcode Command Line Tools already installed"
    return 0
  fi
  
  if ! xcode-select --install; then
    error "Failed to install Xcode Command Line Tools"
    return 1
  fi
  until xcode-select -p &>/dev/null; do 
    sleep 20
    if ! pgrep -q "Install Command Line Tools"; then
      error "Xcode Command Line Tools installation failed"
      return 1
    fi
  done
}

install_homebrew(){
  log "🍺 Installing Homebrew..."
  
  # First try to detect if brew is already available in PATH
  if command -v brew &>/dev/null; then
    BREW_PREFIX=$(brew --prefix)
    log "Homebrew already installed at $BREW_PREFIX"
    return 0
  fi
  
  # If not in PATH, check common installation locations
  if [[ -x "/opt/homebrew/bin/brew" ]]; then
    BREW_PREFIX="/opt/homebrew"
    eval "$(/opt/homebrew/bin/brew shellenv)" || error "Failed to source Homebrew environment"
    log "Homebrew already installed at $BREW_PREFIX"
    return 0
  elif [[ -x "/usr/local/bin/brew" ]]; then
    BREW_PREFIX="/usr/local"
    eval "$(/usr/local/bin/brew shellenv)" || error "Failed to source Homebrew environment"
    log "Homebrew already installed at $BREW_PREFIX"
    return 0
  fi
  
  # If not found, install Homebrew
  if ! NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
    error "Failed to install Homebrew"
    return 1
  fi
  
  # After installation, determine the correct prefix based on architecture
  if [[ "$ARCH" == "arm64" ]]; then
    BREW_PREFIX="/opt/homebrew"
  else
    BREW_PREFIX="/usr/local"
  fi
  
  # Verify Homebrew installation
  if [[ ! -f "$BREW_PREFIX/bin/brew" ]]; then
    error "Homebrew installation failed - could not find brew executable"
    return 1
  fi
  
  # Add Homebrew to PATH for all shells
  for shell_config in ~/.bash_profile ~/.zshrc ~/.config/fish/config.fish; do
    if [[ -f "$shell_config" ]]; then
      if ! grep -q "brew shellenv" "$shell_config"; then
        echo "eval \"($BREW_PREFIX/bin/brew shellenv)\"" >> "$shell_config" || error "Failed to update $shell_config"
      fi
    fi
  done
  
  # Source the environment for current shell
  eval "$($BREW_PREFIX/bin/brew shellenv)" || error "Failed to source Homebrew environment"
  
  # Verify Homebrew is working
  if ! brew doctor &>/dev/null; then
    log "Homebrew installation may have issues - please run 'brew doctor' for details"
  fi
}

accept_xcode_license(){
  log "📝 Accepting Xcode license..."
  if xcodebuild -license check &>/dev/null; then
    log "Xcode license already accepted"
    return 0
  fi
  sudo xcodebuild -license accept || error "Failed to accept Xcode license"
}

brew_bundle(){
  log "📦 Installing Homebrew packages and casks..."
  BREW_PKGS=(aws-cdk awscli bash direnv eza ffmpeg fish gh git jq libpq mas maven p7zip pkgconf pnpm postgresql@16 ripgrep subversion wget nx gum yarn)
  BREW_CASKS=(1password aws-vault beekeeper-studio cloudflare-warp cursor cyberduck devutils discord dropbox dynobase elgato-control-center figma rapidapi font-fira-code font-input font-inter font-jetbrains-mono font-roboto font-geist-mono ghostty google-chrome microsoft-teams mysides orbstack raycast session-manager-plugin slack telegram spotify visual-studio-code zoom chatgpt)
  
  # Get list of installed packages and casks once
  INSTALLED_PKGS=$(brew list --formula -1)
  INSTALLED_CASKS=$(brew list --cask -1)
  
  for f in "${BREW_PKGS[@]}"; do 
    if echo "$INSTALLED_PKGS" | grep -q "^${f}$"; then
      log "Package already installed: $f"
    else
      log "Installing package: $f"
      brew install "$f" || error "Failed to install $f"
    fi
  done
  
  for c in "${BREW_CASKS[@]}"; do 
    if echo "$INSTALLED_CASKS" | grep -q "^${c}$"; then
      log "Cask already installed: $c"
    else
      log "Installing cask: $c"
      brew install --cask "$c" || error "Failed to install $c"
    fi
  done
}

mas_install(){
  log "📱 Installing Mac App Store applications..."
  
  # Check if user is signed into Mac App Store by attempting to list apps
  if ! mas list &>/dev/null; then
    log "⚠️  You need to sign in to the Mac App Store to continue."
    log "1. The App Store will open in a moment"
    log "2. Sign in with your Apple ID"
    log "3. If you don't have an Apple ID, you can create one at appleid.apple.com"
    
    # Open App Store
    open -a "App Store"
    return 1
  else
    log "✅ Successfully signed in to Mac App Store"
  fi
  
  # Define apps as a string to avoid issues with spaces in names
  APPS_STR="Dato:1470584107
HEIC Converter:1294126402
Keynote:409183694
Magnet:441258766
Microsoft Excel:462058435
Microsoft OneNote:784801555
Microsoft Outlook:985367838
Microsoft PowerPoint:462062816
Microsoft To Do:1274495053
Microsoft Word:462054704
Numbers:409203825
OneDrive:823766827
Pages:409201541
Pixelmator Pro:1289583905
TestFlight:899247664
Valheim:1554294918
Xcode:497799835"

  # Get list of installed app IDs
  INSTALLED_APP_IDS=$(mas list 2>/dev/null | awk '{print $1}')
  
  # Count total apps to install
  total_apps=0
  apps_to_install=()
  while IFS=: read -r name id; do
    if ! echo "$INSTALLED_APP_IDS" | grep -qx "$id"; then
      ((total_apps++))
      apps_to_install+=("$name:$id")
    fi
  done <<< "$APPS_STR"
  
  if [ $total_apps -eq 0 ]; then
    log "All Mac App Store applications are already installed"
    return 0
  fi
  
  log "Found $total_apps apps to install"
  
  # Install apps with progress
  current=0
  for app in "${apps_to_install[@]}"; do
    IFS=: read -r name id <<< "$app"
    ((current++))
    log "Installing $name (ID: $id)... ($current/$total_apps)"
    if ! mas install "$id" 2>&1; then
      error "Failed to install $name (ID: $id)"
      return 1
    fi
  done
  
  return 0
}

set_names(){
  log "🏷️  Setting system names..."
  local HOST="${USERNAME}-macbookpro"
  local current_name=$(scutil --get ComputerName 2>/dev/null)
  
  if [[ "$current_name" == "$HOST" ]]; then
    log "System names already set correctly"
    return 0
  fi
  
  scutil --set ComputerName "$HOST" || error "Failed to set ComputerName"
  scutil --set HostName "$HOST" || error "Failed to set HostName"
  scutil --set LocalHostName "$HOST" || error "Failed to set LocalHostName"
  sudo defaults write /Library/Preferences/SystemConfiguration/com.apple.smb.server NetBIOSName -string "$HOST" || error "Failed to set NetBIOSName"
}

configure_defaults(){
  log "⚙️  Configuring system defaults..."
  
  # Ensure sudo access is still valid
  sudo -v || error "Lost sudo access - please run the script again"
  
  # Close any open System Preferences panes
  osascript -e 'tell application "System Settings" to quit' || osascript -e 'tell application "System Preferences" to quit' || true

  # Disable the sound effects on boot
  sudo nvram SystemAudioVolume=" " || true

  # Language & Region
  # Set system language to English
  defaults write NSGlobalDomain AppleLanguages -array "en" || true
  # Set locale to Swedish
  defaults write NSGlobalDomain AppleLocale -string "sv_SE" || true
  # Set measurement units to centimeters
  defaults write NSGlobalDomain AppleMeasurementUnits -string "Centimeters" || true
  # Use metric system
  defaults write NSGlobalDomain AppleMetricUnits -bool true || true
  # Set timezone to Stockholm
  sudo ln -sf /usr/share/zoneinfo/Europe/Stockholm /etc/localtime || true

  # Keyboard & Input
  # Disable automatic capitalization
  defaults write NSGlobalDomain NSAutomaticCapitalizationEnabled -bool false || true
  # Disable smart dashes
  defaults write NSGlobalDomain NSAutomaticDashSubstitutionEnabled -bool false || true
  # Disable automatic period substitution
  defaults write NSGlobalDomain NSAutomaticPeriodSubstitutionEnabled -bool false || true
  # Disable smart quotes
  defaults write NSGlobalDomain NSAutomaticQuoteSubstitutionEnabled -bool false || true
  # Disable auto-correct
  defaults write NSGlobalDomain NSAutomaticSpellingCorrectionEnabled -bool false || true
  # Disable press-and-hold for key repeat
  defaults write NSGlobalDomain ApplePressAndHoldEnabled -bool false || true
  # Set a fast keyboard repeat rate
  defaults write NSGlobalDomain KeyRepeat -int 2 || true
  # Set a short initial key repeat delay
  defaults write NSGlobalDomain InitialKeyRepeat -int 15 || true
  # Enable full keyboard access for all controls
  defaults write NSGlobalDomain AppleKeyboardUIMode -int 3 || true

  # Finder
  # Allow quitting Finder via ⌘Q
  defaults write com.apple.finder QuitMenuItem -bool true || true
  # Show hidden files by default
  defaults write com.apple.finder AppleShowAllFiles -bool true || true
  # Show all filename extensions
  defaults write NSGlobalDomain AppleShowAllExtensions -bool true || true
  # Show status bar in Finder
  defaults write com.apple.finder ShowStatusBar -bool true || true
  # Show path bar in Finder
  defaults write com.apple.finder ShowPathbar -bool true || true
  # Display full POSIX path as window title
  defaults write com.apple.finder _FXShowPosixPathInTitle -bool true || true
  # Keep folders on top when sorting by name
  defaults write com.apple.finder _FXSortFoldersFirst -bool true || true
  # Use list view in all Finder windows
  defaults write com.apple.finder FXPreferredViewStyle -string "Nlsv" || true
  # Expand File Info panes for General, Open with, and Sharing & Permissions
  defaults write com.apple.finder FXInfoPanesExpanded -dict \
    General -bool true \
    OpenWith -bool true \
    Privileges -bool true || true
  # Show the ~/Library folder
  chflags nohidden ~/Library || true
  # Show the /Volumes folder
  sudo chflags nohidden /Volumes || true

  # add favorites if they don't exist
  if ! mysides list | grep -q "Screenshots"; then
    mysides add Screenshots "file:///Users/${USERNAME}/Library/Mobile%20Documents/com~apple~CloudDocs/Screenshots/2025" || true
  fi
  if ! mysides list | grep -q "Home"; then
    mysides add Home "file:///Users/${USERNAME}" || true
  fi

  # Dock
  # Show indicator lights for open applications
  defaults write com.apple.dock show-process-indicators -bool true || true
  # Wipe all default app icons from the Dock
  defaults write com.apple.dock persistent-apps -array || true
  # Speed up Mission Control animations
  defaults write com.apple.dock expose-animation-duration -float 0.1 || true
  # Make Dock icons of hidden applications translucent
  defaults write com.apple.dock showhidden -bool true || true
  # Don't show recent applications in Dock
  defaults write com.apple.dock show-recents -bool false || true
  # Disable the Launchpad gesture
  defaults write com.apple.dock showLaunchpadGestureEnabled -int 0 || true
  # Set top right hot corner to show Desktop
  defaults write com.apple.dock wvous-tr-corner -int 4 || true
  # No modifier key for top right hot corner
  defaults write com.apple.dock wvous-tr-modifier -int 0 || true
  # Set bottom left hot corner to start screen saver
  defaults write com.apple.dock wvous-bl-corner -int 5 || true
  # No modifier key for bottom left hot corner
  defaults write com.apple.dock wvous-bl-modifier -int 0 || true

  # Screenshots
  # Save screenshots to iCloud Drive
  mkdir -p "/Users/${USERNAME}/Library/Mobile Documents/com~apple~CloudDocs/Screenshots/2025" || true
  defaults write com.apple.screencapture location -string "/Users/${USERNAME}/Library/Mobile Documents/com~apple~CloudDocs/Screenshots/2025" || true
  
  # Save screenshots in PNG format
  defaults write com.apple.screencapture type -string "png" || true
  # Disable shadow in screenshots
  defaults write com.apple.screencapture disable-shadow -bool true || true

  # Display
  # Enable subpixel font rendering on non-Apple LCDs
  defaults write NSGlobalDomain AppleFontSmoothing -int 1 || true
  # Enable HiDPI display modes
  # sudo defaults write /Library/Preferences/com.apple.windowserver DisplayResolutionEnabled -bool true || true

  # Mac App Store
  # Enable WebKit Developer Tools in App Store
  defaults write com.apple.appstore WebKitDeveloperExtras -bool true || true
  # Enable automatic update check
  defaults write com.apple.SoftwareUpdate AutomaticCheckEnabled -bool true || true
  # Check for updates daily
  defaults write com.apple.SoftwareUpdate ScheduleFrequency -int 1 || true
  # Download updates in background
  defaults write com.apple.SoftwareUpdate AutomaticDownload -int 1 || true
  # Install system data files & security updates
  defaults write com.apple.SoftwareUpdate CriticalUpdateInstall -int 1 || true
  # Turn on app auto-update
  defaults write com.apple.commerce AutoUpdate -bool true || true

  # Photos
  # Prevent Photos from opening automatically when devices are plugged in
  defaults -currentHost write com.apple.ImageCapture disableHotPlug -bool true || true

  # Chrome
  # Disable backswipe on trackpads
  defaults write com.google.Chrome AppleEnableSwipeNavigateWithScrolls -bool false || true
  # Disable backswipe on Magic Mouse
  defaults write com.google.Chrome AppleEnableMouseSwipeNavigateWithScrolls -bool false || true
  # Use system-native print preview dialog
  defaults write com.google.Chrome DisablePrintPreview -bool true || true
  # Expand print dialog by default
  defaults write com.google.Chrome PMPrintingExpandedStateForPrint2 -bool true || true
  # Always show bookmarks bar (for all profiles)
  defaults write com.google.Chrome ShowBookmarkBar -bool true || true
  defaults write com.google.Chrome BookmarkBarEnabled -bool true || true
  
  # Kill affected applications (excluding Terminal and iTerm2)
  # Restart applications to apply changes
  for app in "Activity Monitor" "Address Book" "Calendar" "cfprefsd" "Contacts" "Dock" "Finder" "Google Chrome" "Mail" "Messages" "Photos" "SizeUp" "Spectacle" "SystemUIServer" "Transmission" "iCal"; do
    killall "${app}" &> /dev/null || true
  done

  log "Done. Note that some of these changes require a logout/restart to take effect."
}

setup_fish(){
  log "🐟 Setting up Fish shell..."
  local shell_path="$BREW_PREFIX/bin/fish"
  
  # Check if fish is already set up
  if [[ "$SHELL" == *fish ]] && grep -q "$shell_path" /etc/shells 2>/dev/null; then
    log "Fish shell already set up"
  else
    # Add fish to /etc/shells if not already there
    grep -q "$shell_path" /etc/shells || echo "$shell_path" | sudo tee -a /etc/shells || error "Failed to add fish to /etc/shells"
    
    # Change shell to fish if not already set
    if [[ "$SHELL" != *fish ]]; then
      chsh -s "$shell_path" || error "Failed to change shell to fish"
    fi
  fi
  
  # Create fish config directory if it doesn't exist
  mkdir -p ~/.config/fish || error "Failed to create fish config directory"
  
  # Create or update fish config file with Homebrew environment
  cat > ~/.config/fish/config.fish <<EOF
# Homebrew environment
if test -f "$BREW_PREFIX/bin/brew"
    set -gx HOMEBREW_PREFIX "$BREW_PREFIX"
    set -gx HOMEBREW_CELLAR "$BREW_PREFIX/Cellar"
    set -gx HOMEBREW_REPOSITORY "$BREW_PREFIX"
    set -gx PATH "$BREW_PREFIX/bin" "$BREW_PREFIX/sbin" \$PATH
    set -gx MANPATH "$BREW_PREFIX/share/man" \$MANPATH
    set -gx INFOPATH "$BREW_PREFIX/share/info" \$INFOPATH
end

# Add Homebrew's sbin to PATH
if test -d "$BREW_PREFIX/sbin"
    set -gx PATH "$BREW_PREFIX/sbin" \$PATH
end

# Add Homebrew's bin to PATH
if test -d "$BREW_PREFIX/bin"
    set -gx PATH "$BREW_PREFIX/bin" \$PATH
end

# Add Bun to PATH
if test -d "$HOME/.bun/bin"
    set -gx BUN_INSTALL "$HOME/.bun"
    set -gx PATH "$HOME/.bun/bin" \$PATH
end
EOF
}

ghostty_config(){
  log "🖥️  Configuring Ghostty terminal..."
  
  mkdir -p ~/Library/Application\ Support/com.mitchellh.ghostty || error "Failed to create Ghostty config directory"
  cat > ~/Library/Application\ Support/com.mitchellh.ghostty/config <<'EOF' || error "Failed to write Ghostty config"
# see https://x.com/rauchg/status/1923842420778860803
theme = "Mathias"
font-family = "GeistMono NF"
font-size = 11
macos-titlebar-style = "tabs"
split-divider-color = "#222"
unfocused-split-opacity = 1
cursor-style = "block"
cursor-style-blink = false
cursor-color = "#B62EB2"
shell-integration-features = "no-cursor"
EOF
}

configure_git(){
  log "🔧 Configuring Git..."
  # Check if git is already configured
  if git config --global user.email &>/dev/null && git config --global user.name &>/dev/null; then
    log "Git already configured"
    return 0
  fi
  
  git config --global branch.autoSetupRebase always || error "Failed to set branch.autoSetupRebase"
  git config --global branch.autoSetupMerge always || error "Failed to set branch.autoSetupMerge"
  git config --global color.ui auto || error "Failed to set color.ui"
  git config --global core.autocrlf input || error "Failed to set core.autocrlf"
  git config --global core.editor code || error "Failed to set core.editor"
  git config --global credential.helper osxkeychain || error "Failed to set credential.helper"
  git config --global pull.rebase true || error "Failed to set pull.rebase"
  git config --global push.default simple || error "Failed to set push.default"
  git config --global rebase.autostash true || error "Failed to set rebase.autostash"
  git config --global rerere.autoUpdate true || error "Failed to set rerere.autoUpdate"
  git config --global rerere.enabled true || error "Failed to set rerere.enabled"
  git config --global user.email "${EMAIL}" || error "Failed to set user.email"
  git config --global user.name "Pål Brattberg" || error "Failed to set user.name"
}

install_nvm_node(){
  log "🟢 Installing Node.js and NVM..."
  # Check if NVM is already installed
  if [[ -d "$HOME/.nvm" ]]; then
    log "NVM already installed"
    return 0
  fi
  
  if ! curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/refs/heads/main/install.sh | bash; then
    error "Failed to install NVM"
    return 1
  fi
  
  export NVM_DIR="$HOME/.nvm"
  # shellcheck disable=SC1090
  if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    . "$NVM_DIR/nvm.sh"
  else
    error "NVM installation appears to be incomplete"
    return 1
  fi
  
  if ! nvm install --lts; then
    error "Failed to install Node.js LTS"
    return 1
  fi
  
  if ! nvm alias default "lts/*"; then
    error "Failed to set default Node.js version"
    return 1
  fi
}

setup_ssh_keys(){
  log "🔑 Setting up SSH keys for GitHub..."
  
  # Check if SSH key exists
  if [[ -f ~/.ssh/id_ed25519 ]]; then
    log "SSH key already exists"
    return 0
  fi
  
  log "Generating new SSH key..."
  ssh-keygen -t ed25519 -C "${EMAIL}" -f ~/.ssh/id_ed25519 -N "" || error "Failed to generate SSH key"
  
  # Start ssh-agent
  eval "$(ssh-agent -s)" || error "Failed to start ssh-agent"
  ssh-add ~/.ssh/id_ed25519 || error "Failed to add SSH key to ssh-agent"
  
  # Display public key for user to add to GitHub
  log "Please add this SSH key to your GitHub account:"
  cat ~/.ssh/id_ed25519.pub
  log "Press Enter once you've added the key to GitHub..."
  read -r
}

clone_repos(){
  log "📚 Cloning development repositories..."
  local BASE=~/dev
  mkdir -p "$BASE" || error "Failed to create dev directory"
  cd "$BASE" || error "Failed to change to dev directory"

  REPOS=(
    "peasy-master|git@github.com:pal/peasy.git#main"
    "peasy|git@github.com:pal/peasy.git#planetscale"
    "frankfurter|git@github.com:pal/frankfurter.git"
    "peasy_client|git@github.com:pal/peasy_client.git"
    "peasyv3|git@github.com:pal/peasyv3.git"
    "peasy-ui|git@github.com:subtree/peasy-ui.git"
    "saas-template|git@github.com:subtree/saas-template.git"
    "template-magic-board|git@github.com:subtree/template-magic-board.git"
    "setup-hosting|git@github.com:subtree/setup-hosting.git"
    "companynamemaker.com|git@github.com:subtree/companynamemaker.com.git"
    "juniormarketer.ai|git@github.com:subtree/juniormarketer.ai.git"
    "social-image-creator|git@github.com:subtree/social-image-creator.git"
    "saas-template-upptime|git@github.com:subtree/saas-template-upptime.git"
    "subtree-sites|git@github.com:subtree/subtree-sites.git"
    "subtree.se|git@github.com:subtree/subtree.se.git"
    "jujino.com|git@github.com:subtree/jujino.com.git"
    "julafton.com|git@github.com:subtree/julafton.com.git"
    "palbrattberg.com|git@github.com:pal/palbrattberg.com.git"
    "ai-pres|git@github.com:pal/ai-pres.git"
    "domainchecker|git@github.com:pal/domainchecker.git"
    "mousegame|git@github.com:pal/mousegame.git"
    "k8s-hosting|git@github.com:subtree/k8s-hosting.git"
    "opencontrol|git@github.com:toolbeam/opencontrol.git"
    # "productvoice|git@github.com:WeDoProducts/productvoice.git"
  )

  for entry in "${REPOS[@]}"; do
    dir=${entry%%|*}
    url_branch=${entry#*|}
    url=${url_branch%%#*}
    branch=${url_branch#*#}
    [[ "$branch" == "$url_branch" ]] && branch=""
    if [[ -d "$dir" ]]; then
      log "Repository already exists: $dir"
      continue
    fi
    if [[ -n $branch ]]; then
      git clone --single-branch --branch "$branch" "$url" "$dir" || error "Failed to clone $dir"
    else
      git clone "$url" "$dir" || error "Failed to clone $dir"
    fi
  done
}

post_install(){
  log "Post-installation steps:"
  log "1. Open and sign in to required apps:"
  log "   • 1Password"
  log "   • Dropbox"
  log "   • Google Chrome" 
  log "   • Magnet"
  log "   • Slack"
  log "   • Outlook"
  log "   • Teams"
  log "   • Spotify"
  log "   • Cursor"
  log "   • RapidAPI"
  log "2. Configure Dropbox selective sync."
}

prevent_sleep(){
  log "💤 Preventing system sleep during installation..."
  caffeinate -i &
  CAFFEINATE_PID=$!
  # Set up trap to restore sleep on script exit
  trap 'restore_sleep' EXIT
}

restore_sleep(){
  if [[ -n "${CAFFEINATE_PID:-}" ]]; then
    log "💤 Restoring normal sleep settings..."
    kill $CAFFEINATE_PID 2>/dev/null || true
  fi
}

check_manual_steps(){
  log "🔍 Checking manual steps..."
  local needs_manual_steps=false
  local manual_steps=()

  # Check Mac App Store login
  if ! mas list &>/dev/null; then
    needs_manual_steps=true
    manual_steps+=("Sign in to Mac App Store")
  fi

  # Check 1Password
  if ! osascript -e 'tell application "1Password" to get version' &>/dev/null; then
    needs_manual_steps=true
    manual_steps+=("Open and sign in to 1Password")
  fi

  # Check Dropbox
  if ! osascript -e 'tell application "Dropbox" to get version' &>/dev/null; then
    needs_manual_steps=true
    manual_steps+=("Open and sign in to Dropbox")
  fi

  # Check Chrome
  if ! osascript -e 'tell application "Google Chrome" to get version' &>/dev/null; then
    needs_manual_steps=true
    manual_steps+=("Open and sign in to Chrome")
  fi

  if $needs_manual_steps; then
    log "⚠️  Manual steps required:"
    for step in "${manual_steps[@]}"; do
      log "  • $step"
    done
    log "\nPlease complete these steps and run the script again."
    exit 0
  fi
}

# Install Bun (not available via Homebrew)
install_bun(){
  log "🍞 Installing Bun..."
  
  # Check if bun is already installed and working
  if command -v bun &>/dev/null && bun --version &>/dev/null; then
    log "Bun already installed (version $(bun --version))"
    return 0
  fi
  
  # Check if bun is installed but not in PATH
  if [[ -f "$HOME/.bun/bin/bun" ]]; then
    log "Bun is installed but not in PATH"
    # Add bun to PATH for all shells
    for shell_config in ~/.bash_profile ~/.zshrc ~/.config/fish/config.fish; do
      if [[ -f "$shell_config" ]]; then
        if [[ "$shell_config" == *fish* ]]; then
          if ! grep -q "set -gx BUN_INSTALL" "$shell_config"; then
            echo 'set -gx BUN_INSTALL "$HOME/.bun"' >> "$shell_config"
            echo 'set -gx PATH "$BUN_INSTALL/bin" $PATH' >> "$shell_config"
          fi
        else
          if ! grep -q "export BUN_INSTALL" "$shell_config"; then
            echo 'export BUN_INSTALL="$HOME/.bun"' >> "$shell_config"
            echo 'export PATH="$BUN_INSTALL/bin:$PATH"' >> "$shell_config"
          fi
        fi
      fi
    done
    # Source the environment for current shell
    export BUN_INSTALL="$HOME/.bun"
    export PATH="$BUN_INSTALL/bin:$PATH"
    return 0
  fi
  
  # Install bun if not found
  curl -fsSL https://bun.sh/install | bash || error "Failed to install Bun"
  
  # Add bun to PATH for all shells
  for shell_config in ~/.bash_profile ~/.zshrc ~/.config/fish/config.fish; do
    if [[ -f "$shell_config" ]]; then
      if [[ "$shell_config" == *fish* ]]; then
        if ! grep -q "set -gx BUN_INSTALL" "$shell_config"; then
          echo 'set -gx BUN_INSTALL "$HOME/.bun"' >> "$shell_config"
          echo 'set -gx PATH "$BUN_INSTALL/bin" $PATH' >> "$shell_config"
        fi
      else
        if ! grep -q "export BUN_INSTALL" "$shell_config"; then
          echo 'export BUN_INSTALL="$HOME/.bun"' >> "$shell_config"
          echo 'export PATH="$BUN_INSTALL/bin:$PATH"' >> "$shell_config"
        fi
      fi
    fi
  done
  
  # Source the environment for current shell
  export BUN_INSTALL="$HOME/.bun"
  export PATH="$BUN_INSTALL/bin:$PATH"
  
  # Verify installation
  if ! command -v bun &>/dev/null; then
    error "Bun installation failed - could not verify installation"
    return 1
  fi
}

install_aws_vault_latest(){
  log "🔒 Ensuring latest aws-vault from GitHub..."
  
  # Check if aws-vault is already installed and working
  if command -v aws-vault &>/dev/null && aws-vault --version &>/dev/null; then
    local current_version
    current_version=$(aws-vault --version | awk '{print $3}')
    log "aws-vault already installed (version $current_version)"
    
    # Check if we need to update
    local latest_version
    local arch
    arch=$(uname -m)
    if [[ "$arch" == "arm64" ]]; then
      latest_version=$(curl -s https://api.github.com/repos/99designs/aws-vault/releases/latest | grep browser_download_url | grep darwin-arm64 | cut -d '"' -f 4 | rev | cut -d '/' -f 1 | rev | sed 's/aws-vault-v//' | sed 's/-darwin-arm64//')
    else
      latest_version=$(curl -s https://api.github.com/repos/99designs/aws-vault/releases/latest | grep browser_download_url | grep darwin-amd64 | cut -d '"' -f 4 | rev | cut -d '/' -f 1 | rev | sed 's/aws-vault-v//' | sed 's/-darwin-amd64//')
    fi
    
    if [[ "$current_version" == "$latest_version" ]]; then
      log "aws-vault is already at the latest version"
      return 0
    fi
  fi
  
  # Get latest release URL for macOS arm64 or amd64
  local arch
  arch=$(uname -m)
  local asset_url
  if [[ "$arch" == "arm64" ]]; then
    asset_url=$(curl -s https://api.github.com/repos/99designs/aws-vault/releases/latest | grep browser_download_url | grep darwin-arm64 | cut -d '"' -f 4)
  else
    asset_url=$(curl -s https://api.github.com/repos/99designs/aws-vault/releases/latest | grep browser_download_url | grep darwin-amd64 | cut -d '"' -f 4)
  fi
  
  if [[ -z "$asset_url" ]]; then
    error "Could not find aws-vault release for your architecture"
    return 1
  fi
  
  # Download and install
  tmpfile=$(mktemp)
  curl -L "$asset_url" -o "$tmpfile" || { error "Failed to download aws-vault"; return 1; }
  chmod +x "$tmpfile"
  sudo mv "$tmpfile" /usr/local/bin/aws-vault || { error "Failed to move aws-vault to /usr/local/bin"; return 1; }
  
  # Verify installation
  if ! aws-vault --version &>/dev/null; then
    error "aws-vault installation failed - could not verify installation"
    return 1
  fi
  
  log "aws-vault installed/updated to latest release"
}

main(){
  prevent_sleep
  install_xcode_clt
  install_homebrew
  accept_xcode_license
  brew_bundle
  install_aws_vault_latest
  install_bun
  check_manual_steps
  mas_install
  set_names
  configure_defaults
  setup_fish
  ghostty_config
  configure_git
  install_nvm_node
  setup_ssh_keys
  clone_repos
  post_install
  
  # Calculate and display duration
  END_TIME=$(date +%s)
  DURATION=$((END_TIME - START_TIME))
  HOURS=$((DURATION / 3600))
  MINUTES=$(( (DURATION % 3600) / 60 ))
  SECONDS=$((DURATION % 60))
  
  DURATION_MSG="Installation took "
  if [ $HOURS -gt 0 ]; then
    DURATION_MSG+="${HOURS}h "
  fi
  if [ $MINUTES -gt 0 ]; then
    DURATION_MSG+="${MINUTES}m "
  fi
  DURATION_MSG+="${SECONDS}s"
  
  log "Setup complete! $DURATION_MSG"
}

main "$@"
