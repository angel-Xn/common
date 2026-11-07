#!/bin/bash
# SPDX-License-Identifier: GPL-3.0-only
PWD_DIR="$(pwd)"

function install_mustrelyon(){
echo -e "\033[36m开始升级ubuntu插件和安装依赖.....\033[0m"
# 网络操作全部限时+重试,防止 runner 网络抖动导致无限挂起
# DPkg::Lock::Timeout: 防止 unattended-upgrades 占锁时 apt 无限等锁
cat > /etc/apt/apt.conf.d/80-timeouts <<'EOF'
Acquire::Retries "3";
Acquire::http::Timeout "30";
Acquire::https::Timeout "30";
DPkg::Lock::Timeout "120";
EOF
# 停掉自动升级服务,避免抢 dpkg 锁
systemctl stop unattended-upgrades 2>/dev/null || true
systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
# 注意:Acquire::Timeout 只管"无数据",慢速滴流连接照样无限拖;
# 所以下面每条 apt/网络命令都套 timeout 硬上限,超时就跳过继续。
# 更新ubuntu源
echo "[$(date +%H:%M:%S)] apt-get update"
timeout 600 apt-get update -y || echo "apt update 超时/失败,继续"

# 升级ubuntu(最佳努力,超时跳过)
echo "[$(date +%H:%M:%S)] apt-get full-upgrade"
timeout 900 apt-get full-upgrade -y || echo "系统升级超时/失败,继续安装依赖"

# 安装编译openwrt的依赖
echo "[$(date +%H:%M:%S)] apt-get install 基础依赖"
timeout 600 apt-get install -y ecj fastjar file gettext java-propose-classpath time xsltproc lib32gcc-s1 || true
echo "[$(date +%H:%M:%S)] apt-get install 主依赖清单"
timeout 1800 apt-get install -y ack antlr3 asciidoc autoconf automake autopoint binutils bison build-essential \
bzip2 ccache cmake cpio curl device-tree-compiler flex gawk gcc-multilib g++-multilib gettext \
genisoimage git gperf haveged help2man intltool libc6-dev-i386 libelf-dev libfuse-dev libglib2.0-dev \
libgmp3-dev libltdl-dev libmpc-dev libmpfr-dev libncurses5-dev libncursesw5-dev libpython3-dev \
libreadline-dev libssl-dev libtool llvm lrzsz msmtp ninja-build p7zip p7zip-full patch pkgconf \
python2 python3 python3-pip python3-cryptography python3-docutils python3-ply python3-pyelftools python3-requests
python3-setuptools python3-distutils python3-netifaces qemu-utils rsync scons squashfs-tools subversion swig \
texinfo uglifyjs upx-ucl unzip vim wget xmlto xxd zlib1g-dev || echo "主依赖安装超时/失败,继续(后续编译按需补)"

# alist依赖
timeout 600 apt-get install -y libfuse-dev || true

# N1打包需要的依赖(jq 用 apt 安装,弃用 snap:snapd 拉商店是著名挂死点)
timeout 600 apt-get install -y rename pigz clang gnupg jq || true
EXTRA_DEPS="$(curl -fsSL --retry 2 --max-time 60 https://tinyurl.com/ubuntu2204-make-openwrt 2>/dev/null || true)"
if [ -n "${EXTRA_DEPS}" ]; then
    timeout 600 apt-get install -y ${EXTRA_DEPS} || true
fi

# 安装gcc g++
GCC_VERSION="13"
timeout 300 add-apt-repository --yes ppa:ubuntu-toolchain-r/test || echo "toolchain PPA 添加失败,继续用系统 gcc"
timeout 600 apt-get update -y || true
timeout 900 apt-get install -y gcc-${GCC_VERSION} || true
timeout 900 apt-get install -y g++-${GCC_VERSION} || true
update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-${GCC_VERSION} 60
update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-${GCC_VERSION} 60
update-alternatives --set gcc /usr/bin/gcc-${GCC_VERSION} || true
update-alternatives --set g++ /usr/bin/g++-${GCC_VERSION} || true

cd $TMP_DIR
# 安装golang
GO_VERSION="1.24.2"
wget -q --timeout=30 --tries=3 https://go.dev/dl/go${GO_VERSION}.linux-amd64.tar.gz -O /tmp/go${GO_VERSION}.linux-amd64.tar.gz || echo "go 下载失败,继续(编译阶段会按需自行拉取)"
sudo tar -C /usr/local -xzf /tmp/go${GO_VERSION}.linux-amd64.tar.gz
echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee -a /etc/profile.d/go.sh
source /etc/profile.d/go.sh
cd $PWD_DIR

# 安装nodejs yarn
curl -fsSL --retry 2 --max-time 120 https://deb.nodesource.com/setup_22.x -o /tmp/nodesource_setup.sh && \
  timeout 300 bash /tmp/nodesource_setup.sh || echo "nodesource 源配置失败,继续"
timeout 600 apt-get install -y nodejs || true
curl -sL --retry 2 --max-time 60 https://dl.yarnpkg.com/debian/pubkey.gpg | sudo gpg --batch --yes --dearmor -o /usr/share/keyrings/yarnkey.gpg
echo "deb [signed-by=/usr/share/keyrings/yarnkey.gpg] https://dl.yarnpkg.com/debian stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
timeout 600 apt-get update -y && timeout 600 apt-get install -y yarn gh || echo "yarn/gh 安装失败,继续"

cd $TMP_DIR
# 安装UPX
UPX_VERSION="5.0.0"
curl -fLO --retry 2 --max-time 300 "https://github.com/upx/upx/releases/download/v${UPX_VERSION}/upx-$UPX_VERSION-amd64_linux.tar.xz"
tar -Jxf "upx-$UPX_VERSION-amd64_linux.tar.xz"
rm -rf "/usr/bin/upx" "/usr/bin/upx-ucl"
cp -fp "upx-$UPX_VERSION-amd64_linux/upx" "/usr/bin/upx-ucl"
chmod 0755 "/usr/bin/upx-ucl"
ln -svf "/usr/bin/upx-ucl" "/usr/bin/upx"
cd $PWD_DIR

cd $TMP_DIR
# 安装padjffs2
timeout 900 git clone --filter=blob:none --no-checkout "https://github.com/openwrt/openwrt.git" "padjffs2"
pushd "padjffs2"
git config core.sparseCheckout true
echo "tools/padjffs2/src" >> ".git/info/sparse-checkout"
timeout 600 git checkout
cd "tools/padjffs2/src"
make padjffs2
strip "padjffs2"
rm -rf "/usr/bin/padjffs2"
cp -fp "padjffs2" "/usr/bin/padjffs2"
popd
cd $PWD_DIR

cd $TMP_DIR
# 安装po2lmo
timeout 900 git clone --filter=blob:none --no-checkout "https://github.com/openwrt/luci.git" "po2lmo"
pushd "po2lmo"
git config core.sparseCheckout true
echo "modules/luci-base/src" >> ".git/info/sparse-checkout"
timeout 600 git checkout
cd "modules/luci-base/src"
make po2lmo
strip "po2lmo"
rm -rf "/usr/bin/po2lmo"
cp -fp "po2lmo" "/usr/bin/po2lmo"
popd
cd $PWD_DIR

curl -fL --retry 2 --max-time 120 "https://build-scripts.immortalwrt.org/modify-firmware.sh" -o "/usr/bin/modify-firmware"
chmod 0755 "/usr/bin/modify-firmware"
}

function update_apt_source(){
timeout 600 apt-get autoremove -y --purge || true
apt-get clean -y

python2.7 --version
python3 --version
node -v
yarn -v
go version
gcc --version
g++ --version
clang --version
upx --version
echo "GitHub CLI：$(gh --version)"
echo -e "\033[32m全部依赖安装完毕!\033[0m"
}

function main(){
	if [[ -n "${BENDI_VERSION}" ]]; then
		export BENDI_VERSION="1"
		install_mustrelyon
		update_apt_source
	else
		install_mustrelyon
		update_apt_source
	fi
}

main
