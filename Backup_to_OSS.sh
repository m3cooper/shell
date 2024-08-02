#!/bin/bash

# 数据库和文件系统备份配置
# 使用此件本需要现在服务器安装 ossutil,参考链接 https://help.aliyun.com/zh/oss/developer-reference/install-ossutil?spm=a2c4g.11186623.0.0.123b3000uH25z6
DB_USER="root"  #Mysql 账号
DB_PASSWORD="123456"   #Mysql 密码
DB_HOST="localhost"
DATABASES=("juhui" "www_china_juhui_") # 数据库列表，多个数据库以数组的方式
BACKUP_SRC=("/www/wwwroot/juhui" "/www/wwwroot/www.china-juhui.com")  # 需要备份的网站目录路径列表
BACKUP_DIR="/www/backup" # 本地备份文件临时存放目录
DATE=$(date +"%Y%m%d_%H%M%S")
OSS_BUCKET="oss://backup" # 阿里云OSS的bucket路径
backups_to_keep=7         # 备份文件保留数量

# 函数：上传文件并在失败时重试
upload_with_retry() {
    local file_to_upload=$1
    local oss_dest=$2
    local max_attempts=20
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        echo "尝试上传（次数 $attempt）: $file_to_upload"
        ossutil cp "$file_to_upload" "$oss_dest" --bigfile-threshold=1
        if [ $? -eq 0 ]; then
            echo "上传成功: $file_to_upload"
            return 0
        else
            echo "上传失败，重试中..."
            ((attempt++))
        fi
    done

    echo "上传重试次数达到上限，上传失败: $file_to_upload"
    return 1
}

# 备份数据库
for DB_NAME in "${DATABASES[@]}"; do
    DB_BACKUP_FILE="$BACKUP_DIR/${DB_NAME}_$DATE.sql"
    if ! mysqldump -h $DB_HOST -u $DB_USER -p$DB_PASSWORD $DB_NAME > $DB_BACKUP_FILE; then
        echo "备份数据库 $DB_NAME 失败" >&2
        exit 1
    fi

    upload_with_retry "$DB_BACKUP_FILE" "$OSS_BUCKET/DBfile/${DB_NAME}/${DB_NAME}_$DATE.sql"
    rm "$DB_BACKUP_FILE"
done

# 压缩并上传文件备份到OSS
backup_and_upload() {
    local src_path=$1
    local backup_name="backup_${src_path##*/}_$DATE.tar.gz"
    local temp_backup_path="$BACKUP_DIR/$backup_name"
    local oss_path="$OSS_BUCKET/SiteFile/${src_path##*/}/$backup_name"

    # 创建临时压缩文件
    tar -czf "$temp_backup_path" -C "$(dirname "$src_path")" "$(basename "$src_path")"

    # 使用断点续传上传文件系统备份
    upload_with_retry "$temp_backup_path" "$oss_path"

    # 删除临时文件
    rm "$temp_backup_path"
}

# 备份文件系统
for src in "${BACKUP_SRC[@]}"; do
    backup_and_upload "$src"
done

# 清理OSS中的旧备份
cleanup_old_backups() {
    local oss_path=$1
    local backup_pattern=$2

    # 获取文件列表并过滤出备份文件
    backup_files=$(ossutil ls "$oss_path" | grep -E "$backup_pattern" | awk '{print $NF}')

    # 删除超出保留数量的旧备份文件
    if [ $(echo "$backup_files" | wc -l) -gt $backups_to_keep ]; then
        echo "$backup_files" | sort | head -n -$backups_to_keep | while read -r old_backup; do
            echo "Deleting: $old_backup"
            ossutil rm "$old_backup"
        done
    fi
}

# 清理网站文件备份
for src in "${BACKUP_SRC[@]}"; do
    cleanup_old_backups "$OSS_BUCKET/SiteFile/${src##*/}" "backup_.*\.tar\.gz"
done

# 清理数据库备份
for DB_NAME in "${DATABASES[@]}"; do
    cleanup_old_backups "$OSS_BUCKET/DBfile/" "${DB_NAME}_.*\.sql"
done
