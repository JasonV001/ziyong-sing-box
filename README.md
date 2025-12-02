# 一件安装

```
wget -N -O /usr/local/bin/anytls-reality.sh https://raw.githubusercontent.com/JasonV001/ziyong-sing-box/refs/heads/main/anytls-reality.sh && chmod +x /usr/local/bin/anytls-reality.sh && bash /usr/local/bin/anytls-reality.sh
```

```
wget -N -O /usr/local/bin/socks5.sh https://raw.githubusercontent.com/JasonV001/ziyong-sing-box/refs/heads/main/socks5.sh && chmod +x /usr/local/bin/socks5.sh && bash /usr/local/bin/socks5.sh
```
```
wget -N -O /usr/local/bin/microsocks.sh https://raw.githubusercontent.com/JasonV001/ziyong-sing-box/refs/heads/main/microsocks.sh && chmod +x /usr/local/bin/microsocks.sh && bash /usr/local/bin/microsocks.sh
```
# 再次运行
```
bash /usr/local/bin/anytls-reality.sh
bash /usr/local/bin/anytls-reality-socks5.sh
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
