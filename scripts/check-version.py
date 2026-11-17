#!/usr/bin/env python3
"""校验发布版本及 Xcode 的 Debug、Release 配置，避免两种构建方式版本不一致。"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent


def validate(version, project):
    # macOS 应用版本仅使用 SemVer 的三段数字；先行版本另行设计映射。
    if not re.fullmatch(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)", version):
        raise ValueError("VERSION 必须是无前导零的 X.Y.Z 版本号")
    versions = re.findall(r"MARKETING_VERSION = ([^;]+);", project)
    if versions != [version, version]:
        raise ValueError(f"Xcode Debug、Release 版本必须均为 {version}，实际为 {versions}")


def self_test():
    for version in ("0.0.94", "1.0.0", "12.34.56"):
        validate(version, f"MARKETING_VERSION = {version};\n" * 2)
    for version, project in (
        ("01.0.0", "MARKETING_VERSION = 01.0.0;\n" * 2),
        ("0.0", ""),
        ("0.0.94", "MARKETING_VERSION = 0.0.93;\n" * 2),
        ("0.0.94", "MARKETING_VERSION = 0.0.94;"),
    ):
        try:
            validate(version, project)
        except ValueError:
            continue
        raise AssertionError(f"应拒绝无效或不一致的版本：{version}")
    print("版本校验自检通过")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--self-test"]:
            self_test()
        elif sys.argv[1:]:
            raise ValueError("用法：python3 scripts/check-version.py [--self-test]")
        else:
            version = (ROOT / "VERSION").read_text().strip()
            validate(version, (ROOT / "NativeMonitor.xcodeproj/project.pbxproj").read_text())
            print(f"版本校验通过：{version}")
    except (OSError, ValueError) as error:
        sys.exit(str(error))
