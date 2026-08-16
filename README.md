# sing-box Argo Lite

适用于无 root、低内存 NAT 小机的 VLESS + WebSocket + TLS 一键部署脚本。

支持常见的 Debian、Ubuntu 和 Alpine Linux 系统，无需安装 Nginx、Caddy、systemd 或申请 TLS 证书。

## 工作原理

```text
v2rayN
  -> Cloudflare 临时域名:443
  -> Cloudflare Quick Tunnel
  -> 127.0.0.1:自定义端口
  -> sing-box VLESS + WebSocket
```

TLS 由 Cloudflare 提供，服务器本地不需要配置域名和证书。

## 支持架构

- `x86_64 / amd64`
- `aarch64 / arm64`
- `armv7`
- `i386 / i686`

## 一键安装

推荐使用下面的一行命令：

```sh
wget -qO- https://raw.githubusercontent.com/liu200320/sing-box-argo-lite/main/install.sh | tr -d '\r' | sh
```
wget -qO- https://raw.githubusercontent.com/liu200320/sing-box-argo-lite/main/install.sh | tr -d '\r' | sh
其中 `tr -d '\r'` 可以兼容 Windows CRLF 换行。

安装时脚本会询问：

```text
请输入 sing-box 本地回源端口 [默认 40001]:
```

直接按回车使用 `40001`，也可以输入其他高位端口，例如：

```text
40002
```

端口会保存在：

```text
~/.config/sb-argo/local-port
```

以后执行 `restart`、`update` 或开机启动时，会继续使用保存的端口。

## 非交互安装

通过环境变量直接指定端口：

```sh
wget -qO- https://raw.githubusercontent.com/liu200320/sing-box-argo-lite/main/install.sh | tr -d '\r' | LOCAL_PORT=40001 sh
```

也可以指定节点名称：

```sh
wget -qO- https://raw.githubusercontent.com/liu200320/sing-box-argo-lite/main/install.sh | tr -d '\r' | LOCAL_PORT=40001 NODE_NAME=My-NAT-Node sh
```

节点名称只能包含英文字母、数字、点、下划线和短横线。

## Alpine Linux

Alpine 可以直接使用推荐的一键安装命令：

```sh
wget -qO- https://raw.githubusercontent.com/liu200320/sing-box-argo-lite/main/install.sh | tr -d '\r' | sh
```

如果 HTTPS 下载提示证书错误，并且当前用户有 root 权限，可以先安装证书和下载工具：

```sh
apk add --no-cache ca-certificates wget
update-ca-certificates
```

脚本本身不要求 root 权限，所有文件均安装在当前用户的 `$HOME` 目录。

## 查看节点

安装成功后执行：

```sh
~/.local/bin/sb-argo show
```

脚本会显示：

```text
协议: VLESS
地址: 随机域名.trycloudflare.com
端口: 443
传输: WebSocket
Host: 随机域名.trycloudflare.com
TLS: 开启
SNI: 随机域名.trycloudflare.com
本地回源端口: 40001
```

复制输出中完整的 `vless://` 链接，在 v2rayN 中选择：

```text
服务器 -> 从剪贴板导入批量 URL
```

生成的链接必须类似：

```text
vless://UUID@随机域名.trycloudflare.com:443?...
```

如果链接中出现下面这种空地址，则节点无效：

```text
vless://UUID@:443
```

## 管理命令

查看节点：

```sh
~/.local/bin/sb-argo show
```

查看运行状态：

```sh
~/.local/bin/sb-argo status
```

重启服务并获取新的 Cloudflare 临时域名：

```sh
~/.local/bin/sb-argo restart
```

查看日志：

```sh
~/.local/bin/sb-argo logs
```

停止服务：

```sh
~/.local/bin/sb-argo stop
```

更新 sing-box、cloudflared 和管理脚本：

```sh
~/.local/bin/sb-argo update
```

重新生成 UUID、WebSocket 路径和临时域名：

```sh
~/.local/bin/sb-argo rotate
```

彻底卸载：

```sh
~/.local/bin/sb-argo uninstall
```

## 更换本地端口

重新运行一键安装命令并输入新端口，或者直接执行：

```sh
printf '%s\n' '40002' > ~/.config/sb-argo/local-port
~/.local/bin/sb-argo restart
```

如果 NAT 映射格式是：

```text
50001:40001
```

应输入右侧的内部端口：

```text
40001
```

需要注意：Quick Tunnel 模式不需要公网端口映射。v2rayN 始终连接 Cloudflare 临时域名的 `443` 端口，输入的端口只用于服务器本地的 `cloudflared -> sing-box` 回源。

## 本地订阅文件

脚本会生成 Base64 订阅文件：

```text
~/.local/share/sb-argo/state/subscription.txt
```

查看订阅内容：

```sh
cat ~/.local/share/sb-argo/state/subscription.txt
```

该文件位于服务器本地，不是在线订阅 URL。当前精简版本不运行额外的订阅服务器，以降低内存占用。

## 文件位置

```text
管理命令:
~/.local/bin/sb-argo

程序目录:
~/.local/share/sb-argo/bin

配置目录:
~/.config/sb-argo

节点信息:
~/.local/share/sb-argo/state/node-info.txt

本地订阅:
~/.local/share/sb-argo/state/subscription.txt

运行日志:
~/.local/share/sb-argo/logs
```

## 故障排查

检查运行状态：

```sh
~/.local/bin/sb-argo status
```

正常情况下应显示：

```text
sing-box:    running
cloudflared: running
```

查看日志：

```sh
~/.local/bin/sb-argo logs
```

查看内存：

```sh
free -m
```

如果系统没有 `free`，可以执行：

```sh
cat /proc/meminfo
```

## 注意事项

- Cloudflare Quick Tunnel 的临时域名不是固定域名。
- 执行 `restart` 后，临时域名通常会改变，需要重新导入节点。
- 执行 `rotate` 会更换 UUID、WebSocket 路径和临时域名。
- 客户端端口始终是 `443`，不是本地回源端口。
- 不需要在 v2rayN 中开启“跳过证书验证”。
- 64 MB 内存非常有限，脚本已使用低内存运行参数，但仍无法保证所有服务商环境都长期稳定。
- 部分服务商会在 SSH 断开后清理用户进程，此时 `nohup` 可能无法保活。
- 用户 `crontab` 是否支持开机启动取决于服务商环境。
- 不要公开完整节点链接、UUID 或其他认证信息。
