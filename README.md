# sing-box Argo Lite

适用于无 root、低内存 NAT 小机的 VLESS + WebSocket + TLS 一键部署脚本。

脚本使用 Cloudflare Quick Tunnel 自动生成临时 `trycloudflare.com` 域名，不需要自己的域名、TLS 证书、Nginx 或 systemd。

## 一键安装
## 交互式端口选择

运行一键安装命令后，脚本会询问：

```text
请输入 sing-box 本地回源端口 [默认 40001]:
```

如果 NAT 映射是：

```text
40001:40001
```

输入：

```text
40001
```

也可以直接按回车使用默认端口。

如果外部端口和内部端口不同，例如：

```text
50001:40001
```

应输入右侧的内部端口：

```text
40001
```

端口会保存到：

```text
~/.config/sb-argo/local-port
```

执行 `restart`、`update` 或服务器重启时，会继续使用保存的端口，不会再次询问。

也可以使用环境变量跳过交互：

```bash
wget -qO- \
  https://raw.githubusercontent.com/liu200320/sing-box-argo-lite/main/install.sh \
  | tr -d '\r' \
  | LOCAL_PORT=40002 bash
```

注意：Cloudflare 临时隧道模式下，v2rayN 仍然连接临时域名的 `443` 端口。这里输入的端口只用于服务器本地回源。
推荐使用下面的命令。命令中的 `tr` 可以兼容意外出现的 Windows CRLF 换行：

```bash
wget -qO- https://raw.githubusercontent.com/liu200320/sing-box-argo-lite/main/install.sh | tr -d '\r' | bash
```

也可以分行执行：

```bash
wget -qO- \
  https://raw.githubusercontent.com/liu200320/sing-box-argo-lite/main/install.sh \
  | tr -d '\r' \
  | bash
```

确认 GitHub 上的 `install.sh` 已经使用 Linux LF 换行后，也可以使用：

```bash
bash <(wget -qO- \
  https://raw.githubusercontent.com/liu200320/sing-box-argo-lite/main/install.sh)
```

安装成功后，脚本会自动输出一个完整的 `vless://` 节点链接。

## 查看节点

执行：

```bash
~/.local/bin/sb-argo show
```

复制输出中完整的 `vless://` 链接，在 v2rayN 中选择：

```text
服务器 -> 从剪贴板导入批量 URL
```

正确生成的节点应包含：

```text
协议：VLESS
端口：443
传输：WebSocket
TLS：开启
地址：随机域名.trycloudflare.com
Host：随机域名.trycloudflare.com
SNI：随机域名.trycloudflare.com
```

## 管理命令

查看节点：

```bash
~/.local/bin/sb-argo show
```

查看运行状态：

```bash
~/.local/bin/sb-argo status
```

重新启动并生成新的 Cloudflare 临时域名：

```bash
~/.local/bin/sb-argo restart
```

查看运行日志：

```bash
~/.local/bin/sb-argo logs
```

停止 sing-box 和 Cloudflare 隧道：

```bash
~/.local/bin/sb-argo stop
```

更新 sing-box、cloudflared 和管理脚本：

```bash
~/.local/bin/sb-argo update
```

重新生成 UUID、WebSocket 路径和节点：

```bash
~/.local/bin/sb-argo rotate
```

彻底卸载：

```bash
~/.local/bin/sb-argo uninstall
```

## 工作方式

```text
v2rayN
  -> trycloudflare.com:443
  -> Cloudflare Quick Tunnel
  -> 127.0.0.1:40001
  -> sing-box VLESS WebSocket
```

TLS 由 Cloudflare 提供，本机不需要配置域名和证书。

客户端连接临时域名的 `443` 端口，不需要填写 NAT 小机映射的 `40001` 端口。

## 订阅文件

脚本会在服务器本地生成 Base64 订阅文件：

```text
~/.local/share/sb-argo/state/subscription.txt
```

查看本地订阅内容：

```bash
cat ~/.local/share/sb-argo/state/subscription.txt
```

当前精简版本不提供在线订阅 URL，避免额外运行订阅服务或保存 GitHub Token。

## 注意事项

- Cloudflare Quick Tunnel 的临时域名在隧道重新启动后通常会改变。
- 执行 `restart` 后，需要重新运行 `show` 并导入新的节点链接。
- 执行 `rotate` 会同时更换 UUID、WebSocket 路径和临时域名。
- 不要在客户端开启“跳过证书验证”，Cloudflare 提供的是可信 TLS 证书。
- 64 MB 内存非常有限，脚本已经对 sing-box 和 cloudflared 设置了低内存运行参数。
- 部分服务商会在 SSH 断开后清理普通用户进程，这种环境下 `nohup` 可能无法长期保活。
- 用户 `crontab` 是否支持开机启动取决于服务商环境。

## 查看故障日志

如果节点无法连接，先检查运行状态：

```bash
~/.local/bin/sb-argo status
```

然后查看日志：

```bash
~/.local/bin/sb-argo logs
```

正常情况下应显示：

```text
sing-box:    running
cloudflared: running
```

生成的节点链接必须包含临时域名：

```text
vless://UUID@随机域名.trycloudflare.com:443
```

如果链接中出现下面这种空地址，则节点无效：

```text
vless://UUID@:443
```
