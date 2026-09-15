#!/bin/bash

# wp-local-setup-proxy.sh
# Automates the configuration of a WordPress (WP) site to proxy missing media files from a production server.
# -----------------------------------------------------------------------------------------
# To use this script from anywhere on your system, follow these steps:

# For macOS and Linux:
# 
# Using one line: 
# git clone https://gist.github.com/yaroslav-borodii/7518442975cca971d54d7e02df61ccdb wp-local-setup-proxy-dir && sudo mv wp-local-setup-proxy-dir/wp-local-setup-proxy.sh /usr/local/bin/wp-local-setup-proxy && chmod +x /usr/local/bin/wp-local-setup-proxy && rm -rf wp-local-setup-proxy-dir
#
# Step by step:
# 1. Clone the Gist: git clone https://gist.github.com/yaroslav-borodii/7518442975cca971d54d7e02df61ccdb wp-local-setup-proxy-dir
# 2. Move the script to a global directory: sudo mv wp-local-setup-proxy-dir/wp-local-setup-proxy.sh /usr/local/bin/wp-local-setup-proxy
# 3. Make the script executable: chmod +x /usr/local/bin/wp-local-setup-proxy
# 4. Remove folder: rm -rf wp-local-setup-proxy-dir

# For Windows (using Git Bash or WSL):
#
# Step by step:
# 1. Clone the Gist: git clone https://gist.github.com/yaroslav-borodii/7518442975cca971d54d7e02df61ccdb wp-local-setup-proxy-dir
# 2. Make the script executable (if using Bash or WSL): chmod +x wp-local-setup-proxy-dir/wp-local-setup-proxy.sh
# 3. Add the directory to your PATH through System Properties or with setx command.
# 4. Run the script using 'bash wp-local-setup-proxy.sh' in Command Prompt, or directly in Git Bash/WSL.

# -----------------------------------------------------------------------------------------

# Check if a domain was provided as an argument
if [ "$#" -ne 1 ]; then
    echo "Usage: $0 <domain-to-proxy.com>"
    exit 1
fi

# The user's domain
USER_DOMAIN=$1

# Step 1: Assuming the script is run from the root directory of the local install

# Step 2: Go to the /conf/nginx directory
cd conf/nginx || { echo "Failed to navigate to conf/nginx. Exiting."; exit 1; }

# Step 3: Add a new file called uploads-proxy.conf
echo "Creating uploads-proxy.conf file..."
cat > uploads-proxy.conf <<EOL
location ~ ^/wp-content/uploads/(.*) {
    if (!-e \$request_filename) {
        rewrite ^/wp-content/uploads/(.*) https://${USER_DOMAIN}/wp-content/uploads/\$1 redirect;
    }
}
EOL

# Step 6: Open site.conf.hbs
# Step 7-8: Add specific lines after a particular block of text
echo "Modifying site.conf.hbs..."
awk -v domain="${USER_DOMAIN}" '
    /{{#unless site.multiSite}}/ { print; next }
    /{{else}}/ { print; next }
    /{{\/unless}}/ {
        print;
        print "\n#\n# Proxy requests to the upload directory to the production site\n#";
        print "include uploads-proxy.conf;\n";
        next
    }
    { print }
' site.conf.hbs > site.conf.hbs.tmp && mv site.conf.hbs.tmp site.conf.hbs

echo "Modifications complete."

# Instructions for steps 9 and 10 are manual and cannot be scripted.
echo "Please restart your site in the Local by Flywheel control panel."
echo "After restarting, load your local site in your browser to see the changes."
