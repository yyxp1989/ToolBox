# openclaw-debian-menu.sh 修复完成报告

> 修复时间：2026-03-24
> 版本升级：v2.6.1 → v2.7.0

## ✅ 全部 11 项修复已完成

### P0 (3项)
1. TARGET_USER 检测改用 logname（防环境变量伪造）
2. TARGET_USER 正则格式验证（防路径注入）
3. 日志文件移出 /tmp（防符号链接攻击 + 权限 600）

### P1 (5项)
4. run_cmd 保留实际 exit code
5. Docker GPG sudo → as_root
6. sed -i 改为 tmpfile + mv 原子写入（setup_shortcut / uninstall_pnpm）
7. SMB 路径验证增强（新增 _validate_path 函数）
8. 配置文件原子写入（新增 safe_write 函数）

### P2 (3项)
9. hostname -I 全部 6 处加错误处理
10. docker 组提示增强
11. SMB awk 临时文件清理

## 验证
- `bash -n` 语法检查通过
