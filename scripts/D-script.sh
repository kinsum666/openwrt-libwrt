#!/bin/sh
# ========== 1. 添加 iStore 专属 feeds 源 ==========
if ! grep -q "istore" feeds.conf.default; then
    echo 'src-git istore https://github.com/linkease/istore.git;main' >> feeds.conf.default
    echo 'src-git nas https://github.com/linkease/nas-packages.git;master' >> feeds.conf.default
    echo 'src-git nas_luci https://github.com/linkease/nas-packages-luci.git;main' >> feeds.conf.default
fi

# 更新并安装 iStore 相关的 feeds
./scripts/feeds update istore nas nas_luci
./scripts/feeds install -a -p istore
./scripts/feeds install -a -p nas
./scripts/feeds install -a -p nas_luci

# ========== 全局刷新 feeds，确保所有依赖可用 ==========
./scripts/feeds update -a
./scripts/feeds install -a

# ========== 2. 使用 scripts/config 安全设置所有选项 ==========
# 启用 iStore 核心组件
./scripts/config --enable CONFIG_PACKAGE_luci-app-istorex \
                 --enable CONFIG_PACKAGE_luci-app-quickstart \
                 --enable CONFIG_PACKAGE_luci-app-store

# 启用 Docker 核心及管理界面
./scripts/config --enable CONFIG_PACKAGE_docker \
                 --enable CONFIG_PACKAGE_dockerd \
                 --enable CONFIG_PACKAGE_containerd \
                 --enable CONFIG_PACKAGE_runc \
                 --enable CONFIG_PACKAGE_luci-app-dockerman \
                 --enable CONFIG_PACKAGE_luci-i18n-dockerman-zh-cn

# 启用 iStore 依赖库
./scripts/config --enable CONFIG_PACKAGE_luci-lib-taskd \
                 --enable CONFIG_PACKAGE_luci-lib-xterm \
                 --enable CONFIG_PACKAGE_luci-compat

# 启用可选配套工具
./scripts/config --enable CONFIG_PACKAGE_luci-app-diskman \
                 --enable CONFIG_PACKAGE_luci-app-ddns-to

# 禁用与内核 6.12 不兼容的 NSS ECM 接口
./scripts/config --disable CONFIG_ECM_INTERFACE_PPTP \
                 --disable CONFIG_ECM_INTERFACE_VXLAN \
                 --disable CONFIG_ECM_INTERFACE_L2TPV2 \
                 --disable CONFIG_ECM_INTERFACE_GRE \
                 --disable CONFIG_ECM_INTERFACE_GRE_TAP \
                 --disable CONFIG_ECM_INTERFACE_GRE_TUN \
                 --disable CONFIG_ECM_INTERFACE_SIT \
                 --disable CONFIG_ECM_INTERFACE_TUNIPIP6 \
                 --disable CONFIG_ECM_INTERFACE_BOND

# ========== 关键：启用 Docker 所需的内核功能 ==========
./scripts/config --enable CONFIG_KERNEL_CGROUPS \
                 --enable CONFIG_KERNEL_CGROUP_CPUACCT \
                 --enable CONFIG_KERNEL_CGROUP_DEVICE \
                 --enable CONFIG_KERNEL_CGROUP_FREEZER \
                 --enable CONFIG_KERNEL_CGROUP_SCHED \
                 --enable CONFIG_KERNEL_CPUSETS \
                 --enable CONFIG_KERNEL_NAMESPACES \
                 --enable CONFIG_KERNEL_NET_NS \
                 --enable CONFIG_KERNEL_PID_NS \
                 --enable CONFIG_KERNEL_IPC_NS \
                 --enable CONFIG_KERNEL_UTS_NS \
                 --enable CONFIG_KERNEL_USER_NS \
                 --enable CONFIG_KERNEL_OVERLAY_FS \
                 --enable CONFIG_KERNEL_VETH

# 重新生成配置（使依赖自动解析）
make defconfig

# ========== 3. 修复因内核版本升级导致的 NSS 补丁失败 ==========
rm -f target/linux/qualcommax/patches-6.12/060*-qca-nss-clients-*.patch
echo "已移除不兼容的 NSS 客户端补丁"

# ========== 4. 生成代理插件打包脚本 ==========
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

# ========== 5. 预置安装脚本到固件 ==========
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

echo "已添加 iStore 源，写入配置并重新 defconfig，同时生成代理打包脚本和安装脚本"
