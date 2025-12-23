# anytls-reality快捷键：ar

```
wget -N -O /usr/local/bin/anytls-reality.sh https://raw.githubusercontent.com/JasonV001/ziyong-sing-box/refs/heads/main/anytls-reality.sh && chmod +x /usr/local/bin/anytls-reality.sh && bash /usr/local/bin/anytls-reality.sh
```
# 再次运行
```
bash /usr/local/bin/anytls-reality.sh
bash /usr/local/bin/anytls-reality-socks5.sh
```
# socks5一件安装
```
wget -N -O /usr/local/bin/socks5.sh https://raw.githubusercontent.com/JasonV001/ziyong-sing-box/refs/heads/main/socks5.sh && chmod +x /usr/local/bin/socks5.sh && bash /usr/local/bin/socks5.sh
```
# MTProxy快捷命令：mtp
```
(curl -LfsS https://raw.githubusercontent.com/JasonV001/ziyong-sing-box/refs/heads/main/mtp.sh -o /usr/local/bin/mtp || wget -q https://raw.githubusercontent.com/JasonV001/ziyong-sing-box/refs/heads/main/mtp.sh -O /usr/local/bin/mtp) && chmod +x /usr/local/bin/mtp && mtp
```
</details>

# 手动开机重启sing-box-Alpine

<details>
    <summary>(点击展开)</summary>
    
```
ps aux | grep sing-box  # 查看进程是否存在
ps aux | grep anytls
```

# reality-Alpine重启
```
nohup /usr/local/bin/sing-box run -c /usr/local/etc/sing-box/reality.json
```

# AnyTLs-Alpine重启
```
nohup "/usr/local/bin/anytls-server" -l "0.0.0.0:端口" -p "anytls密码"
```





```
😆
```
</details>
# NAT VPS Swap一键配置工具

一个自动为NAT VPS配置Swap交换空间的Shell脚本。

## 功能特性
- 自动检测系统信息
- 交互式Swap大小选择
- 智能磁盘空间检查
- 自动优化系统参数
- 安全删除功能

## 快速开始
```bash
# 方法1: 直接运行
sudo bash -c "$(curl -sSL https://raw.githubusercontent.com/JasonV001/ziyong-sing-box/main/swap_install.sh)"

# 方法2: 下载后运行
wget https://raw.githubusercontent.com/JasonV001/ziyong-sing-box/main/swap_install.sh
sudo bash swap_install.sh