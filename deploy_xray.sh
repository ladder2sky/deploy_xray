#!/bin/bash

# ====================================================
# Xray 自动部署脚本 (Ubuntu)
# 功能：
# 1. 安装 Xray, Nginx, Certbot
# 2. 配置 2个 Reality 端口 + 1个 WS+TLS 端口
# 3. 自动申请 SSL 证书并配置自动续期
# 4. 安全增强：配置备份、防火墙检查、错误回滚
# ====================================================

# 配置参数 (可在此修改默认值)
PORT_REALITY_1=8443
PORT_REALITY_2=30001
PORT_WS=2613
WS_PATH="/nobody"

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

# 日志和备份配置
LOG_FILE="/var/log/xray_deploy.log"
BACKUP_DIR="/root/nginx_backup_$(date +%Y%m%d%H%M%S)"

# 错误处理函数
handle_error() {
    echo -e "${RED}发生错误，脚本终止！${PLAIN}" | tee -a "$LOG_FILE"
    echo -e "${YELLOW}正在尝试回滚...${PLAIN}" | tee -a "$LOG_FILE"
    
    if [ -d "$BACKUP_DIR" ]; then
        read -p "是否恢复 Nginx 备份? [Y/n] " restore_choice
        case "${restore_choice}" in
            [yY][eE][sS]|[yY])
                echo -e "${YELLOW}正在恢复 Nginx 配置...${PLAIN}" | tee -a "$LOG_FILE"
                cp -r "$BACKUP_DIR/nginx"/* /etc/nginx/
                systemctl restart nginx
                echo -e "${GREEN}恢复完成。${PLAIN}" | tee -a "$LOG_FILE"
                ;;
            *)
                echo -e "${YELLOW}跳过恢复。备份文件位于: ${BACKUP_DIR}${PLAIN}" | tee -a "$LOG_FILE"
                ;;
        esac
    else
        echo -e "${YELLOW}无备份可恢复。${PLAIN}" | tee -a "$LOG_FILE"
    fi
    exit 1
}

# 设置错误捕获
trap 'handle_error' ERR

# 检查是否为 root 用户
check_root() {
    if [ "$EUID" -ne 0 ]; then
        echo -e "${RED}请以 root 用户运行此脚本！${PLAIN}"
        exit 1
    fi
}

# 日志记录
log() {
    echo -e "$(date "+%Y-%m-%d %H:%M:%S") $1" >> "$LOG_FILE"
}

# 安装基础依赖
install_dependencies() {
    echo -e "${YELLOW}正在更新系统并安装依赖...${PLAIN}" | tee -a "$LOG_FILE"
    apt update -y
    apt install -y curl wget socat git nginx certbot python3-certbot-nginx jq openssl ufw
    log "依赖安装完成"
}

# 检查并配置防火墙
configure_firewall() {
    echo -e "${YELLOW}正在检查防火墙配置...${PLAIN}" | tee -a "$LOG_FILE"
    if ufw status | grep -q "Status: active"; then
        echo -e "${GREEN}UFW 防火墙已激活，正在开放端口...${PLAIN}" | tee -a "$LOG_FILE"
        ufw allow 80/tcp
        ufw allow 443/tcp
        ufw allow "${PORT_REALITY_1}/tcp"
        ufw allow "${PORT_REALITY_2}/tcp"
        ufw allow ssh
        ufw reload
        log "UFW 端口已开放: 80, 443, ${PORT_REALITY_1}, ${PORT_REALITY_2}"
    else
        echo -e "${YELLOW}UFW 防火墙未激活。建议稍后手动配置防火墙以保障安全。${PLAIN}" | tee -a "$LOG_FILE"
    fi
}

# 安装 Xray
install_xray() {
    echo -e "${YELLOW}正在安装 Xray...${PLAIN}" | tee -a "$LOG_FILE"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    log "Xray 安装完成"
}

# 生成 UUID 和 密钥
generate_credentials() {
    echo -e "${YELLOW}正在生成 UUID 和 密钥...${PLAIN}"
    
    # 生成 3 个用户 ID
    UUID1=$(xray uuid)
    UUID2=$(xray uuid)
    UUID3=$(xray uuid)
    
    # 生成 Reality 密钥对 1
    # 解析逻辑：兼容 xray x25519 的输出格式
    #   旧版: "Private key: <key>" / "Public key: <key>"
    #   新版: "PrivateKey: <key>" / "Password (PublicKey): <key>" / "Hash32: ..."
    # 密钥始终是所在行的最后一个字段，故用 $NF 提取
    KEYS1=$(xray x25519)
    PRI_KEY1=$(echo "$KEYS1" | grep -i "private" | awk '{print $NF}')
    PUB_KEY1=$(echo "$KEYS1" | grep -iE "public|password" | awk '{print $NF}')
    
    # 生成 Reality 密钥对 2
    KEYS2=$(xray x25519)
    PRI_KEY2=$(echo "$KEYS2" | grep -i "private" | awk '{print $NF}')
    PUB_KEY2=$(echo "$KEYS2" | grep -iE "public|password" | awk '{print $NF}')
    
    # 生成 ShortIDs
    SHORTID1=$(openssl rand -hex 4)
    SHORTID2=$(openssl rand -hex 4)
    log "凭证生成完成"
}

# 配置 Xray
configure_xray() {
    echo -e "${YELLOW}正在配置 Xray...${PLAIN}" | tee -a "$LOG_FILE"
    
    cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": ${PORT_REALITY_1},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${UUID1}", "flow": "xtls-rprx-vision", "email": "user1" },
          { "id": "${UUID2}", "flow": "xtls-rprx-vision", "email": "user2" },
          { "id": "${UUID3}", "flow": "xtls-rprx-vision", "email": "user3" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.cloudflare.com:443",
          "serverNames": ["www.cloudflare.com"],
          "privateKey": "${PRI_KEY1}",
          "shortIds": ["${SHORTID1}"],
          "xver": 0
        }
      }
    },
    {
      "port": ${PORT_REALITY_2},
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${UUID1}", "flow": "xtls-rprx-vision", "email": "user1" },
          { "id": "${UUID2}", "flow": "xtls-rprx-vision", "email": "user2" },
          { "id": "${UUID3}", "flow": "xtls-rprx-vision", "email": "user3" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "www.cloudflare.com:443",
          "serverNames": ["www.cloudflare.com"],
          "privateKey": "${PRI_KEY2}",
          "shortIds": ["${SHORTID2}"],
          "xver": 0
        }
      }
    },
    {
      "port": ${PORT_WS},
      "listen": "127.0.0.1",
      "tag": "ws-in",
      "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "${UUID1}", "email": "user1" },
          { "id": "${UUID2}", "email": "user2" },
          { "id": "${UUID3}", "email": "user3" }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "${WS_PATH}",
          "headers": { "Host": "${DOMAIN}" }
        },
        "security": "none"
      }
    }
  ],
  "outbounds": [
    { "protocol": "freedom", "settings": {} }
  ]
}
EOF
    systemctl restart xray
    log "Xray 配置已更新并重启"
}

# 备份 Nginx 配置
backup_nginx() {
    if [ -d "/etc/nginx" ]; then
        echo -e "${YELLOW}正在备份现有 Nginx 配置...${PLAIN}" | tee -a "$LOG_FILE"
        mkdir -p "$BACKUP_DIR"
        cp -r /etc/nginx "$BACKUP_DIR/"
        echo -e "${GREEN}Nginx 配置已备份至: ${BACKUP_DIR}${PLAIN}" | tee -a "$LOG_FILE"
        log "Nginx 备份至 $BACKUP_DIR"
    fi
}

# 配置 Nginx 和 SSL
configure_nginx() {
    backup_nginx
    
    echo -e "${YELLOW}正在配置 Nginx...${PLAIN}" | tee -a "$LOG_FILE"
    
    # 检查是否存在包含该域名的现有配置
    EXISTING_CONF=$(grep -r "server_name.*${DOMAIN}" /etc/nginx/sites-enabled/ | cut -d: -f1 | head -n 1)
    
    if [ -n "$EXISTING_CONF" ]; then
        echo -e "${YELLOW}检测到域名 ${DOMAIN} 已在以下文件中配置: ${EXISTING_CONF}${PLAIN}" | tee -a "$LOG_FILE"
        echo -e "${YELLOW}脚本将跳过创建新配置文件，以避免冲突。${PLAIN}"
        
        # 尝试检查是否已经有反代配置
        if grep -q "proxy_pass.*127.0.0.1:${PORT_WS}" "$EXISTING_CONF"; then
             echo -e "${GREEN}现有配置似乎已包含 Xray 反代设置 (端口 ${PORT_WS})。${PLAIN}" | tee -a "$LOG_FILE"
        else
             echo -e "${RED}警告：现有配置可能未包含 Xray 反代设置 (端口 ${PORT_WS})。${PLAIN}" | tee -a "$LOG_FILE"
             echo -e "${RED}请手动检查并修改文件: ${EXISTING_CONF}${PLAIN}"
             echo -e "需要添加 location ${WS_PATH} { proxy_pass http://127.0.0.1:${PORT_WS}; ... }"
        fi
        
        # 依然检查 SSL
        echo -e "${YELLOW}正在检查 SSL 证书...${PLAIN}" | tee -a "$LOG_FILE"
        if certbot certificates | grep -q "${DOMAIN}"; then
            echo -e "${GREEN}证书已存在。${PLAIN}" | tee -a "$LOG_FILE"
        else
            echo -e "${YELLOW}尝试为现有配置申请证书...${PLAIN}" | tee -a "$LOG_FILE"
            certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos -m "admin@${DOMAIN}" --redirect
        fi
        
        return
    fi
    
    # 检查 default 配置
    if [ -f "/etc/nginx/sites-enabled/default" ]; then
        echo -e "${YELLOW}发现默认 Nginx 配置 (/etc/nginx/sites-enabled/default)${PLAIN}"
        read -p "是否移除默认配置以避免冲突? [Y/n] " remove_default
        case "${remove_default}" in
            [yY][eE][sS]|[yY])
                rm -f /etc/nginx/sites-enabled/default
                echo -e "${GREEN}已移除默认配置。${PLAIN}" | tee -a "$LOG_FILE"
                ;;
            *)
                echo -e "${YELLOW}保留默认配置。请注意可能会有端口冲突。${PLAIN}" | tee -a "$LOG_FILE"
                ;;
        esac
    fi
    
    # 创建 Nginx 配置
    cat > /etc/nginx/sites-available/xray <<EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location ${WS_PATH} {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:${PORT_WS};
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$http_host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location / {
        # 伪装站
        return 200 "Welcome to nginx!";
    }
}
EOF

    # 启用配置
    ln -sf /etc/nginx/sites-available/xray /etc/nginx/sites-enabled/
    
    # 测试 Nginx 配置
    if ! nginx -t; then
        echo -e "${RED}Nginx 配置测试失败！即将回滚...${PLAIN}" | tee -a "$LOG_FILE"
        handle_error
    fi
    systemctl reload nginx
    
    echo -e "${YELLOW}正在申请 SSL 证书...${PLAIN}" | tee -a "$LOG_FILE"
    
    # 检查证书是否已存在
    if certbot certificates | grep -q "${DOMAIN}"; then
        echo -e "${GREEN}检测到域名 ${DOMAIN} 已存在证书。${PLAIN}" | tee -a "$LOG_FILE"
        read -p "是否重新申请/强制更新证书? [y/N] " renew_choice
        if [[ "$renew_choice" =~ ^[yY] ]]; then
            certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos -m "admin@${DOMAIN}" --redirect --force-renewal
        else
            echo -e "${YELLOW}跳过证书申请，复用现有证书。${PLAIN}" | tee -a "$LOG_FILE"
        fi
    else
        # 申请新证书
        certbot --nginx -d "${DOMAIN}" --non-interactive --agree-tos -m "admin@${DOMAIN}" --redirect
    fi
    
    # 再次重载以确保生效
    systemctl reload nginx
    log "Nginx 和 SSL 配置完成"
}

# 输出客户端配置信息
output_info() {
    IP=$(curl -s ipv4.icanhazip.com)
    
    echo -e ""
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e "${GREEN}      Xray 部署完成！客户端配置如下           ${PLAIN}"
    echo -e "${GREEN}==============================================${PLAIN}"
    echo -e ""
    
    echo -e "${YELLOW}--- 通用信息 ---${PLAIN}"
    echo -e "用户 ID (UUID):"
    echo -e "User1: ${UUID1}"
    echo -e "User2: ${UUID2}"
    echo -e "User3: ${UUID3}"
    echo -e ""
    
    echo -e "${YELLOW}--- 节点 1: Reality (Port ${PORT_REALITY_1}) ---${PLAIN}"
    echo -e "地址 (Address): ${IP}"
    echo -e "端口 (Port): ${PORT_REALITY_1}"
    echo -e "协议 (Protocol): vless"
    echo -e "流控 (Flow): xtls-rprx-vision (推荐开启)"
    echo -e "传输方式 (Network): tcp"
    echo -e "伪装类型 (Type): none"
    echo -e "Reality ServerName: www.cloudflare.com"
    echo -e "Reality PublicKey: ${PUB_KEY1}"
    echo -e "Reality ShortId: ${SHORTID1}"
    echo -e ""
    
    echo -e "${YELLOW}--- 节点 2: Reality (Port ${PORT_REALITY_2}) ---${PLAIN}"
    echo -e "地址 (Address): ${IP}"
    echo -e "端口 (Port): ${PORT_REALITY_2}"
    echo -e "协议 (Protocol): vless"
    echo -e "流控 (Flow): xtls-rprx-vision (推荐开启)"
    echo -e "传输方式 (Network): tcp"
    echo -e "伪装类型 (Type): none"
    echo -e "Reality ServerName: www.cloudflare.com"
    echo -e "Reality PublicKey: ${PUB_KEY2}"
    echo -e "Reality ShortId: ${SHORTID2}"
    echo -e ""
    
    echo -e "${YELLOW}--- 节点 3: WS + TLS + CDN (Port 443) ---${PLAIN}"
    echo -e "地址 (Address): ${DOMAIN} (请开启 CDN)"
    echo -e "端口 (Port): 443"
    echo -e "协议 (Protocol): vless"
    echo -e "传输方式 (Network): ws"
    echo -e "路径 (Path): ${WS_PATH}"
    echo -e "Host: ${DOMAIN}"
    echo -e "TLS: 开启"
    echo -e ""
    echo -e "${GREEN}脚本执行结束。日志文件: ${LOG_FILE}${PLAIN}"
}

# 主程序
main() {
    check_root
    
    echo -e "${GREEN}欢迎使用 Xray 自动部署脚本 (优化版)${PLAIN}"
    read -p "请输入您的域名 (例如: example.com): " DOMAIN
    
    if [ -z "$DOMAIN" ]; then
        echo -e "${RED}域名不能为空！${PLAIN}"
        exit 1
    fi
    
    install_dependencies
    configure_firewall
    install_xray
    generate_credentials
    configure_xray
    configure_nginx
    output_info
}

main
