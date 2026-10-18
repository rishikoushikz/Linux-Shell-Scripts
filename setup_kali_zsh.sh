#!/bin/bash

# Exit immediately if a command exits with a non-zero status
set -e

echo "========================================="
echo " Installing and Configuring Kali-like Zsh "
echo "========================================="

# 1. Update package lists and install prerequisite packages
echo "--> Installing Zsh, curl, git, and fonts..."
sudo apt update
sudo apt install -y zsh curl git fonts-noto-color-emoji fonts-font-awesome

# 2. Install Oh My Zsh (Automated non-interactive install)
if [ ! -d "$HOME/.oh-my-zsh" ]; then
    echo "--> Installing Oh My Zsh..."
    RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
else
    echo "--> Oh My Zsh is already installed."
fi

# 3. Install Core Plugins used by Kali (Syntax Highlighting & Autosuggestions)
ZSH_CUSTOM="$HOME/.oh-my-zsh/custom"

echo "--> Installing zsh-autosuggestions..."
if [ ! -d "$ZSH_CUSTOM/plugins/zsh-autosuggestions" ]; then
    git clone https://github.com/zsh-users/zsh-autosuggestions "$ZSH_CUSTOM/plugins/zsh-autosuggestions"
fi

echo "--> Installing zsh-syntax-highlighting..."
if [ ! -d "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting" ]; then
    git clone https://github.com/zsh-users/zsh-syntax-highlighting "$ZSH_CUSTOM/plugins/zsh-syntax-highlighting"
fi

# 4. Pull and apply the Kali Linux official .zshrc theme settings
echo "--> Fetching Kali Linux Zsh configurations..."

# Download Kali's official zshrc template
curl -fsSL https://gitlab.com/kalilinux/packages/kali-defaults/-/raw/kali/master/etc/skel/.zshrc -o "$HOME/.zshrc.kali"

# Backup existing .zshrc if it exists
if [ -f "$HOME/.zshrc" ]; then
    mv "$HOME/.zshrc" "$HOME/.zshrc.bak"
    echo "    Saved existing .zshrc to .zshrc.bak"
fi

# Use the Kali config as the primary .zshrc
mv "$HOME/.zshrc.kali" "$HOME/.zshrc"

# 5. Fix Kali-specific paths for Ubuntu compatibility
echo "--> Optimizing configuration for Ubuntu environment..."
sed -i 's|/usr/share/zsh-autosuggestions/zsh-autosuggestions.zsh|'"$ZSH_CUSTOM"'/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh|g' "$HOME/.zshrc"
sed -i 's|/usr/share/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh|'"$ZSH_CUSTOM"'/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh|g' "$HOME/.zshrc"

# 6. FIX: Add high-visibility color overrides for Light Backgrounds
echo "--> Injecting visibility fixes for light backgrounds..."
cat << 'EOF' >> "$HOME/.zshrc"

# --- Light Background Visibility Patch ---
# Kali defaults assume a dark terminal. These overrides ensure typos stay visible.
typeset -A ZSH_HIGHLIGHT_STYLES
ZSH_HIGHLIGHT_STYLES[unknown-token]='fg=red,bold'
EOF

# 7. Change default shell to Zsh for the current user
echo "--> Changing default shell to Zsh..."
sudo chsh -s $(which zsh) $USER

echo "========================================="
echo "  Setup Complete! Please log out and log "
echo "  back in (or restart your terminal).     "
echo "========================================="
