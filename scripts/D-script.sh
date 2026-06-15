# ========== 生成代理插件打包脚本（供编译后使用） ==========
# 注意：此脚本将在编译完成后由 GitHub Actions 的 Organize Files 步骤调用
# 使用绝对路径，避免依赖环境变量
cat > "$(pwd)/collect_proxy_pkgs.sh" << 'EOF'
#!/bin/sh
# 自动查找 OpenWrt 编译目录
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_BASE="$SCRIPT_DIR/bin/packages"

# 查找实际的架构目录（如 aarch64_cortex-a53 或 qualcommax）
ARCH_DIR=$(find "$PKG_BASE" -type d -name "packages" | head -1)
if [ -z "$ARCH_DIR" ]; then
    echo "未找到 packages 目录"
    exit 1
fi

OUTPUT_DIR="$SCRIPT_DIR/bin/targets/*/*"
TAR_NAME="proxy-packages.tar.gz"

WORK_DIR=$(mktemp -d)
cd "$WORK_DIR" || exit 1

# 需要收集的包名列表
PACKAGES="luci-app-openclash luci-app-passwall luci-app-passwall2 luci-app-homeproxy luci-app-ssr-plus \
          xray-core sing-box clash hysteria v2ray-geodata geoview haproxy chinadns-ng tcping ipt2socks microsocks"

for pkg in $PACKAGES; do
    find "$ARCH_DIR" -name "${pkg}*.ipk" -exec cp -t "$WORK_DIR" {} \;
done

if [ "$(ls -A *.ipk 2>/dev/null)" ]; then
    tar -czf "$TAR_NAME" *.ipk
    # 复制到每个固件输出目录
    for dir in $OUTPUT_DIR; do
        if [ -d "$dir" ]; then
            cp "$TAR_NAME" "$dir/"
            echo "代理包已复制到: $dir/$TAR_NAME"
        fi
    done
else
    echo "警告：未找到任何代理 ipk 文件"
fi

rm -rf "$WORK_DIR"
EOF

chmod +x "$(pwd)/collect_proxy_pkgs.sh"

# 预置安装脚本到固件（刷机后位于 /root/install-proxy.sh）
mkdir -p package/base-files/files/root
cat > package/base-files/files/root/install-proxy.sh << 'EOF'
#!/bin/sh
# 一键安装代理插件（手动上传 proxy-packages.tar.gz 到 /tmp）
if [ -f /tmp/proxy-packages.tar.gz ]; then
    mkdir -p /tmp/proxy_ipk
    tar -xzf /tmp/proxy-packages.tar.gz -C /tmp/proxy_ipk
    cd /tmp/proxy_ipk || exit 1
    opkg update
    opkg install *.ipk --force-overwrite
    cd /
    rm -rf /tmp/proxy_ipk
    echo "代理插件安装完成！请重启 LuCI 或路由器。"
else
    echo "错误：请先上传 proxy-packages.tar.gz 到 /tmp 目录"
    exit 1
fi
EOF
chmod +x package/base-files/files/root/install-proxy.sh

echo "已生成 collect_proxy_pkgs.sh 和预置安装脚本"
