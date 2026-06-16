#!/bin/sh
# ========== 0. 检查磁盘空间 ==========
echo "当前磁盘使用情况："
df -h

# ========== 1. 添加 iStore 专属 feeds 源 ==========
if ! grep -q "istore" feeds.conf.default; then
    echo 'src-git istore https://github.com/linkease/istore.git;main' >> feeds.conf.default
    echo 'src-git nas https://github.com/linkease/nas-packages.git;master' >> feeds.conf.default
    echo 'src-git nas_luci https://github.com/linkease/nas-packages-luci.git;main' >> feeds.conf.default
fi

./scripts/feeds update istore nas nas_luci
./scripts/feeds install -a -p istore
./scripts/feeds install -a -p nas
./scripts/feeds install -a -p nas_luci

# ========== 2. 更新 nss_packages（必须在删除补丁之前） ==========
./scripts/feeds update nss_packages
./scripts/feeds install -a -p nss_packages

# ========== 3. 删除不兼容的补丁 ==========
PATCH_FILE="feeds/nss_packages/qca-nss-ecm/patches/100-fix-ecm-6.12-compat.patch"
if [ -f "$PATCH_FILE" ]; then
    rm -f "$PATCH_FILE"
    echo "已删除补丁 $PATCH_FILE"
fi
rm -f target/linux/qualcommax/patches-6.12/060*-qca-nss-clients-*.patch

# ========== 4. 直接注释掉有问题的代码行（而非条件编译） ==========
ECM_SRC="$(find feeds/nss_packages/qca-nss-ecm -name "ecm_interface.c" | head -1)"
if [ -n "$ECM_SRC" ] && [ -f "$ECM_SRC" ]; then
    echo "正在修复 $ECM_SRC ..."
    cp "$ECM_SRC" "$ECM_SRC.bak"
    
    # 注释掉 vxlan_fdb_update_mac 调用
    sed -i 's/\(vxlan_fdb_update_mac(priv, mac_addr, vxlan_info.vni);\)/\/\/ \1  \/\/ disabled by script/g' "$ECM_SRC"
    
    # 注释掉 pptp_channel_addressing_get 调用（如果存在）
    sed -i 's/\(pptp_channel_addressing_get(&opt, ppp_chan\[0\]);\)/\/\/ \1  \/\/ disabled by script/g' "$ECM_SRC"
    
    # 注释掉 __ppp_is_multilink 调用（可能有多处，用更通用的方式）
    sed -i 's/\(__ppp_is_multilink([^)]*);\)/\/\/ \1  \/\/ disabled by script/g' "$ECM_SRC"
    
    echo "✅ 已注释掉冲突的函数调用"
else
    echo "⚠️ 未找到 ecm_interface.c，跳过"
fi

# ========== 5. 清理构建残留 ==========
rm -rf build_dir/target-*/qca-nss-ecm-*

# ========== 6. 配置选项 ==========
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

./scripts/config --disable CONFIG_ECM_INTERFACE_PPTP \
                 --disable CONFIG_ECM_INTERFACE_VXLAN \
                 --disable CONFIG_ECM_INTERFACE_L2TPV2 \
                 --disable CONFIG_ECM_INTERFACE_GRE \
                 --disable CONFIG_ECM_INTERFACE_GRE_TAP \
                 --disable CONFIG_ECM_INTERFACE_GRE_TUN \
                 --disable CONFIG_ECM_INTERFACE_SIT \
                 --disable CONFIG_ECM_INTERFACE_TUNIPIP6 \
                 --disable CONFIG_ECM_INTERFACE_BOND

make olddefconfig

# ========== 7. 生成代理打包脚本 ==========
cat > "$(pwd)/collect_proxy_pkgs.sh" << 'EOF'
#!/bin/sh
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PKG_BASE="$SCRIPT_DIR/bin/packages"
ARCH_DIR=$(find "$PKG_BASE" -type d -name "packages" | head -1)
[ -z "$ARCH_DIR" ] && { echo "未找到 packages 目录"; exit 1; }
OUTPUT_DIR="$SCRIPT_DIR/bin/targets/*/*"
TAR_NAME="proxy-packages.tar.gz"
WORK_DIR=$(mktemp -d)
cd "$WORK_DIR" || exit 1
PACKAGES="luci-app-openclash luci-app-passwall luci-app-passwall2 luci-app-homeproxy luci-app-ssr-plus xray-core sing-box clash hysteria v2ray-geodata geoview haproxy chinadns-ng tcping ipt2socks microsocks"
for pkg in $PACKAGES; do
    find "$ARCH_DIR" -name "${pkg}*.ipk" -exec cp -t "$WORK_DIR" {} \;
done
if [ "$(ls -A *.ipk 2>/dev/null)" ]; then
    tar -czf "$TAR_NAME" *.ipk
    for dir in $OUTPUT_DIR; do
        [ -d "$dir" ] && cp "$TAR_NAME" "$dir/"
    done
fi
rm -rf "$WORK_DIR"
EOF
chmod +x "$(pwd)/collect_proxy_pkgs.sh"

# ========== 8. 预置安装脚本 ==========
mkdir -p package/base-files/files/root
cat > package/base-files/files/root/install-proxy.sh << 'EOF'
#!/bin/sh
if [ -f /tmp/proxy-packages.tar.gz ]; then
    mkdir -p /tmp/proxy_ipk
    tar -xzf /tmp/proxy-packages.tar.gz -C /tmp/proxy_ipk
    cd /tmp/proxy_ipk || exit 1
    opkg update && opkg install *.ipk --force-overwrite
    cd / && rm -rf /tmp/proxy_ipk
    echo "代理插件安装完成！"
else
    echo "请先上传 proxy-packages.tar.gz 到 /tmp"
    exit 1
fi
EOF
chmod +x package/base-files/files/root/install-proxy.sh

echo "========== 所有准备工作完成 =========="
echo "- 已删除冲突补丁，并注释掉 ecm_interface.c 中的问题调用"
echo "- 配置已更新 (olddefconfig)"
echo "- 代理打包脚本和安装脚本已生成"
echo "现在请执行 make -j$(nproc) 开始编译"
