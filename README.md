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
