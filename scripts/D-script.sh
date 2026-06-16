
#!/bin/sh
# ========== 清理磁盘空间（适用于 OpenWrt 构建目录） ==========
echo "=== 清理旧构建文件，释放空间 ==="
# 删除构建产物（保留配置和下载缓存）
make clean

# 如果空间仍然不足，可以进一步清理（会删除所有构建目录，但保留 config 和 dl）
# make dirclean

# 删除临时文件
rm -rf tmp/* logs/*
# 清空部分大包下载（可选，需要重新下载）
# rm -rf dl/*

# 检查剩余空间
df -h
echo "=== 开始正常编译 ==="


# ========== 1. 添加 iStore 专属 feeds 源 ==========
if ! grep -q "istore" feeds.conf.default; then
    echo 'src-git istore https://github.com/linkease/istore.git;main' >> feeds.conf.default
    echo 'src-git nas https://github.com/linkease/nas-packages.git;master' >> feeds.conf.default
    echo 'src-git nas_luci https://github.com/linkease/nas-packages-luci.git;main' >> feeds.conf.default
fi

# 更新并安装 iStore 相关 feeds
./scripts/feeds update istore nas nas_luci
./scripts/feeds install -a -p istore
./scripts/feeds install -a -p nas
./scripts/feeds install -a -p nas_luci

# ========== 2. 更新 nss_packages（必须在删除补丁之前） ==========
./scripts/feeds update nss_packages
./scripts/feeds install -a -p nss_packages

# ========== 3. 删除不兼容的补丁（更新后立即执行） ==========
PATCH_FILE="feeds/nss_packages/qca-nss-ecm/patches/100-fix-ecm-6.12-compat.patch"
if [ -f "$PATCH_FILE" ]; then
    rm -f "$PATCH_FILE"
    echo "已删除旧的补丁文件 $PATCH_FILE"
fi

# 同时删除其他可能冲突的 NSS 客户端补丁（如有）
rm -f target/linux/qualcommax/patches-6.12/060*-qca-nss-clients-*.patch

# ========== 4. 手动修改 ecm_interface.c 添加条件编译保护 ==========
ECM_SRC="$(find feeds/nss_packages/qca-nss-ecm -name "ecm_interface.c" | head -1)"
if [ -n "$ECM_SRC" ] && [ -f "$ECM_SRC" ]; then
    echo "找到 ecm_interface.c: $ECM_SRC，正在添加条件编译保护..."
    cp "$ECM_SRC" "$ECM_SRC.bak"
    # 为 __ppp_is_multilink 调用加宏保护
    sed -i '/if (__ppp_is_multilink(dev) > 0) {/i #ifdef ECM_INTERFACE_PPTP_ENABLE' "$ECM_SRC"
    sed -i '/if (__ppp_is_multilink(dev) > 0) {/a #endif' "$ECM_SRC"
    # 为 pptp_channel_addressing_get 调用加宏保护
    sed -i '/pptp_channel_addressing_get(&opt, ppp_chan\[0\]);/i #ifdef ECM_INTERFACE_PPTP_ENABLE' "$ECM_SRC"
    sed -i '/pptp_channel_addressing_get(&opt, ppp_chan\[0\]);/a #endif' "$ECM_SRC"
    # 为 vxlan_fdb_update_mac 调用加宏保护
    sed -i '/vxlan_fdb_update_mac(priv, mac_addr, vxlan_info.vni);/i #ifdef ECM_INTERFACE_VXLAN_ENABLE' "$ECM_SRC"
    sed -i '/vxlan_fdb_update_mac(priv, mac_addr, vxlan_info.vni);/a #endif' "$ECM_SRC"
    echo "✅ 已添加条件编译保护到 ecm_interface.c"
else
    echo "⚠️ 警告：未找到 ecm_interface.c，跳过修复"
fi

# ========== 5. 清理 ECM 构建残留 ==========
rm -rf build_dir/target-*/qca-nss-ecm-*

# ========== 6. 配置选项（写入 .config） ==========
# 启用 iStore / Docker 相关包
./scripts/config --enable CONFIG_PACKAGE_luci-app-istorex \
                 --enable CONFIG_PACKAGE_luci-app-quickstart \
                 --enable CONFIG_PACKAGE_luci-app-store \
                 --enable CONFIG_PACKAGE_luci-app-dockerman \
                 --enable CONFIG_PACKAGE_luci-i18n-dockerman-zh-cn \
                 --enable CONFIG_PACKAGE_luci-lib-taskd \
                 --enable CONFIG_PACKAGE_luci-lib-xterm \
                 --enable CONFIG_PACKAGE_luci-compat \
                 --enable CONFIG_PACKAGE_luci-app-diskman \
                 --enable CONFIG_PACKAGE_luci-app-ddns-to

# 禁用与内核 6.12 不兼容的 ECM 接口模块
./scripts/config --disable CONFIG_ECM_INTERFACE_PPTP \
                 --disable CONFIG_ECM_INTERFACE_VXLAN \
                 --disable CONFIG_ECM_INTERFACE_L2TPV2 \
                 --disable CONFIG_ECM_INTERFACE_GRE \
                 --disable CONFIG_ECM_INTERFACE_GRE_TAP \
                 --disable CONFIG_ECM_INTERFACE_GRE_TUN \
                 --disable CONFIG_ECM_INTERFACE_SIT \
                 --disable CONFIG_ECM_INTERFACE_TUNIPIP6 \
                 --disable CONFIG_ECM_INTERFACE_BOND

# ========== 7. 生成最终配置 ==========
make olddefconfig

# ========== 8. 生成代理插件打包脚本（供编译后使用） ==========
cat > "$(pwd)/collect_proxy_pkgs.sh" << 'EOF'
#!/bin/sh
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_BASE="$SCRIPT_DIR/bin/packages"
ARCH_DIR=$(find "$PKG_BASE" -type d -name "packages" | head -1)
if [ -z "$ARCH_DIR" ]; then
    echo "未找到 packages 目录"
    exit 1
fi

OUTPUT_DIR="$SCRIPT_DIR/bin/targets/*/*"
TAR_NAME="proxy-packages.tar.gz"
WORK_DIR=$(mktemp -d)
cd "$WORK_DIR" || exit 1

PACKAGES="luci-app-openclash luci-app-passwall luci-app-passwall2 luci-app-homeproxy luci-app-ssr-plus \
          xray-core sing-box clash hysteria v2ray-geodata geoview haproxy chinadns-ng tcping ipt2socks microsocks"

for pkg in $PACKAGES; do
    find "$ARCH_DIR" -name "${pkg}*.ipk" -exec cp -t "$WORK_DIR" {} \;
done

if [ "$(ls -A *.ipk 2>/dev/null)" ]; then
    tar -czf "$TAR_NAME" *.ipk
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

# ========== 9. 预置安装脚本到固件 ==========
mkdir -p package/base-files/files/root
cat > package/base-files/files/root/install-proxy.sh << 'EOF'
#!/bin/sh
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

echo "========== 所有准备工作完成 =========="
echo "- iStore 源已添加，NSS 补丁已删除并手动修复"
echo "- 配置已更新 (olddefconfig)"
echo "- 代理打包脚本和安装脚本已生成"
echo "现在可以执行 make 或 make world 开始编译"
