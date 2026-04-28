#!/bin/sh
set -e

# 环境变量检查，其中 GITHUB_REPOSITORY_OWNER 由 GitHub Actions 自动注入，其他变量需自行准备
REQUIRED_VARS="
GITHUB_REPOSITORY_OWNER
ALIBABA_CLOUD_ACCESS_KEY_ID
ALIBABA_CLOUD_ACCESS_KEY_SECRET
OSS_ENDPOINT
OSS_BUCKET
OSS_REGION
CDN_DOMAIN
"
for var in $REQUIRED_VARS; do
    if [ -z "$(eval echo \$$var)" ]; then
        echo ">>> [ERROR] Environment variable $var is missing. Aborting."
        exit 1
    fi
done

WORKDIR=$(pwd)
PKGSRC_BRANCH="pkgsrc-2025Q4"
PKGSRC_QUARTER="2025Q4"
PKG_PREFIX="/storage/Users/currentUser/.pkg"
PKG_ARCH="arm64"
OSS_BOOTSTRAP_PATH="bootstrap"
OSS_PACKAGE_PATH="packages/$PKGSRC_QUARTER/$PKG_ARCH/All"
OBJCTL="$WORKDIR/objctl.py"

# 下载 pkgsrc 源码树
cd /opt
git clone --depth 1 -b $PKGSRC_BRANCH "https://github.com/$GITHUB_REPOSITORY_OWNER/pkgsrc.git"

# bootstrap
cd /opt/pkgsrc/bootstrap
./bootstrap \
    --prefix $PKG_PREFIX \
    --varbase $PKG_PREFIX/var \
    --pkgdbdir $PKG_PREFIX/pkgdb \
    --prefer-pkgsrc yes \
    --compiler clang

# 修改个性化配置，让仓库里面所有把 openssl 视为可选依赖的软件包全部启用 openssl
sed -i '/.endif/i PKG_DEFAULT_OPTIONS+=\topenssl' $PKG_PREFIX/etc/mk.conf

# 把“干净”的 .pkg 目录复制一份备份起来
cp -r $PKG_PREFIX $PKG_PREFIX-backup

export MAKEFLAGS="MAKE_JOBS=$(nproc)"
export PATH=$PKG_PREFIX/bin:$PKG_PREFIX/sbin:$PATH

# 需要预置在 bootstrap kit 里面的软件包
PACKAGES="pkgtools/pkgin
security/mozilla-rootcerts"

# 循环构建它们，产生的包会存放在 /opt/pkgsrc/packages/All
# 此时 .pkg 目录里面会带有大量构建期依赖
for pkg in $PACKAGES; do
    cd "/opt/pkgsrc/$pkg"
    bmake package clean
done

# 把这个“脏了”的 .pkg 目录删掉，再把“干净”的 .pkg 目录移回来
rm -r $PKG_PREFIX
mv $PKG_PREFIX-backup $PKG_PREFIX

# 通过二进制安装的方式，把这些预置包装到“干净”的目录里面，
# 此时 .pkg 里面只会携带它们的运行期依赖，不会携带构建期依赖
export PKG_PATH="/opt/pkgsrc/packages/All"
pkg_add pkgin mozilla-rootcerts

# 预置 ssl 证书到 .pkg 目录中，随包分发
mozilla-rootcerts install

# 整体进行一遍代码签名
find $PKG_PREFIX -type f | while read -r FILE; do
    if file -b "$FILE" | grep -iqE "ELF|shared object"; then
        echo ">>> Signing: $FILE"
        binary-sign-tool sign -inFile $FILE -outFile $FILE -selfSign 1
        chmod 0755 $FILE
    fi
done

# 设置默认源为 CDN 地址
echo "http://$CDN_DOMAIN/$OSS_PACKAGE_PATH" > $PKG_PREFIX/etc/pkgin/repositories.conf

# 打包引导套件，tar 包和 zip 包各打包一份
cd $WORKDIR
TAR_NAME="bootstrap-$PKGSRC_QUARTER-$PKG_ARCH.tar.gz"
ZIP_NAME="bootstrap-$PKGSRC_QUARTER-$PKG_ARCH.zip"
tar -zcf "$TAR_NAME" -C / $PKG_PREFIX
# 构建环境里面没有 zip 命令，这里使用 python 打包 zip 包
python3 -m zipfile -c "$ZIP_NAME" $PKG_PREFIX

# 上传到 OSS
echo ">>> [UPLOAD] Uploading bootstrap kit..."
$OBJCTL upload "$WORKDIR/$TAR_NAME" "$OSS_BOOTSTRAP_PATH/$TAR_NAME"
$OBJCTL upload "$WORKDIR/$ZIP_NAME" "$OSS_BOOTSTRAP_PATH/$ZIP_NAME"

# 刷新 CDN 缓存
echo ">>> [CDN] Refreshing files (File mode)..."
$OBJCTL refresh "http://$CDN_DOMAIN/$OSS_BOOTSTRAP_PATH/$TAR_NAME" "File"
$OBJCTL refresh "http://$CDN_DOMAIN/$OSS_BOOTSTRAP_PATH/$ZIP_NAME" "File"
