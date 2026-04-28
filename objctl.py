#!/usr/bin/env python3

import os
import sys
import alibabacloud_oss_v2 as oss
from alibabacloud_cdn20180510.client import Client as CdnClient
from alibabacloud_tea_openapi import models as open_api_models
from alibabacloud_cdn20180510 import models as cdn_models


def get_oss_client():
    # 兼容性处理：如果只配置了 ALIBABA_CLOUD_... 变量，自动映射给 OSS SDK 识别
    if "ALIBABA_CLOUD_ACCESS_KEY_ID" in os.environ and "OSS_ACCESS_KEY_ID" not in os.environ:
        os.environ["OSS_ACCESS_KEY_ID"] = os.environ["ALIBABA_CLOUD_ACCESS_KEY_ID"]
    if "ALIBABA_CLOUD_ACCESS_KEY_SECRET" in os.environ and "OSS_ACCESS_KEY_SECRET" not in os.environ:
        os.environ["OSS_ACCESS_KEY_SECRET"] = os.environ["ALIBABA_CLOUD_ACCESS_KEY_SECRET"]

    # V2 SDK 默认从环境变量读取 OSS_ACCESS_KEY_ID 等
    credentials_provider = oss.credentials.EnvironmentVariableCredentialsProvider()
    cfg = oss.Config(
        credentials_provider=credentials_provider,
        endpoint=os.environ["OSS_ENDPOINT"],
        region=os.environ["OSS_REGION"],
    )
    return oss.Client(cfg)


def oss_check_exists(remote_key):
    """
    判断 OSS 中的文件是否存在 (使用 HeadObject)
    """
    client = get_oss_client()
    bucket_name = os.environ["OSS_BUCKET"]

    try:
        request = oss.HeadObjectRequest(bucket=bucket_name, key=remote_key)
        client.head_object(request)
        print(f">>> [OSS] File exists: {remote_key}")
        return True
    except Exception as e:
        if "Error Code: NoSuchKey" in str(e):
            print(f">>> [OSS] File NOT found: {remote_key}")
            return False
        raise e


def oss_upload(local_file, remote_key):
    client = get_oss_client()
    bucket_name = os.environ["OSS_BUCKET"]

    with open(local_file, "rb") as f:
        request = oss.PutObjectRequest(bucket=bucket_name, key=remote_key, body=f)
        result = client.put_object(request)

    print(f">>> [OSS] Uploaded: {remote_key}")


def oss_download(remote_key, local_file):
    client = get_oss_client()
    bucket_name = os.environ["OSS_BUCKET"]

    request = oss.GetObjectRequest(bucket=bucket_name, key=remote_key)
    result = client.get_object(request)

    local_dir = os.path.dirname(local_file)
    if local_dir and not os.path.exists(local_dir):
        os.makedirs(local_dir)

    with open(local_file, "wb") as f:
        f.write(result.body.read())

    if result.body:
        result.body.close()

    print(f">>> [OSS] Downloaded: {remote_key} -> {local_file}")


def cdn_refresh(path, obj_type):
    config = open_api_models.Config(
        access_key_id=os.environ["ALIBABA_CLOUD_ACCESS_KEY_ID"],
        access_key_secret=os.environ["ALIBABA_CLOUD_ACCESS_KEY_SECRET"],
        endpoint="cdn.aliyuncs.com",
    )
    client = CdnClient(config)

    request = cdn_models.RefreshObjectCachesRequest(object_path=path, object_type=obj_type)

    response = client.refresh_object_caches(request)
    task_id = getattr(response.body, "refresh_task_id", "Unknown")

    print(f">>> [CDN] Refresh Success!")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage:")
        print("  Check:     python3 objctl.py check <remote_key>")
        print("  Upload:    python3 objctl.py upload <local_path> <remote_key>")
        print("  Download:  python3 objctl.py download <remote_key> <local_path>")
        print("  Refresh:   python3 objctl.py refresh <url> <File|Directory>")
        sys.exit(1)

    mode = sys.argv[1]

    try:
        if mode == "check":
            exists = oss_check_exists(sys.argv[2])
            sys.exit(0 if exists else 1)
            
        elif mode == "upload":
            oss_upload(sys.argv[2], sys.argv[3])
            
        elif mode == "download":
            oss_download(sys.argv[2], sys.argv[3])
            
        elif mode == "refresh":
            cdn_refresh(sys.argv[2], sys.argv[3])
            
        else:
            print(f"Unknown mode: {mode}")
            sys.exit(1)
            
    except Exception as e:
        print(f">>> [FATAL ERROR] {str(e)}")
        sys.exit(1)
