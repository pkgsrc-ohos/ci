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
    if [ -z "$(eval echo \$$var)" ]; then echo ">>> [ERROR] $var is missing"; exit 1; fi
done

# --- 初始化基础变量 ---
WORKDIR=$(pwd)
PKGSRC_BRANCH="pkgsrc-2025Q4"
PKGSRC_QUARTER="2025Q4"
PKG_PREFIX="/storage/Users/currentUser/.pkg"
PKG_ARCH="arm64"
INDEX_GZ="pkg_summary.gz"     # gzip 格式的索引文件，用于上传/下载
INDEX_TXT="pkg_summary"       # 文本格式的索引文件，用于本地操作
INDEX_TMP="pkg_summary.tmp"   # 重建索引时的临时文件
PMETA_TMP="package-meta.tmp"  # 包元数据临时文件，里面是单个包的元数据
OSS_BOOTSTRAP_PATH="bootstrap"
OSS_PACKAGE_PATH="packages/$PKGSRC_QUARTER/$PKG_ARCH/All"
BOOTSTRAP_KIT_NAME="bootstrap-$PKGSRC_QUARTER-$PKG_ARCH.tar.gz"
OBJCTL="$WORKDIR/objctl.py"

# --- 准备构建环境 ---
echo ">>> [SETUP] Cloning pkgsrc tree (branch: $PKGSRC_BRANCH)..."
cd /opt
git clone --depth 1 -b "$PKGSRC_BRANCH" https://github.com/$GITHUB_REPOSITORY_OWNER/pkgsrc.git
echo ">>> [SETUP] Fetching bootstrap kit..."

$OBJCTL download "$OSS_BOOTSTRAP_PATH/$BOOTSTRAP_KIT_NAME" "$BOOTSTRAP_KIT_NAME"
tar -zxf "$BOOTSTRAP_KIT_NAME" -C /

cd "$WORKDIR"

export PATH=$PKG_PREFIX/bin:$PKG_PREFIX/sbin:$PATH
sed -i '/.endif/i OHOS_CODE_SIGN+=\tyes' $PKG_PREFIX/etc/mk.conf
export MAKEFLAGS="MAKE_JOBS=$(nproc)"

# --- 下载包索引 ---
echo ">>> [SYNC] Downloading existing index..."
$OBJCTL download "$OSS_PACKAGE_PATH/$INDEX_GZ" "$INDEX_GZ" || touch "$INDEX_TXT"

if [ -f "$INDEX_GZ" ]; then 
    gzip -df "$INDEX_GZ" 
fi

# --- 核心构建循环 ---
TARGET_LIST=$(cat $WORKDIR/whitelist.txt)
for p_path in $TARGET_LIST; do

    cd "/opt/pkgsrc/$p_path"

    # 获取包属性：P_NAME(带版本号), P_BASE(包名), P_TGZ(制品路径)
    P_NAME=$(bmake show-var VARNAME=PKGNAME)
    P_BASE=$(bmake show-var VARNAME=PKGBASE)
    P_TGZ="/opt/pkgsrc/packages/All/$P_NAME.tgz"

    # 增量构建检查：如果当前版本已存在索引和制品，则跳过构建
    if grep -q "^PKGNAME=$P_NAME$" "$WORKDIR/$INDEX_TXT" && $OBJCTL check "$OSS_PACKAGE_PATH/$P_NAME.tgz"; then
        echo ">>> [SKIP] $P_NAME is already up-to-date."
        cd "$WORKDIR"
        continue
    fi

    # 依赖预下载，避免实时构建占用大量时间
    # 安装失败不退出，因为还有实时构建作为兜底
    echo ">>> [PRE-FETCH] Quick-installing dependencies for $P_NAME..."
    RAW_DEPS=$(bmake show-depends-recursive 2>/dev/null)
    if [ -n "$RAW_DEPS" ]; then
        pkgin -y update || true
        for dep_path in $RAW_DEPS; do
            FULL_DEP_PATH="/opt/pkgsrc/$dep_path"
            if [ -d "$FULL_DEP_PATH" ]; then
                DEP_BASE=$(cd "$FULL_DEP_PATH" && bmake show-var VARNAME=PKGBASE)
                pkgin -y install "$DEP_BASE" || true
            fi
        done
    fi

    # 执行构建，失败则跳过，去构建下一个包
    echo ">>> [BUILD] Compiling $P_NAME..."
    if ! bmake package clean; then
        echo ">>> [ERROR] Build failed for $P_NAME."
        cd "$WORKDIR"
        continue
    fi

    # 验证制品生成结果
    if [ ! -f "$P_TGZ" ]; then
        echo ">>> [ERROR] $P_NAME compiled, but $P_TGZ is missing."
        cd "$WORKDIR"
        continue
    fi

    # 上传制品包
    echo ">>> [UPLOAD] $P_NAME.tgz"
    $OBJCTL upload "$P_TGZ" "$OSS_PACKAGE_PATH/$P_NAME.tgz"

    # 更新包索引：把这个包的元数据添加到包索引中，如果这个包之前已经存在于包索引中就先删掉再重新添加。
    pkg_info -X "$P_TGZ" > "$WORKDIR/$PMETA_TMP"
    awk -v pbase="$P_BASE" '
        BEGIN { RS = ""; ORS = "\n\n" }
        {
            if ($0 ~ "(^|\n)PKGNAME=" pbase "-[0-9]+") {
                next 
            }
            print $0
        }' "$WORKDIR/$INDEX_TXT" > "$WORKDIR/$INDEX_TMP"
    cat "$WORKDIR/$PMETA_TMP" >> "$WORKDIR/$INDEX_TMP"
    mv "$WORKDIR/$INDEX_TMP" "$WORKDIR/$INDEX_TXT"
    gzip -c "$WORKDIR/$INDEX_TXT" > "$WORKDIR/$INDEX_GZ"

    # 上传更新后的包索引
    echo ">>> [UPLOAD] Index: $INDEX_GZ"
    $OBJCTL upload "$WORKDIR/$INDEX_GZ" "$OSS_PACKAGE_PATH/$INDEX_GZ"

    echo ">>> [SUCCESS] $P_NAME is uploaded."

    # 返回工作目录，开启下一轮构建
    cd $WORKDIR
done

# 刷新 CDN 缓存
echo ">>> [CDN] Refreshing directory..."
$OBJCTL refresh "http://$CDN_DOMAIN/$OSS_PACKAGE_PATH/" "Directory"
