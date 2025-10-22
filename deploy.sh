#!/bin/bash

###############
# Author: Paul Adegoke
# Tittle: Automated Deployment Bash Script
# Input: Git repository URL, Personal Access Token (PAT), Branch name, Remote Username, Remote server IP, SSH key path, and Application internal port
#
###############

set -o errexit
set -o pipefail
set -o nounset


# Logging Setup
LOGFILE="deploy_$(date +%Y%m%d_%H%M%S).log"
exec > >(tee -a "$LOGFILE") 2>&1

# Error handling
trap 'echo "[ERROR] An unexpected error occurred. Check $LOGFILE for details."; exit 1' ERR

# Collect Parameter from User Input by prompting user for the inputs
#-------------------------------------------------------------------

echo "Collecting Parameter from User Input..."
read -r -p "Git repository URL (HTTPS): " GIT_REPO
read -r -s -p "Personal Access Token (PAT) (PAT is hidden): " GIT_PAT
echo
read -r -p "Branch name (default: main): " GIT_BRANCH
GIT_BRANCH=${GIT_BRANCH:-main}
read -r -p "Remote SSH username (e.g Ubuntu, Redhot): " REMOTE_USER
read -r -p "Remote server IP address: " REMOTE_IP
read -r -p "SSH key path (private key on my local machine): " SSH_KEY
SSH_KEY=${SSH_KEY/#~/$HOME}
read -r -p "Application internal port (container port, e.g. 3000): " APP_PORT

# Basic validations for the parameters
echo "Starting deployment" | tee -a "$LOGFILE"
if [[ -z "$GIT_REPO" ]]; then echo "Repository URL is required." exit 1; fi
if [[ -z "GIT_PAT" ]]; then err "PAT is required"; exit 1; fi
if [[ -z "$REMOTE_USER" || -z "$REMOTE_IP" ]]; then err "Remote SSH username and host are required." exit 1; fi
if [[ ! -f "$SSH_KEY" ]]; then err "SSH key not found at $SSH_KEY" exit 1; fi
if ! [[ "$APP_PORT" =~ ^[0-9]+$ ]]; then echo "Application port must be a number"; exit 1; fi

# Cleanup Flag
if [[ "${1:-}" == "--cleanup" ]]; then
  echo "Performing cleanup..."
  ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_IP" << 'EOF'
    cd /home/$REMOTE_USER/app || exit
    docker compose down
    docker system prune -af
    sudo rm -rf /etc/nginx/sites-available/app.conf /etc/nginx/sites-enabled/app.conf
    sudo systemctl reload nginx
EOF
  echo "Cleanup completed successfully."
  exit 0
fi

# Clone repositry from github
#----------------------------

# To authenticate PAT, add PAT into HTTPS URL, so that, git can automatically autheticate without asking for password
REPOSITORY_AUTH_URL="https://${GIT_PAT}@${GIT_REPO#https://}"

# This will extract folder name from repository URL
REPO=$(basename -s .git "$GIT_REPO")

# Here is a conditional statement to pull latest version if repository already exits otherwise, clone repository
if [[ -d "$REPO" ]]; then
echo "Repository directory $REPO already exists locally - pulling latest version from $GIT_BRANCH" | tee -a "$LOGFILE"
git -C "$REPO" fetch --all --prune | tee -a "$LOGFILE"
git -C "$REPO" checkout "$GIT_BRANCH" | tee -a "$LOGFILE"
git -C "$REPO" pull origin "$GIT_BRANCH" | tee -a "$LOGFILE"
else
echo "Cloning HTTPS respository (branch: $GIT_BRANCH)"
git clone --branch "$GIT_BRANCH" "REPOSITORY_AUTH_URL" "REPO" | tee -a "$LOGFILE"
fi

# Change directory into the cloned repository directory
#------------------------------------------------------
cd "$REPO" || { echo "Oops! Failed to enter repository directory"; exit 1; }

# Confirm if dockerfile or docker-compose.yml exists
if [[ -f "Dockerfile" || -f "docker-compose.yml" ]]; then
    echo "Viola! Docker configuration file found." | tee -a "$LOGFILE"
else
    echo "Oops! No Dockerfile or docker-compose.yml found in the repository." | tee -a "$LOGFILE"
    exit 1
fi

# SSH into the remote server
#----------------------------

echo "Checking SSH connection to remote server..." | tee -a "$LOGFILE"

# Confirm SSH connectivity
if ssh -o BatchMode=yes -o ConnectTimeout=15 -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_IP" "echo 'SSH connection successful'" 2>/dev/null; then
    echo "Hurray! SSH connection verified successfully." | tee -a "$LOGFILE"
else
    echo "Oops! SSH connection failed. Incorrect user input. Please check your details again." | tee -a "$LOGFILE"
    exit 1
fi

# Prepare remote environment
#----------------------------

echo "Preparing remote environment..." | tee -a "$LOGFILE"
ssh -i "$SSH_KEY" ubuntu@"$REMOTE_IP" << 'EOF'
set -e

# Update ystem packages
sudo apt update

# Install essentials
sudo apt install -y ca-certificates curl gnupg lsb-release


# Docker installation if missing
if ! command -v docker >/dev/null 2>&1; then
echo "Installing Docker..."
curl -fsSL https://get.docker.com | sh
else
echo "Docker already installed: $(docker --version)"
fi


# Docker Compose plugin (compose v2) if missing
if ! docker compose version >/dev/null 2>&1; then
echo "Installing docker compose plugin..."
sudo apt update
sudo apt install -y docker-compose-plugin || true
fi

# Nginx install
if ! command -v nginx >/dev/null 2>&1; then
echo "Installing nginx..."
sudo apt install -y nginx
else
echo "Nginx already installed: $(nginx -v 2>&1)"
fi


# Add user to docker group to ensure non-root docker commands can be used
if ! groups "$USER" | grep -q docker; then
sudo usermod -aG docker "$USER" || true
fi


# Enable and start services using systemctl
sudo systemctl enable --now docker || true
sudo systemctl enable --now nginx || true


# Print versions
docker --version || true
if docker compose version >/dev/null 2>&1; then
docker compose version || true
fi
nginx -v || true
EOF

echo "Remote environment prepared" | tee -a $"$LOGFILE"


# Deploy the Dockerized Application
# -----------------------------
echo "Deploying the dockerized application..." | tee -a "$LOGFILE"

# Transfer project files
ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_IP" "mkdir -p /home/$REMOTE_USER/app"
rsync -avz --delete -e "ssh -i $SSH_KEY" ./ "$REMOTE_USER@$REMOTE_IP:/home/$REMOTE_USER/app/" | tee -a "$LOGFILE"

# Build and run containers remotely
ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_IP" << EOF
  cd /home/$REMOTE_USER/app
  if [ -f docker-compose.yml ]; then
      echo "Using docker-compose to start services..."
      docker-compose up -d
  elif [ -f Dockerfile ]; then
      echo "🧱 Building and running container manually..."
      docker build -t myapp .
      docker run -d -p 80:$APP_PORT --name myapp_container myapp
  else
      echo "No Docker configuration file found — deployment aborted."
      exit 1
  fi

# Verify container is running
docker ps | grep myapp
echo "Application deployed successfully." | tee -a "$LOGFILE"
EOF

# Configure Nginx as a reverse proxy
#-----------------------------------
ssh -i "$SSH_KEY" "$REMOTE_USER@$REMOTE_IP" <<EOF
echo "Configuring nginx as a reverse proxy..." | tee -a "$LOGFILE"

NGINX_CONF=/etc/nginx/sites-available/myapp.conf
sudo bash -c "cat > \$NGINX_CONF" <<'NGCONF'
server {
    listen 80;
    server_name _;
    location / {
        proxy_set_header Host \$host;
	proxy_set_header X-Real-IP \$remote_addr;
	proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
	proxy_set_header X-Forwarded-Proto \$scheme;
	proxy_pass http://127.0.0.1:${APP_PORT};
	proxy_read_timeout 90;
    }
}
NGCONF

#Enable configuration
sudo ln -sf \$NGINX_CONF /etc/nginx/sites-enabled/myapp.conf

# Test connfiguration
sudo nginx -t
sudo systemctl reload nginx

echo "Nginx reverse proxy configured successfully"
EOF

# Test local endpoint using curl
if command -v curl >/dev/null 2>&1; then
if curl -sS --fail http://127.0.0.1:80 >/dev/null 2>&1; then
    echo "Local health check OK: http://127.0.0.1:${APP_PORT}"
else
    echo "Local health check failed for http://127.0.0.1:${APP_PORT}"
fi
fi

exit 0

echo "Deployment completed — verifying services" | tee -a "$LOGFILE"

# Validate Deployment
echo "Validating deployment on remote server..." | tee -a "$LOGFILE"
echo "Checking Docker service..."
if systemctl is-active --quiet docker; then
echo "Docker service is active."
else
echo "Docker service is not running."
exit 1
fi

echo "Checking running containers..."
if docker ps | grep -q myapp; then
echo "Application container is running."
else
echo "Application container not found or not running."
exit 1
fi

echo "Testing Nginx proxy and app accessibility..."
if curl -s http://localhost | grep -q "200"; then
echo "Nginx proxy is responding locally."
else
echo "local Nginx response test may have failed. Kindly check logs"
fi

echo "Deployment validation completed." | tee -a "$LOGFILE"
