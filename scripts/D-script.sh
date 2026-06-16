#!/bin/sh
# ========== 1. 添加 iStore 专属 feeds 源（编译前执行） ==========
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

# ========== 2. 将 iStore/Docker 组件写入 .config（强制编译进固件） ==========
# 使用 scripts/config 设置 iStore 相关选项（避免追加导致冲突）
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

# 禁用与内核 6.12 不兼容的 ECM 接口模块（使用正确选项名）
./scripts/config --disable CONFIG_ECM_INTERFACE_PPTP \
                 --disable CONFIG_ECM_INTERFACE_VXLAN \
                 --disable CONFIG_ECM_INTERFACE_L2TPV2 \
                 --disable CONFIG_ECM_INTERFACE_GRE \
                 --disable CONFIG_ECM_INTERFACE_GRE_TAP \
                 --disable CONFIG_ECM_INTERFACE_GRE_TUN \
                 --disable CONFIG_ECM_INTERFACE_SIT \
                 --disable CONFIG_ECM_INTERFACE_TUNIPIP6 \
                 --disable CONFIG_ECM_INTERFACE_BOND

# 关键步骤：重新解析配置，使上述选项生效（使用 olddefconfig 保留手动设置）
make olddefconfig

# ========== 修复因内核版本升级导致的 NSS 补丁失败 ==========
rm -f target/linux/qualcommax/patches-6.12/060*-qca-nss-clients-*.patch
echo "已移除不兼容的 NSS 客户端补丁"

# ========== 额外修复 qca-nss-ecm 与 Linux 6.12 的兼容性（添加条件编译保护） ==========
# 创建补丁文件到 feeds 目录，使其永久生效
PATCH_DIR="feeds/nss_packages/qca-nss-ecm/patches"
mkdir -p "$PATCH_DIR"

cat > "$PATCH_DIR/100-fix-ecm-6.12-compat.patch" << 'EOF'
--- a/ecm_interface.c
+++ b/ecm_interface.c
@@ -3763,7 +3763,9 @@
 		}
 	}
 
+#ifdef ECM_INTERFACE_PPTP_ENABLE
 	if (__ppp_is_multilink(dev) > 0) {
+#endif
 		/*
 		 * We are a multilink PPP interface, we can also do handling similar to PPP.
 		 */
@@ -3872,9 +3874,11 @@
 					pppoe_channel_addressing_get(&opt, ppp_chan[0]);
 					break;
 
+#ifdef ECM_INTERFACE_PPTP_ENABLE
 				case ECM_INTERFACE_PPP_TYPE_PPTP:
 					pptp_channel_addressing_get(&opt, ppp_chan[0]);
 					break;
+#endif
 
 				default:
 					DEBUG_WARN("Unknown PPP channel type\n");
@@ -6763,7 +6767,9 @@
 						unsigned char *mac_addr = ecm_sfe_ipv6_get_macaddr(addr6);
 
 						if (mac_addr && !is_multicast_ether_addr(mac_addr)) {
+#ifdef ECM_INTERFACE_VXLAN_ENABLE
 							vxlan_fdb_update_mac(priv, mac_addr, vxlan_info.vni);
+#endif
 						}
 					}
 				}
EOF

# 更新 nss_packages feeds 以应用补丁
./scripts/feeds update nss_packages
./scripts/feeds install -a -p nss_packages

# 清理 ECM 构建残留，避免旧对象干扰
rm -rf build_dir/target-*/qca-nss-ecm-*
echo "已清理 ECM 构建残留"

# ========== 3. 生成代理插件打包脚本（供编译后使用） ==========
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

# ========== 4. 预置安装脚本到固件 ==========
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
echo "已修复 qca-nss-ecm 与 Linux 6.12 的兼容性问题"
