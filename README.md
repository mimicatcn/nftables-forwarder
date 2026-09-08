# nftables 端口转发管理脚本

nftables 端口转发一键管理工具，支持 TCP/UDP 转发。

## 一键安装

```bash
bash <(curl -Ls https://raw.githubusercontent.com/mimicatcn/nftables-forwarder/main/install.sh)
```

安装完成后输入 `nat` 即可打开管理菜单。

## 使用说明

| 选项 | 功能 |
|------|------|
| 1 | 添加转发规则 |
| 2 | 删除转发规则 |
| 3 | 查看所有规则 |
| 4 | 保存规则 |
| 0 | 退出 |

## 系统要求

- Debian 12 / Ubuntu 22.04+
- 需要 root 权限
