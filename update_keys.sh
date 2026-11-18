#!/bin/bash

# ====================================================
# Xray 密钥更新与验证脚本
# 功能：
# 1. 生成两对新的 X25519 密钥
# 2. 打印生成的公私钥对（用于验证解析逻辑）
# 3. 更新现有的 Xray 配置文件 (/usr/local/etc/xray/config.json)
# 4. 重启 Xray 服务
# ====================================================

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
PLAIN='\033[0m'

CONFIG_FILE="/usr/local/etc/xray/config.json"

# 检查 root 权限
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}请以 root 用户运行此脚本！${PLAIN}"
    exit 1
fi

# 检查 Xray 是否安装
if ! command -v xray &> /dev/null; then
    echo -e "${RED}Xray 未安装，请先运行部署脚本。${PLAIN}"
    exit 1
fi

# 检查配置文件是否存在
if [ ! -f "$CONFIG_FILE" ]; then
    echo -e "${RED}配置文件 $CONFIG_FILE 不存在！${PLAIN}"
    exit 1
fi

echo -e "${YELLOW}正在生成新的密钥对...${PLAIN}"

# --- 生成第 1 对密钥 ---
OUTPUT1=$(xray x25519)
# 解析逻辑：兼容不同版本的 xray x25519 输出格式
#   旧版: "Private key: <key>" / "Public key: <key>"
#   新版: "PrivateKey: <key>" / "Password (PublicKey): <key>" / "Hash32: ..."
# 密钥始终是所在行的最后一个字段，故用 $NF 提取，避免新版多出的标签列被误取
PRI_KEY1=$(echo "$OUTPUT1" | grep -i "private" | awk '{print $NF}')
PUB_KEY1=$(echo "$OUTPUT1" | grep -iE "public|password" | awk '{print $NF}')

# --- 生成第 2 对密钥 ---
OUTPUT2=$(xray x25519)
PRI_KEY2=$(echo "$OUTPUT2" | grep -i "private" | awk '{print $NF}')
PUB_KEY2=$(echo "$OUTPUT2" | grep -iE "public|password" | awk '{print $NF}')

# --- 打印验证信息 ---
echo -e ""
echo -e "${GREEN}=== 密钥生成验证 ===${PLAIN}"
echo -e "${YELLOW}Key Pair 1:${PLAIN}"
echo -e "  Private Key: ${PRI_KEY1}"
echo -e "  Public Key : ${PUB_KEY1}"
echo -e ""
echo -e "${YELLOW}Key Pair 2:${PLAIN}"
echo -e "  Private Key: ${PRI_KEY2}"
echo -e "  Public Key : ${PUB_KEY2}"
echo -e "======================"
echo -e ""

# --- 验证解析结果是否为空 ---
if [ -z "$PRI_KEY1" ] || [ -z "$PUB_KEY1" ] || [ -z "$PRI_KEY2" ] || [ -z "$PUB_KEY2" ]; then
    echo -e "${RED}错误：密钥解析失败！请检查 xray x25519 输出格式。${PLAIN}"
    echo -e "原始输出 1: \n$OUTPUT1"
    exit 1
fi

echo -e "${YELLOW}正在更新配置文件...${PLAIN}"

# 使用 jq 更新配置文件
# 注意：这里假设配置文件结构符合标准 Xray 格式
# 我们需要找到两个 Reality 入站配置并替换 privateKey
# 通常 Reality 端口是第一个和第二个入站，但为了保险，我们可以根据端口匹配或者假设顺序
# 这里简单起见，假设第 1 个入站是 Reality1，第 2 个是 Reality2 (对应 deploy_xray.sh 的结构)

# 备份配置文件（-p 保留原始属主与权限，便于回滚时原样还原）
BACKUP_FILE="${CONFIG_FILE}.bak_$(date +%s)"
cp -p "$CONFIG_FILE" "$BACKUP_FILE"

# 更新 privateKey 并写回配置。注意两点：
# 1) 用 “cat > 原文件” 而非 “mv 覆盖”，可保留原文件的 inode、属主与权限，
#    避免 mktemp 默认的 0600 权限被带到 config.json 上
#    （xray 官方 systemd 服务以 User=nobody 运行，读不到配置会报 permission denied）；
# 2) 显式 chmod 644，与 deploy_xray.sh 生成的权限保持一致，同时能自动修复被改坏的文件权限。
tmp=$(mktemp)
jq --arg key "$PRI_KEY1" '.inbounds[0].streamSettings.realitySettings.privateKey = $key' "$CONFIG_FILE" > "$tmp" && cat "$tmp" > "$CONFIG_FILE"

# 更新第二个 privateKey (inbounds[1])
jq --arg key "$PRI_KEY2" '.inbounds[1].streamSettings.realitySettings.privateKey = $key' "$CONFIG_FILE" > "$tmp" && cat "$tmp" > "$CONFIG_FILE"
rm -f "$tmp"

chmod 644 "$CONFIG_FILE"

echo -e "${GREEN}配置文件更新完成。${PLAIN}"
echo -e "${YELLOW}正在重启 Xray...${PLAIN}"

systemctl restart xray

if systemctl is-active --quiet xray; then
    echo -e "${GREEN}Xray 重启成功！${PLAIN}"
    echo -e ""
    echo -e "请更新客户端配置中的 Public Key："
    echo -e "节点 1 (Reality): ${PUB_KEY1}"
    echo -e "节点 2 (Reality): ${PUB_KEY2}"
else
    echo -e "${RED}Xray 重启失败！请检查日志： journalctl -u xray -n 20${PLAIN}"
    echo -e "已尝试还原备份..."
    cp -p "$BACKUP_FILE" "$CONFIG_FILE"
fi
