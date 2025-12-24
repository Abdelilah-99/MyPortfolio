#!/bin/bash

################################################################################
# Complete HTTPS Setup Script for Portfolio
# This script handles everything: prerequisites, SSL, deployment, and testing
# 
# Usage: sudo ./complete-https-setup.sh
# 
# Author: Abdelilah Bouchikhi
# Date: 2025
################################################################################

set -e  # Exit on error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color
BOLD='\033[1m'

# Configuration Variables
DOMAIN="abdelilah.bouchikhi.com"
WWW_DOMAIN="www.abdelilah.bouchikhi.com"
PROJECT_DIR="/home/abdelilah/MyPortfolio"
WEB_ROOT="/var/www/portfolio"
EMAIL="bouchihkiabdelilah0@gmail.com"
USER="abdelilah"

# Logging
LOG_FILE="/var/log/portfolio-deployment.log"
exec > >(tee -a "$LOG_FILE") 2>&1

################################################################################
# Helper Functions
################################################################################

print_header() {
    echo -e "\n${BOLD}${CYAN}========================================${NC}"
    echo -e "${BOLD}${CYAN}$1${NC}"
    echo -e "${BOLD}${CYAN}========================================${NC}\n"
}

print_step() {
    echo -e "${BOLD}${GREEN}[STEP $1/$2]${NC} ${YELLOW}$3${NC}"
}

print_success() {
    echo -e "${GREEN}✓${NC} $1"
}

print_error() {
    echo -e "${RED}✗${NC} $1"
}

print_info() {
    echo -e "${BLUE}ℹ${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}⚠${NC} $1"
}

check_root() {
    if [ "$EUID" -ne 0 ]; then 
        print_error "This script must be run as root"
        echo "Please run: sudo ./complete-https-setup.sh"
        exit 1
    fi
    print_success "Running as root"
}

check_dns() {
    print_info "Checking DNS configuration..."
    
    if command -v dig &> /dev/null; then
        DNS_IP=$(dig +short "$DOMAIN" | tail -n1)
    elif command -v nslookup &> /dev/null; then
        DNS_IP=$(nslookup "$DOMAIN" | grep "Address:" | tail -n1 | awk '{print $2}')
    else
        print_warning "dig/nslookup not found, skipping DNS check"
        return 0
    fi
    
    if [ -z "$DNS_IP" ]; then
        print_warning "DNS not configured for $DOMAIN"
        print_info "Make sure your domain points to this server's IP"
        read -p "Continue anyway? (y/n) " -n 1 -r
        echo
        if [[ ! $REPLY =~ ^[Yy]$ ]]; then
            exit 1
        fi
    else
        print_success "DNS configured: $DOMAIN → $DNS_IP"
    fi
}

check_ports() {
    print_info "Checking if ports 80 and 443 are available..."
    
    if command -v netstat &> /dev/null; then
        PORT_80=$(netstat -tuln | grep ":80 " || true)
        PORT_443=$(netstat -tuln | grep ":443 " || true)
    elif command -v ss &> /dev/null; then
        PORT_80=$(ss -tuln | grep ":80 " || true)
        PORT_443=$(ss -tuln | grep ":443 " || true)
    else
        print_warning "netstat/ss not found, skipping port check"
        return 0
    fi
    
    if [ -n "$PORT_80" ] && [[ ! "$PORT_80" =~ "nginx" ]]; then
        print_warning "Port 80 is in use by another service"
    fi
    
    if [ -n "$PORT_443" ] && [[ ! "$PORT_443" =~ "nginx" ]]; then
        print_warning "Port 443 is in use by another service"
    fi
}

################################################################################
# Installation Functions
################################################################################

update_system() {
    print_info "Updating system packages..."
    apt update -qq
    print_success "System packages updated"
}

install_dependencies() {
    print_info "Installing required dependencies..."
    
    PACKAGES=(
        "nginx"
        "certbot"
        "python3-certbot-nginx"
        "curl"
        "ufw"
        "git"
    )
    
    for pkg in "${PACKAGES[@]}"; do
        if dpkg -l | grep -q "^ii  $pkg "; then
            print_success "$pkg already installed"
        else
            print_info "Installing $pkg..."
            apt install -y "$pkg" > /dev/null 2>&1
            print_success "$pkg installed"
        fi
    done
}

install_nodejs() {
    print_info "Checking Node.js installation..."
    
    if command -v node &> /dev/null; then
        NODE_VERSION=$(node --version)
        print_success "Node.js already installed: $NODE_VERSION"
    else
        print_info "Installing Node.js..."
        curl -fsSL https://deb.nodesource.com/setup_20.x | bash -
        apt install -y nodejs
        print_success "Node.js installed: $(node --version)"
    fi
    
    if command -v npm &> /dev/null; then
        NPM_VERSION=$(npm --version)
        print_success "npm installed: $NPM_VERSION"
    fi
}

################################################################################
# Firewall Configuration
################################################################################

configure_firewall() {
    print_info "Configuring firewall..."
    
    # Enable UFW if not active
    if ufw status | grep -q "Status: inactive"; then
        print_info "Enabling firewall..."
        ufw --force enable
    fi
    
    # Allow SSH (important!)
    ufw allow 22/tcp comment 'SSH' > /dev/null 2>&1
    print_success "Port 22 (SSH) allowed"
    
    # Allow HTTP
    ufw allow 80/tcp comment 'HTTP' > /dev/null 2>&1
    print_success "Port 80 (HTTP) allowed"
    
    # Allow HTTPS
    ufw allow 443/tcp comment 'HTTPS' > /dev/null 2>&1
    print_success "Port 443 (HTTPS) allowed"
    
    # Reload firewall
    ufw reload > /dev/null 2>&1
    print_success "Firewall configured and reloaded"
}

################################################################################
# Project Build
################################################################################

build_project() {
    print_info "Building portfolio project..."
    
    cd "$PROJECT_DIR"
    
    # Check if node_modules exists
    if [ ! -d "node_modules" ]; then
        print_info "Installing npm dependencies..."
        sudo -u "$USER" npm install
        print_success "Dependencies installed"
    else
        print_success "Dependencies already installed"
    fi
    
    # Build the project
    print_info "Building project with Parcel..."
    sudo -u "$USER" npm run build
    print_success "Project built successfully"
    
    # Verify dist folder exists
    if [ ! -d "dist" ]; then
        print_error "Build failed: dist folder not found"
        exit 1
    fi
    print_success "Build output verified"
}

################################################################################
# Web Server Setup
################################################################################

setup_web_directory() {
    print_info "Setting up web directory..."
    
    # Create web root
    mkdir -p "$WEB_ROOT"
    print_success "Web root directory created: $WEB_ROOT"
    
    # Copy built files
    print_info "Copying built files to web root..."
    cp -r "$PROJECT_DIR/dist/"* "$WEB_ROOT/"
    print_success "Files copied successfully"
    
    # Set ownership and permissions
    chown -R www-data:www-data "$WEB_ROOT"
    chmod -R 755 "$WEB_ROOT"
    print_success "Permissions set correctly"
    
    # Verify files
    FILE_COUNT=$(find "$WEB_ROOT" -type f | wc -l)
    print_success "Deployed $FILE_COUNT files"
}

configure_nginx_temp() {
    print_info "Installing temporary Nginx configuration..."
    
    cat > /etc/nginx/sites-available/portfolio << EOF
# Temporary HTTP configuration for SSL certificate generation
server {
    listen 80;
    listen [::]:80;
    server_name $DOMAIN $WWW_DOMAIN;
    
    root $WEB_ROOT;
    index index.html;
    
    location / {
        try_files \$uri \$uri/ /index.html;
    }
    
    location ~ /\. {
        deny all;
    }
}
EOF
    
    # Enable site
    ln -sf /etc/nginx/sites-available/portfolio /etc/nginx/sites-enabled/
    rm -f /etc/nginx/sites-enabled/default
    
    # Test configuration
    nginx -t
    print_success "Temporary Nginx configuration installed"
    
    # Restart Nginx
    systemctl restart nginx
    print_success "Nginx restarted"
}

################################################################################
# SSL Certificate Setup
################################################################################

obtain_ssl_certificate() {
    print_info "Obtaining SSL certificate from Let's Encrypt..."
    
    # Check if certificate already exists
    if [ -d "/etc/letsencrypt/live/$DOMAIN" ]; then
        print_warning "SSL certificate already exists"
        read -p "Renew certificate? (y/n) " -n 1 -r
        echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            certbot renew --force-renewal
            print_success "Certificate renewed"
        else
            print_info "Using existing certificate"
        fi
    else
        # Obtain new certificate
        certbot --nginx \
            -d "$DOMAIN" \
            -d "$WWW_DOMAIN" \
            --non-interactive \
            --agree-tos \
            --email "$EMAIL" \
            --redirect
        
        print_success "SSL certificate obtained successfully"
    fi
    
    # Verify certificate
    if [ -f "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" ]; then
        CERT_EXPIRY=$(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" | cut -d= -f2)
        print_success "Certificate valid until: $CERT_EXPIRY"
    else
        print_error "Certificate verification failed"
        exit 1
    fi
}

configure_nginx_final() {
    print_info "Installing optimized HTTPS Nginx configuration..."
    
    # Backup existing config
    if [ -f "/etc/nginx/sites-available/portfolio" ]; then
        cp /etc/nginx/sites-available/portfolio "/etc/nginx/sites-available/portfolio.backup.$(date +%Y%m%d_%H%M%S)"
    fi
    
    # Copy optimized configuration from project
    cp "$PROJECT_DIR/nginx.conf" /etc/nginx/sites-available/portfolio
    
    # Update paths in config if needed
    sed -i "s|root .*;|root $WEB_ROOT;|g" /etc/nginx/sites-available/portfolio
    
    # Test configuration
    nginx -t
    print_success "Final Nginx configuration installed"
    
    # Reload Nginx
    systemctl reload nginx
    print_success "Nginx reloaded with HTTPS configuration"
}

################################################################################
# Auto-Renewal Setup
################################################################################

setup_auto_renewal() {
    print_info "Setting up automatic certificate renewal..."
    
    # Enable and start certbot timer
    systemctl enable certbot.timer > /dev/null 2>&1
    systemctl start certbot.timer > /dev/null 2>&1
    
    # Verify timer is active
    if systemctl is-active --quiet certbot.timer; then
        print_success "Auto-renewal timer enabled and active"
        
        # Show next renewal time
        NEXT_RENEWAL=$(systemctl list-timers certbot.timer --no-pager | grep certbot | awk '{print $1, $2, $3}')
        if [ -n "$NEXT_RENEWAL" ]; then
            print_info "Next automatic check: $NEXT_RENEWAL"
        fi
    else
        print_warning "Auto-renewal timer may not be active"
    fi
    
    # Test renewal process (dry-run)
    print_info "Testing certificate renewal process..."
    certbot renew --dry-run --quiet
    print_success "Certificate renewal test passed"
}

################################################################################
# Service Management
################################################################################

enable_services() {
    print_info "Enabling services to start on boot..."
    
    systemctl enable nginx > /dev/null 2>&1
    print_success "Nginx enabled"
    
    systemctl enable certbot.timer > /dev/null 2>&1
    print_success "Certbot timer enabled"
}

################################################################################
# Verification & Testing
################################################################################

verify_deployment() {
    print_info "Verifying deployment..."
    
    # Check Nginx status
    if systemctl is-active --quiet nginx; then
        print_success "Nginx is running"
    else
        print_error "Nginx is not running"
        exit 1
    fi
    
    # Check if site is accessible
    print_info "Testing HTTP connection..."
    if curl -s -o /dev/null -w "%{http_code}" "http://$DOMAIN" | grep -q "301\|302\|200"; then
        print_success "HTTP accessible (should redirect to HTTPS)"
    else
        print_warning "HTTP connection test inconclusive"
    fi
    
    # Check HTTPS
    print_info "Testing HTTPS connection..."
    if curl -s -o /dev/null -w "%{http_code}" "https://$DOMAIN" | grep -q "200"; then
        print_success "HTTPS working correctly"
    else
        print_warning "HTTPS connection test inconclusive"
    fi
    
    # Check SSL certificate
    print_info "Verifying SSL certificate..."
    if openssl s_client -connect "$DOMAIN:443" -servername "$DOMAIN" </dev/null 2>/dev/null | grep -q "Verify return code: 0"; then
        print_success "SSL certificate valid"
    else
        print_warning "SSL certificate verification inconclusive"
    fi
}

create_helper_scripts() {
    print_info "Creating helper scripts..."
    
    # Create quick update script if it doesn't exist
    if [ ! -f "$PROJECT_DIR/update-portfolio.sh" ]; then
        cat > "$PROJECT_DIR/update-portfolio.sh" << 'EOFSCRIPT'
#!/bin/bash
set -e
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo -e "${GREEN}Updating Portfolio...${NC}\n"

cd /home/abdelilah/MyPortfolio

echo -e "${YELLOW}Building project...${NC}"
npm run build

echo -e "${YELLOW}Deploying to web root...${NC}"
sudo cp -r dist/* /var/www/portfolio/
sudo chown -R www-data:www-data /var/www/portfolio
sudo chmod -R 755 /var/www/portfolio

echo -e "${YELLOW}Reloading Nginx...${NC}"
sudo systemctl reload nginx

echo -e "\n${GREEN}✓ Portfolio updated successfully!${NC}"
echo -e "Visit: ${GREEN}https://abdelilah.bouchikhi.com${NC}\n"
EOFSCRIPT
        
        chmod +x "$PROJECT_DIR/update-portfolio.sh"
        chown "$USER:$USER" "$PROJECT_DIR/update-portfolio.sh"
        print_success "Update script created"
    fi
    
    # Create status check script
    cat > "$PROJECT_DIR/check-status.sh" << 'EOFSCRIPT'
#!/bin/bash
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

echo -e "${YELLOW}Portfolio Status Check${NC}\n"

echo "Nginx Status:"
sudo systemctl status nginx --no-pager | grep "Active:" | sed 's/^/  /'

echo -e "\nSSL Certificate:"
sudo certbot certificates 2>/dev/null | grep -A 5 "abdelilah.bouchikhi.com" | sed 's/^/  /'

echo -e "\nFirewall Status:"
sudo ufw status | grep -E "80|443|Status" | sed 's/^/  /'

echo -e "\nDisk Usage (Web Root):"
du -sh /var/www/portfolio 2>/dev/null | sed 's/^/  /'

echo -e "\nRecent Nginx Access (last 5):"
sudo tail -n 5 /var/log/nginx/access.log 2>/dev/null | sed 's/^/  /' || echo "  No access logs found"

echo -e "\nRecent Nginx Errors (last 5):"
sudo tail -n 5 /var/log/nginx/error.log 2>/dev/null | sed 's/^/  /' || echo "  No error logs found"
EOFSCRIPT
    
    chmod +x "$PROJECT_DIR/check-status.sh"
    chown "$USER:$USER" "$PROJECT_DIR/check-status.sh"
    print_success "Status check script created"
}

################################################################################
# Main Execution
################################################################################

main() {
    local TOTAL_STEPS=15
    local current_step=0
    
    print_header "Complete HTTPS Setup for Portfolio"
    
    echo -e "${CYAN}Domain:${NC} $DOMAIN"
    echo -e "${CYAN}WWW Domain:${NC} $WWW_DOMAIN"
    echo -e "${CYAN}Project Directory:${NC} $PROJECT_DIR"
    echo -e "${CYAN}Web Root:${NC} $WEB_ROOT"
    echo -e "${CYAN}Email:${NC} $EMAIL"
    echo -e "${CYAN}Log File:${NC} $LOG_FILE"
    echo ""
    
    read -p "Continue with deployment? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Deployment cancelled by user"
        exit 0
    fi
    
    # Pre-flight checks
    print_header "Pre-flight Checks"
    check_root
    check_dns
    check_ports
    
    # System setup
    ((current_step++))
    print_step $current_step $TOTAL_STEPS "Updating system packages"
    update_system
    
    ((current_step++))
    print_step $current_step $TOTAL_STEPS "Installing dependencies"
    install_dependencies
    
    ((current_step++))
    print_step $current_step $TOTAL_STEPS "Installing Node.js and npm"
    install_nodejs
    
    ((current_step++))
    print_step $current_step $TOTAL_STEPS "Configuring firewall"
    configure_firewall
    
    # Build project
    ((current_step++))
    print_step $current_step $TOTAL_STEPS "Building portfolio project"
    build_project
    
    # Web server setup
    ((current_step++))
    print_step $current_step $TOTAL_STEPS "Setting up web directory"
    setup_web_directory
    
    ((current_step++))
    print_step $current_step $TOTAL_STEPS "Configuring Nginx (temporary)"
    configure_nginx_temp
    
    # SSL setup
    ((current_step++))
    print_step $current_step $TOTAL_STEPS "Obtaining SSL certificate"
    obtain_ssl_certificate
    
    ((current_step++))
    print_step $current_step $TOTAL_STEPS "Installing final HTTPS configuration"
    configure_nginx_final
    
    ((current_step++))
    print_step $current_step $TOTAL_STEPS "Setting up auto-renewal"
    setup_auto_renewal
    
    # Service management
    ((current_step++))
    print_step $current_step $TOTAL_STEPS "Enabling services"
    enable_services
    
    # Verification
    ((current_step++))
    print_step $current_step $TOTAL_STEPS "Verifying deployment"
    verify_deployment
    
    # Helper scripts
    ((current_step++))
    print_step $current_step $TOTAL_STEPS "Creating helper scripts"
    create_helper_scripts
    
    # Summary
    print_header "Deployment Complete! 🎉"
    
    echo -e "${GREEN}${BOLD}Your portfolio is now live with HTTPS!${NC}\n"
    
    echo -e "${YELLOW}${BOLD}URLs:${NC}"
    echo -e "  🔒 ${GREEN}https://$DOMAIN${NC}"
    echo -e "  🔒 ${GREEN}https://$WWW_DOMAIN${NC}"
    echo ""
    
    echo -e "${YELLOW}${BOLD}SSL Certificate:${NC}"
    echo -e "  ✓ Auto-renewal enabled"
    echo -e "  ✓ Expires: $(openssl x509 -enddate -noout -in "/etc/letsencrypt/live/$DOMAIN/fullchain.pem" | cut -d= -f2)"
    echo ""
    
    echo -e "${YELLOW}${BOLD}Helper Scripts Created:${NC}"
    echo -e "  📝 ${CYAN}./update-portfolio.sh${NC} - Update your portfolio after changes"
    echo -e "  📊 ${CYAN}./check-status.sh${NC} - Check deployment status"
    echo ""
    
    echo -e "${YELLOW}${BOLD}Useful Commands:${NC}"
    echo -e "  ${CYAN}sudo systemctl status nginx${NC} - Check Nginx status"
    echo -e "  ${CYAN}sudo certbot certificates${NC} - View certificates"
    echo -e "  ${CYAN}sudo certbot renew --dry-run${NC} - Test renewal"
    echo -e "  ${CYAN}sudo tail -f /var/log/nginx/error.log${NC} - View Nginx errors"
    echo ""
    
    echo -e "${YELLOW}${BOLD}Test Your SSL:${NC}"
    echo -e "  🔍 https://www.ssllabs.com/ssltest/analyze.html?d=$DOMAIN"
    echo ""
    
    echo -e "${YELLOW}${BOLD}Logs:${NC}"
    echo -e "  📋 Deployment log: ${CYAN}$LOG_FILE${NC}"
    echo ""
    
    echo -e "${GREEN}${BOLD}🚀 Deployment successful! Visit your site now!${NC}\n"
}

# Run main function
main "$@"

